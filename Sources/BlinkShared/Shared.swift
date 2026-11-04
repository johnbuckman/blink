import AppKit

/// The interface between the Blink executable and the viewers in libBlinkViewers.dylib.
/// It is an Objective-C protocol on purpose: this module is linked into both images,
/// and the ObjC runtime matches protocols by name, so a class from the dylib conforms
/// to the executable's copy of the protocol.
@objc public protocol BlinkPlugin: NSObjectProtocol {
    init(url: URL)
    var view: NSView { get }
    /// Natural content size in points; .zero = no opinion.
    var preferredSize: NSSize { get }
    var supportsZoom: Bool { get }
    func zoomIn()
    func zoomOut()
    func zoomToFit()
    func actualSize()
    func didAppear()
    func tearDown()
}

/// Opens a file in Blink (a new window), from either image.
public func blinkOpen(_ url: URL) {
    NSApp.delegate?.application?(NSApp, open: [url])
}

/// Reads text in whatever encoding it is in: UTF-8 first, then whatever Foundation
/// detects, then Latin-1 (which never fails).
public func readText(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    if let s = String(data: data, encoding: .utf8) { return s }
    var enc = String.Encoding.utf8
    if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
    return String(data: data, encoding: .isoLatin1) ?? ""
}

/// Font-size zoom shared by the text, CSV and markdown views.
public struct FontZoom {
    public static let defaultSize: CGFloat = 13
    public var size: CGFloat = defaultSize
    public init() {}
    public mutating func step(_ up: Bool) { size = max(6, min(72, up ? size * 1.2 : size / 1.2)).rounded(.toNearestOrEven) }
    public mutating func reset() { size = Self.defaultSize }
    public var font: NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

/// A read-only, selectable text view in a scroll view.
public func makeTextScrollView(wrap: Bool) -> (NSScrollView, NSTextView) {
    let scroll = NSTextView.scrollableTextView()
    let text = scroll.documentView as! NSTextView
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.usesFindBar = true
    text.isIncrementalSearchingEnabled = true
    text.textContainerInset = NSSize(width: 10, height: 10)
    if !wrap {
        scroll.hasHorizontalScroller = true
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
    }
    return (scroll, text)
}
