import AppKit
import BlinkShared

final class TextViewer: Viewer {
    private let scroll: NSScrollView
    private let textView: NSTextView
    private var zoom = FontZoom()

    var view: NSView { scroll }
    var preferredContentSize: NSSize? { NSSize(width: 760, height: 800) }

    init(url: URL) {
        (scroll, textView) = makeTextScrollView(wrap: true)
        textView.string = readText(url)
        textView.font = zoom.font
    }

    init(message: String) {
        (scroll, textView) = makeTextScrollView(wrap: true)
        textView.string = message
        textView.font = .systemFont(ofSize: 14)
    }

    func zoomIn() { zoom.step(true); textView.font = zoom.font }
    func zoomOut() { zoom.step(false); textView.font = zoom.font }
    func zoomToFit() { zoom.reset(); textView.font = zoom.font }
    func actualSize() { zoomToFit() }
}
