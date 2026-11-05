import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps a document smaller than the window centred instead of pinned bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A magnifiable scroll view that remembers whether it is in "fit" mode, so the
/// image keeps fitting as the window is resized until the user zooms by hand.
final class ZoomScrollView: NSScrollView {
    private(set) var fitting = true
    static let steps: [CGFloat] = [0.03, 0.05, 0.0625, 0.083, 0.125, 0.167, 0.25, 0.333, 0.5, 0.667,
                                   0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        allowsMagnification = true
        minMagnification = 0.01
        maxMagnification = 64
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        usesPredominantAxisScrolling = false
        NotificationCenter.default.addObserver(self, selector: #selector(userMagnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func userMagnified() { fitting = false }

    override func layout() {
        super.layout()
        if fitting { fit() }
    }

    func fit() {
        fitting = true
        guard let doc = documentView, doc.frame.width > 0, doc.frame.height > 0 else { return }
        let avail = contentView.bounds.size.applying(.init(scaleX: magnification, y: magnification))
        let m = min(avail.width / doc.frame.width, avail.height / doc.frame.height)
        // Fit only ever shrinks; small images show at their real size, like Preview.
        magnification = min(m, 1)
    }

    func step(_ up: Bool) {
        fitting = false
        let current = magnification
        let next = up ? Self.steps.first { $0 > current * 1.001 } ?? maxMagnification
                      : Self.steps.last { $0 < current * 0.999 } ?? minMagnification
        setMagnification(next, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }

    func actual() {
        fitting = false
        setMagnification(1, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }
}

/// Flipped so pages stack top-down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ImageViewer: Viewer {
    private let scroll = ZoomScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let canvas = FlippedView()
    private let url: URL
    private let source: CGImageSource?
    private var overlay: CropOverlay?
    /// Tells the window to enable or disable its Crop button.
    var onCropSelectionChange: ((Bool) -> Void)? { didSet { overlay?.onChange = onCropSelectionChange } }
    var onArrowsChange: ((Bool) -> Void)? { didSet { overlay?.onArrowsChange = onArrowsChange } }
    private var sampler: ColorSampler?
    private var pageLayers: [CALayer] = []
    private let decodeQueue = DispatchQueue(label: "blink.decode", qos: .userInitiated)
    private var naturalSize = NSSize(width: 400, height: 300)

    // Animation
    private var delays: [Double] = []
    private var frames: [Int: CGImage] = [:]
    private var cacheAllFrames = true
    private var frameIndex = 0
    private var timer: Timer?
    private var stopped = false

    var view: NSView { scroll }
    var preferredContentSize: NSSize? { naturalSize }

    init(url: URL) {
        self.url = url
        source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        canvas.wantsLayer = true
        scroll.documentView = canvas
        guard let source else { showError("Can't read this image."); return }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { showError("Can't read this image."); return }

        let first = pointSize(at: 0)
        delays = (0..<count).compactMap { frameDelay(at: $0) }
        let animated = count > 1 && delays.count == count

        if animated {
            naturalSize = first
            canvas.frame = NSRect(origin: .zero, size: first)
            pageLayers = [makeLayer(NSRect(origin: .zero, size: first))]
            let w = Double(first.width), h = Double(first.height)
            cacheAllFrames = w * h * Double(count) < 150_000_000  // ~600 MB of RGBA at most
            decode(0) { [weak self] img in
                self?.pageLayers.first?.contents = img
                self?.startAnimation()
            }
        } else {
            // Single image, or a multi-page TIFF stacked top to bottom.
            let gap: CGFloat = count > 1 ? 16 : 0
            var y: CGFloat = 0, width: CGFloat = 0
            var rects: [NSRect] = []
            for i in 0..<count {
                let s = pointSize(at: i)
                rects.append(NSRect(x: 0, y: y, width: s.width, height: s.height))
                y += s.height + gap
                width = max(width, s.width)
            }
            for i in rects.indices { rects[i].origin.x = (width - rects[i].width) / 2 }
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: y - gap)
            naturalSize = count > 1 ? NSSize(width: width, height: rects[0].height) : canvas.frame.size
            pageLayers = rects.map { makeLayer($0) }
            for i in 0..<count {
                decode(i) { [weak self] img in self?.pageLayers[i].contents = img }
            }
        }
        if pageLayers.count == 1 {
            let o = CropOverlay(frame: canvas.bounds)
            o.autoresizingMask = [.width, .height]
            canvas.addSubview(o)
            o.sampler = { [weak self] in self?.colorSampler() }
            overlay = o
        }
    }

    // MARK: Crop

    var canCrop: Bool { overlay != nil }
    var hasCropSelection: Bool { overlay?.selection != nil }

    enum CropError: LocalizedError {
        case notReady, cantWrite(URL)
        var errorDescription: String? {
            switch self {
            case .notReady: return "The picture hasn't finished loading."
            case .cantWrite(let u): return "Blink couldn't save \(u.lastPathComponent) in \(u.deletingLastPathComponent().path)."
            }
        }
    }

    var arrowMode: Bool {
        get { overlay?.arrowMode ?? false }
        set { overlay?.arrowMode = newValue }
    }
    var hasArrows: Bool { !(overlay?.arrows.isEmpty ?? true) }

    private func colorSampler() -> ColorSampler? {
        if sampler == nil, let layer = pageLayers.first, let img = layer.contents {
            sampler = ColorSampler(img as! CGImage, picture: layer.frame.size)
        }
        return sampler
    }

    /// Saves the selected part of the picture (the frame on screen, for an animation),
    /// with any arrows, next to the original as name-crop-1.ext, -crop-2 …
    func crop() throws -> URL? {
        guard let sel = overlay?.selection else { return nil }
        return try save(sel, suffix: "crop")
    }

    /// Saves the whole picture with its arrows as name-arrows-1.ext, -arrows-2 …
    func saveWithArrows() throws -> URL? {
        guard hasArrows else { return nil }
        return try save(canvas.bounds, suffix: "arrows")
    }

    /// Renders `region` (canvas points) with the arrows drawn in, and writes it in the
    /// original's format (PNG when that format can't be written). Rotation from EXIF is
    /// already in the pixels, so the new file has none. The file's description says, in
    /// plain words, what was done, so a person or an AI reading the file later knows
    /// what the arrows and labels point at.
    private func save(_ region: NSRect, suffix: String) throws -> URL? {
        guard let layer = pageLayers.first else { return nil }
        guard let contents = layer.contents else { throw CropError.notReady }
        let img = contents as! CGImage
        let scale = CGFloat(img.width) / layer.frame.width
        let px = NSRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale)
            .integral.intersection(NSRect(x: 0, y: 0, width: img.width, height: img.height))
        guard px.width >= 1, px.height >= 1, let cropped = img.cropping(to: px) else { return nil }
        let arrows = overlay?.arrows ?? []

        var output = cropped
        if !arrows.isEmpty {
            guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CropError.notReady }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: px.width, height: px.height))
            // Canvas points (y down) → this bitmap's pixels.
            ctx.translateBy(x: 0, y: px.height)
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -px.minX / scale, y: -px.minY / scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            Arrow.draw(arrows, picture: layer.frame.size)
            NSGraphicsContext.restoreGraphicsState()
            if let made = ctx.makeImage() { output = made }
        }

        var type = (source.flatMap { CGImageSourceGetType($0) } as String?) ?? UTType.png.identifier
        var ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : url.pathExtension
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if !writable.contains(type) { type = UTType.png.identifier; ext = "png" }

        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        var out = dir.appendingPathComponent("\(base)-\(suffix)-\(n).\(ext)")
        while FileManager.default.fileExists(atPath: out.path) {
            n += 1
            out = dir.appendingPathComponent("\(base)-\(suffix)-\(n).\(ext)")
        }

        let note = describe(original: img, region: px, arrows: arrows, scale: scale)
        var props = (source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]) ?? [:]
        props[kCGImagePropertyOrientation] = 1
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFImageDescription] = note
        tiff[kCGImagePropertyTIFFSoftware] = "Blink"
        props[kCGImagePropertyTIFFDictionary] = tiff
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment] = note
        exif[kCGImagePropertyExifPixelXDimension] = Int(px.width)
        exif[kCGImagePropertyExifPixelYDimension] = Int(px.height)
        props[kCGImagePropertyExifDictionary] = exif
        var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        iptc[kCGImagePropertyIPTCCaptionAbstract] = note
        props[kCGImagePropertyIPTCDictionary] = iptc
        var png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        png[kCGImagePropertyPNGDescription] = note
        props[kCGImagePropertyPNGDictionary] = png
        props[kCGImagePropertyPixelWidth] = nil
        props[kCGImagePropertyPixelHeight] = nil
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw CropError.cantWrite(out)
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CropError.cantWrite(out) }
        return out
    }

    /// e.g. "Made in Blink from the original picture /Users/me/Pictures/harbour-sunset.jpg (3000x2000 px): cropped to 1645x1012 px,
    /// taken from x 600, y 500 of the original. Arrow 1 (yellow) starts at (120, 300) and
    /// points at (800, 450), with the label "the boat" written along it." Arrow
    /// positions are in this file's pixels, from its top-left corner. Plain ASCII, since
    /// EXIF's UserComment can't hold anything else.
    private func describe(original img: CGImage, region px: NSRect, arrows: [Arrow], scale: CGFloat) -> String {
        var parts = ["Made in Blink from the original picture \(url.path) (\(img.width)x\(img.height) px)"]
        if px.width < CGFloat(img.width) || px.height < CGFloat(img.height) {
            parts[0] += ": cropped to \(Int(px.width))x\(Int(px.height)) px, taken from x \(Int(px.minX)), y \(Int(px.minY)) of the original."
        } else {
            parts[0] += ", same size as the original."
        }
        for (i, a) in arrows.enumerated() {
            func pt(_ p: NSPoint) -> String { "(\(Int(p.x * scale - px.minX)), \(Int(p.y * scale - px.minY)))" }
            var line = "Arrow \(i + 1) (\(a.colorName)) starts at \(pt(a.start)) and points at \(pt(a.end))"
            line += a.text.isEmpty ? "." : ", with the label \"\(a.text)\" written along it."
            parts.append(line)
        }
        if !arrows.isEmpty { parts.append("Arrow positions are in this image's pixels, from its top-left corner.") }
        return parts.joined(separator: " ")
    }

    func zoomIn() { scroll.step(true) }
    func zoomOut() { scroll.step(false) }
    func zoomToFit() { scroll.fit() }
    func actualSize() { scroll.actual() }

    func didAppear() {
        scroll.fit()
        if pageLayers.count > 1, delays.isEmpty {
            canvas.scroll(.zero)  // multi-page: start at the top of page 1
        }
    }

    func tearDown() {
        stopped = true
        timer?.invalidate()
        timer = nil
        frames.removeAll()
    }

    // MARK: Decoding

    /// Point size as Preview shows it: pixels at the file's DPI (72 dpi = 1 px per point),
    /// with EXIF rotation applied.
    private func pointSize(at i: Int) -> NSSize {
        guard let source, let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] else {
            return NSSize(width: 400, height: 300)
        }
        var w = (p[kCGImagePropertyPixelWidth] as? CGFloat) ?? 400
        var h = (p[kCGImagePropertyPixelHeight] as? CGFloat) ?? 300
        if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let dpi = (p[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let scale = dpi > 72 ? 72 / dpi : 1
        return NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    /// Frame duration if this frame belongs to an animation (GIF, APNG, HEICS, AVIS, WebP —
    /// they all use the same two key names inside their own dictionary).
    private func frameDelay(at i: Int) -> Double? {
        guard let source, let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any] else { return nil }
        for case let dict as [String: Any] in p.values {
            let d = (dict["UnclampedDelayTime"] as? Double) ?? (dict["DelayTime"] as? Double)
            if let d { return d < 0.011 ? 0.1 : d }  // browsers treat 0 as 100 ms
        }
        return nil
    }

    private func decode(_ i: Int, done: @escaping (CGImage?) -> Void) {
        guard let source else { return }
        decodeQueue.async {
            // The thumbnail call at full size is the one decode path that applies EXIF
            // orientation for us.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 100_000,
            ]
            let img = CGImageSourceCreateThumbnailAtIndex(source, i, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, i, nil)
            DispatchQueue.main.async { done(img) }
        }
    }

    private func makeLayer(_ rect: NSRect) -> CALayer {
        let layer = CALayer()
        layer.frame = rect
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest   // crisp pixels when zoomed right in
        layer.minificationFilter = .trilinear
        canvas.layer?.addSublayer(layer)
        return layer
    }

    // MARK: Animation

    private func startAnimation() {
        guard !stopped, delays.count > 1 else { return }
        prefetch(1)
        schedule(after: delays[0])
    }

    private func schedule(after delay: Double) {
        timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.advance() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func advance() {
        guard !stopped else { return }
        let next = (frameIndex + 1) % delays.count
        guard let img = frames[next] else {
            schedule(after: 0.01)   // decoder hasn't caught up yet
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayers.first?.contents = img
        CATransaction.commit()
        if !cacheAllFrames { frames[frameIndex] = nil }
        frameIndex = next
        prefetch((next + 1) % delays.count)
        schedule(after: delays[next])
    }

    private func prefetch(_ i: Int) {
        guard frames[i] == nil else { return }
        decode(i) { [weak self] img in
            guard let self, !self.stopped, let img else { return }
            self.frames[i] = img
        }
    }

    private func showError(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.sizeToFit()
        canvas.frame = NSRect(origin: .zero, size: NSSize(width: label.frame.width + 40, height: 60))
        label.frame.origin = NSPoint(x: 20, y: 20)
        canvas.addSubview(label)
        naturalSize = canvas.frame.size
    }
}
