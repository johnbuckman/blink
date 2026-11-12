import AppKit
import AVFoundation
import BlinkShared

/// Sound files as a waveform with a playhead that moves as it plays. Click to jump there;
/// Space plays and pauses; when paused, ← → step 1 s (⇧ 0.1 s, ⌥ 10 s). Paused, drag
/// across the waveform to select a stretch and type a comment on it; ⌘K saves just that
/// stretch as a new .m4a next to the original, with the comment and exactly where it came
/// from in its metadata, and carries on playing.
@objc(BlinkAudioViewer) final class AudioViewer: MediaViewer {
    override class var isAudio: Bool { true }

    private let wave = WaveformView()
    private var timeObserver: Any?
    private var sampleRate: Double = 0

    override var view: NSView { wave }
    override var preferredSize: NSSize { NSSize(width: 900, height: 220) }

    required convenience init(url: URL) { self.init(url: url, audioOnly: true) }

    override init(url: URL, audioOnly: Bool) {
        super.init(url: url, audioOnly: true)
        wave.onSeek = { [weak self] t in self?.seek(to: t) }
        wave.onTogglePlay = { [weak self] in self?.togglePlay() }
        wave.onStep = { [weak self] d in self?.step(by: d) }
        wave.isPlaying = { [weak self] in self?.isPlaying ?? false }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wave.time = CMTimeGetSeconds(t)
                if let d = self.player.currentItem?.duration, d.isNumeric { self.wave.duration = CMTimeGetSeconds(d) }
            }
        }
        let asset = self.asset
        Task { @MainActor [weak self] in
            let (peaks, rate, duration) = await Task.detached(priority: .userInitiated) { await Self.readPeaks(asset) }.value
            self?.sampleRate = rate
            self?.wave.duration = duration
            self?.wave.peaks = peaks
        }
    }

    override func didAppear() {
        wave.window?.makeFirstResponder(wave)
        wave.window?.contentMinSize = NSSize(width: 360, height: 120)
    }

    override func tearDown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        super.tearDown()
    }

    override func play() { player.play(); wave.window?.makeFirstResponder(wave) }

    private func seek(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        wave.time = max(0, t)
    }

    // MARK: Peaks

    /// The loudest sample in each of up to 4000 slices of the sound (0…1), decoded with
    /// AVAssetReader off the main thread; plus the sample rate and length.
    private static func readPeaks(_ asset: AVURLAsset) async -> ([Float], Double, Double) {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return ([], 0, 0) }
        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        var rate: Double = 44100
        if let desc = try? await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee { rate = asbd.mSampleRate }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { return ([], rate, duration) }
        let total = max(1, Int(duration * rate))
        let slices = min(4000, total)
        let perSlice = max(1, total / slices)
        var peaks = [Float](repeating: 0, count: slices)
        var index = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                for i in 0..<count {
                    let slice = min(index / perSlice, slices - 1)
                    let v = abs(samples[i])
                    if v > peaks[slice] { peaks[slice] = v }
                    index += 1
                }
            }
        }
        let loudest = max(peaks.max() ?? 1, 0.001)
        return (peaks.map { min(1, $0 / loudest) }, rate, duration)
    }

    // MARK: Clips

    var canClip: Bool { true }
    var hasClipSelection: Bool { wave.selection != nil }

    /// Saves the selected stretch as name-0m12.3s-0m18.0s-clip-1.m4a beside the original,
    /// with a plain-words note (the original's path, the exact start and end in time and
    /// samples, and the comment) in its description and comment metadata, then plays on.
    func saveClip(_ done: @escaping (URL?, NSError?) -> Void) {
        guard let sel = wave.selection, sel.upperBound - sel.lowerBound > 0.01 else { done(nil, nil); return }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            done(nil, NSError(domain: "Blink", code: 1, userInfo: [NSLocalizedDescriptionKey: "This sound can't be saved as a clip."]))
            return
        }
        func stamp(_ t: Double) -> String { String(format: "%dm%04.1fs", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        func clock(_ t: Double) -> String { String(format: "%d:%06.3f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        let dir = url.deletingLastPathComponent()
        let base = "\(url.deletingPathExtension().lastPathComponent)-\(stamp(sel.lowerBound))-\(stamp(sel.upperBound))-clip"
        var n = 1
        var out = dir.appendingPathComponent("\(base)-\(n).m4a")
        while FileManager.default.fileExists(atPath: out.path) { n += 1; out = dir.appendingPathComponent("\(base)-\(n).m4a") }

        var note = "Clip made in Blink from the recording \(url.path), from \(clock(sel.lowerBound)) to \(clock(sel.upperBound))"
        note += String(format: " (%.3f to %.3f seconds from the start, %.3f seconds long", sel.lowerBound, sel.upperBound,
                       sel.upperBound - sel.lowerBound)
        if sampleRate > 0 {
            note += String(format: "; samples %d to %d at %d Hz", Int(sel.lowerBound * sampleRate), Int(sel.upperBound * sampleRate),
                           Int(sampleRate))
        }
        note += ")."
        if !wave.comment.isEmpty { note += " Comment: \"\(wave.comment)\"." }

        func item(_ key: AVMetadataKey, _ space: AVMetadataKeySpace, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.key = key as NSString
            m.keySpace = space
            m.value = value as NSString
            return m
        }
        let title = wave.comment.isEmpty ? "\(url.deletingPathExtension().lastPathComponent) \(clock(sel.lowerBound))–\(clock(sel.upperBound))" : wave.comment
        export.metadata = [item(.commonKeyDescription, .common, note), item(.iTunesMetadataKeyUserComment, .iTunes, note),
                           item(.commonKeyTitle, .common, title)]
        export.outputURL = out
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: CMTime(seconds: sel.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: sel.upperBound, preferredTimescale: 600))
        nonisolated(unsafe) let session = export
        export.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                if session.status == .completed {
                    self?.wave.clearSelection()
                    self?.play()
                    done(out, nil)
                } else {
                    done(nil, (session.error as NSError?) ?? NSError(domain: "Blink", code: 2,
                                                                      userInfo: [NSLocalizedDescriptionKey: "Blink couldn't save the clip."]))
                }
            }
        }
    }
}

