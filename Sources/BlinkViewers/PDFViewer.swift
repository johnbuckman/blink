import AppKit
import PDFKit
import BlinkShared

/// PDFView keeps its bottom edge still when it is resized, so a window made taller or
/// shorter slides the page you were reading. Keep the top-left point still instead.
final class TopAnchoredPDFView: PDFView {
    override func setFrameSize(_ newSize: NSSize) {
        guard let doc = document, doc.pageCount > 0, frame.size != .zero,
              let page = page(for: NSPoint(x: bounds.midX, y: bounds.maxY - 2), nearest: true) else {
            super.setFrameSize(newSize); return
        }
        let top = convert(NSPoint(x: bounds.minX, y: bounds.maxY), to: page)
        super.setFrameSize(newSize)
        go(to: PDFDestination(page: page, at: top))
    }
}

@objc(BlinkPDFViewer) final class PDFViewer: NSObject, BlinkPlugin {
    private let pdfView = TopAnchoredPDFView()
    private var pageSize: NSSize?

    var view: NSView { pdfView }
    var preferredSize: NSSize { pageSize ?? .zero }
    var supportsZoom: Bool { true }

    required init(url: URL) {
        super.init()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
            if let page = doc.page(at: 0) {
                let b = page.bounds(for: .cropBox)
                let rotated = page.rotation % 180 != 0
                pageSize = rotated ? NSSize(width: b.height, height: b.width) : b.size
                pageSize!.height += 20   // room for the page-break margin
            }
        }
        pdfView.autoScales = true
    }

    func zoomIn() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    func zoomToFit() {
        // autoScales fits the page width; also make the whole first page visible when
        // the window is shorter than it, like Preview's "Zoom to Fit".
        pdfView.autoScales = false
        guard let page = pdfView.currentPage else { pdfView.autoScales = true; return }
        let b = page.bounds(for: pdfView.displayBox)
        let avail = pdfView.bounds.insetBy(dx: 8, dy: 12).size
        pdfView.scaleFactor = min(avail.width / b.width, avail.height / b.height)
        pdfView.go(to: page)
    }
    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }

    func didAppear() {
        pdfView.autoScales = true
        if let first = pdfView.document?.page(at: 0) { pdfView.go(to: first) }
    }
    func tearDown() {}
}
