import AppKit
import Quartz
import BlinkShared

/// Office documents (xlsx etc.) through the same renderer Finder's Quick Look uses.
/// Quick Look owns its own zoom, so the zoom controls are disabled for these.
@objc(BlinkQuickLookViewer) final class QuickLookViewer: NSObject, BlinkPlugin {
    private let preview: QLPreviewView

    var view: NSView { preview }
    var preferredSize: NSSize { NSSize(width: 1100, height: 800) }
    var supportsZoom: Bool { false }

    required init(url: URL) {
        preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), style: .normal)!
        super.init()
        preview.autostarts = true
        preview.previewItem = url as NSURL
    }

    func zoomIn() {}
    func zoomOut() {}
    func zoomToFit() {}
    func actualSize() {}

    func didAppear() {}
    func tearDown() { preview.close() }
}