/// The waveform: played part in the accent colour, the rest grey, a red playhead, a
/// translucent selection with its comment above it, and the times along the top.
final class WaveformView: NSView {
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var duration: Double = 0 { didSet { if duration != oldValue { needsDisplay = true } } }
    var time: Double = 0 { didSet { needsDisplay = true } }
    private(set) var selection: ClosedRange<Double>? { didSet { needsDisplay = true } }
    private(set) var comment = "" { didSet { needsDisplay = true } }

    var onSeek: ((Double) -> Void)?
    var onTogglePlay: (() -> Void)?
    var onStep: ((Double) -> Void)?
    var isPlaying: (() -> Bool)?

    private var dragStart: Double?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clearSelection() { selection = nil; comment = "" }

    private var track: NSRect { bounds.insetBy(dx: 16, dy: 0).divided(atDistance: 30, from: .minYEdge).remainder.insetBy(dx: 0, dy: 10) }
    private func x(_ t: Double) -> CGFloat { track.minX + track.width * CGFloat(duration > 0 ? t / duration : 0) }
    private func t(_ x: CGFloat) -> Double { duration * Double(min(max((x - track.minX) / max(track.width, 1), 0), 1)) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        let r = track
        if let sel = selection {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            NSRect(x: x(sel.lowerBound), y: r.minY - 6, width: x(sel.upperBound) - x(sel.lowerBound), height: r.height + 12).fill()
        }
        // Bars, one per pixel column, from the loudest peak in that column.
        if !peaks.isEmpty {
            let columns = max(1, Int(r.width))
            let played = x(time)
            for c in 0..<columns {
                let a = c * peaks.count / columns, b = max(a + 1, (c + 1) * peaks.count / columns)
                let v = CGFloat(peaks[a..<min(b, peaks.count)].max() ?? 0)
                let h = max(1, v * r.height)
                let px = r.minX + CGFloat(c)
                (px <= played ? NSColor.controlAccentColor : NSColor(white: 0.55, alpha: 1)).setFill()
                NSRect(x: px, y: r.midY - h / 2, width: 1, height: h).fill()
            }
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.6, alpha: 1)]
            ("Reading the sound…" as NSString).draw(at: NSPoint(x: r.minX, y: r.midY - 8), withAttributes: attrs)
        }
        // Playhead.
        NSColor.systemRed.setFill()
        NSRect(x: x(time) - 1, y: r.minY - 8, width: 2, height: r.height + 16).fill()

        // Times along the top, and the selection's comment above it.
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        func clock(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
        (clock(time) + " / " + clock(duration) as NSString).draw(at: NSPoint(x: 16, y: 8), withAttributes: small)
        if let sel = selection {
            let label = comment.isEmpty ? "\(clock(sel.lowerBound))–\(clock(sel.upperBound))  ·  type a comment, ⌘K saves the clip"
                                        : comment + "▏"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: comment.isEmpty ? 12 : 14, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            let size = (label as NSString).size(withAttributes: attrs)
            let mid = (x(sel.lowerBound) + x(sel.upperBound)) / 2
            let lx = min(max(mid - size.width / 2, 16), bounds.width - 16 - size.width)
            (label as NSString).draw(at: NSPoint(x: max(16, lx), y: 7), withAttributes: attrs)
        }
    }

    // MARK: Mouse: click to jump; paused, drag to select

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = t(p.x)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, isPlaying?() != true else { return }
        let now = t(convert(event.locationInWindow, from: nil).x)
        dragged = true
        selection = min(start, now)...max(start, now)
        comment = ""
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if !dragged, let start = dragStart {
            selection = nil
            comment = ""
            onSeek?(start)
        } else if let sel = selection, sel.upperBound - sel.lowerBound < 0.05 {
            selection = nil
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 49 where mods.isEmpty && comment.isEmpty:           // Space (types a space once a comment is under way)
            onTogglePlay?()
        case 123, 124 where mods.isSubset(of: [.shift, .option]) && isPlaying?() != true:
            let size: Double = mods.contains(.option) ? 10 : mods.contains(.shift) ? 0.1 : 1
            onStep?(event.keyCode == 123 ? -size : size)
        case 53:                                                  // Esc
            clearSelection()
        case 51 where selection != nil:                           // Delete
            if !comment.isEmpty { comment.removeLast() }
        case 36, 76:                                              // Return: comment done
            break
        default:
            if selection != nil, mods.isSubset(of: [.shift]), let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                comment += chars
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
