import AppKit
import AVKit
import BlinkShared

/// Video and audio through AVKit's standard controls. Zoom resizes the window around
/// the video (there is nothing to scroll), "fit" fills 90% of the screen, actual size
/// is the video's own pixel size. Doesn't autoplay; Space plays and pauses.
@objc(BlinkVideoViewer) class MediaViewer: NSObject, BlinkPlugin {
    private let playerView = AVPlayerView()
    private let player: AVPlayer
    private let audioOnly: Bool
    private var videoSize: NSSize?

    var view: NSView { playerView }
    var preferredSize: NSSize { audioOnly ? NSSize(width: 480, height: 60) : videoSize ?? NSSize(width: 960, height: 540) }
    class var isAudio: Bool { false }

    required convenience init(url: URL) { self.init(url: url, audioOnly: Self.isAudio) }
    var supportsZoom: Bool { !audioOnly }

    init(url: URL, audioOnly: Bool) {
        self.audioOnly = audioOnly
        let asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        super.init()
        playerView.player = player
        playerView.controlsStyle = audioOnly ? .inline : .floating
        playerView.showsFullScreenToggleButton = !audioOnly
        playerView.allowsPictureInPicturePlayback = !audioOnly
        if !audioOnly {
            Task { @MainActor [weak self] in
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return }
                let r = CGRect(origin: .zero, size: size).applying(transform)
                self?.videoSize = NSSize(width: abs(r.width), height: abs(r.height))
                self?.actualSize()   // natural size, shrunk only if it won't fit the screen
            }
        }
    }

    func didAppear() {
        playerView.window?.makeFirstResponder(playerView)
        if audioOnly {
            // Fixed-height strip: only the width is resizable.
            playerView.window?.minSize = NSSize(width: 320, height: 0)
            playerView.window?.setContentSize(NSSize(width: 480, height: 60))
            playerView.window?.contentMinSize = NSSize(width: 320, height: 60)
            playerView.window?.contentMaxSize = NSSize(width: 4000, height: 60)
        }
    }

    func tearDown() { player.pause(); playerView.player = nil }

    private func resize(to size: NSSize) {
        guard let window = playerView.window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let chrome = window.frame.height - window.contentLayoutRect.height
        let scale = min(1, visible.width / size.width, (visible.height - chrome) / size.height)
        let content = NSSize(width: size.width * scale, height: size.height * scale)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: true, animate: true)
        window.contentAspectRatio = size
    }

    private var current: NSSize { playerView.window?.contentLayoutRect.size ?? playerView.bounds.size }

    func zoomIn() { guard !audioOnly else { return }; resize(to: NSSize(width: current.width * 1.25, height: current.height * 1.25)) }
    func zoomOut() { guard !audioOnly else { return }; resize(to: NSSize(width: current.width / 1.25, height: current.height / 1.25)) }

    func zoomToFit() {
        guard !audioOnly, let v = videoSize, let screen = playerView.window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.size
        let scale = min(visible.width * 0.9 / v.width, visible.height * 0.85 / v.height)
        resize(to: NSSize(width: v.width * scale, height: v.height * scale))
    }

    func actualSize() {
        guard !audioOnly, let v = videoSize else { return }
        resize(to: v)
    }
}

@objc(BlinkAudioViewer) final class AudioViewer: MediaViewer {
    override class var isAudio: Bool { true }
}
