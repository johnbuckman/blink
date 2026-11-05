import AppKit

/// Word (.doc, .docx) and RTF documents, through AppKit's own importers: the text
/// keeps its fonts, styles, tables and pictures, on a white page.
final class WordViewer: Viewer {
    private let scroll: NSScrollView
    private let textView: NSTextView

    var view: NSView { scroll }
    var preferredContentSize: NSSize? { NSSize(width: 820, height: 900) }

    init(url: URL) {
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 48, height: 40)
        scroll.backgroundColor = .white
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 5

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let doc = try? NSAttributedString(url: url, options: options, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(doc)
        } else {
            textView.string = "Blink can't read this document. Use Edit to open it in Word."
            textView.font = .systemFont(ofSize: 14)
        }
        // Documents are written for a white page; keep their colours in Dark Mode too.
        scroll.appearance = NSAppearance(named: .aqua)
    }

    func zoomIn() { scroll.animator().magnification = min(5, scroll.magnification * 1.25) }
    func zoomOut() { scroll.animator().magnification = max(0.25, scroll.magnification / 1.25) }
    func zoomToFit() { scroll.animator().magnification = 1 }
    func actualSize() { zoomToFit() }
}
