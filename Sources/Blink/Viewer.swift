import AppKit
import BlinkShared

/// One per window: shows a single file and knows how to zoom it.
protocol Viewer: AnyObject {
    var view: NSView { get }
    /// Natural content size in points, used to size the window before "fit".
    /// nil = no opinion (the window uses a sensible default).
    var preferredContentSize: NSSize? { get }
    var supportsZoom: Bool { get }
    func zoomIn()
    func zoomOut()
    func zoomToFit()
    func actualSize()
    /// Called once the view is in a window that has its final size.
    func didAppear()
    /// Called when the window closes: stop timers, players, file watchers.
    func tearDown()
    /// Pictures can be cropped to a rectangle drawn over them (see CropOverlay).
    var canCrop: Bool { get }
    var hasCropSelection: Bool { get }
    /// Saves the selection as a new file next to the original and returns it.
    func crop() throws -> URL?
    /// Arrows with labels drawn over a picture; saved into a copy of it.
    var arrowMode: Bool { get set }
    var hasArrows: Bool { get }
    func saveWithArrows() throws -> URL?
}

extension Viewer {
    var preferredContentSize: NSSize? { nil }
    var supportsZoom: Bool { true }
    func didAppear() {}
    func tearDown() {}
    var canCrop: Bool { false }
    var hasCropSelection: Bool { false }
    func crop() throws -> URL? { nil }
    var arrowMode: Bool { get { false } set {} }
    var hasArrows: Bool { false }
    func saveWithArrows() throws -> URL? { nil }
}

enum FileKind {
    case image, pdf, csv, xlsx, word, email, spreadsheet, gpx, video, audio, text, markdown

    /// Decided from the extension first; files with no (or an unknown) extension
    /// are sniffed, which is how John's extensionless `…_GPX` downloads open.
    static func of(_ url: URL) -> FileKind {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "tif", "tiff", "avif", "heic", "heif", "webp", "bmp", "ico", "icns":
            return .image
        case "pdf": return .pdf
        case "csv", "tsv": return .csv
        case "eml", "emlx": return .email
        case "xlsx": return .xlsx
        case "rtf", "doc", "docx": return .word
        case "xls", "numbers", "pptx", "ppt", "key", "pages": return .spreadsheet
        case "gpx": return .gpx
        case "mp4", "mov", "m4v": return .video
        case "m4a", "mp3", "wav", "aac", "aiff", "aif", "flac": return .audio
        case "md", "markdown", "mdown": return .markdown
        case "txt", "text", "log", "adp", "tcl", "js", "json", "xml", "sh", "py", "css": return .text
        default: return sniff(url)
        }
    }

    private static func sniff(_ url: URL) -> FileKind {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .text }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 1024)) ?? Data()
        let bytes = [UInt8](head)
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + sig.count && Array(bytes[offset..<offset + sig.count]) == sig
        }
        if starts([0xFF, 0xD8, 0xFF]) || starts([0x89, 0x50, 0x4E, 0x47]) || starts(Array("GIF8".utf8))
            || starts(Array("II*".utf8)) || starts(Array("MM".utf8) + [0, 42]) { return .image }
        if starts(Array("ftypavif".utf8), at: 4) || starts(Array("ftypheic".utf8), at: 4) { return .image }
        if starts(Array("ftyp".utf8), at: 4) { return .video }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .spreadsheet }  // zip: Office documents
        let text = String(decoding: head, as: UTF8.self)
        if text.contains("<gpx") { return .gpx }
        return .text
    }

    @MainActor func makeViewer(_ url: URL) -> Viewer {
        switch self {
        case .image: return ImageViewer(url: url)
        case .csv: return CSVViewer(url: url)
        case .xlsx:
            // Our own reader gives a zoomable grid; Quick Look is the fallback for odd files.
            if let wb = XLSXWorkbook(url: url) { return CSVViewer(workbook: wb) }
            return PluginViewer.make("BlinkQuickLookViewer", url)
        case .word: return WordViewer(url: url)
        case .text: return TextViewer(url: url)
        case .pdf: return PluginViewer.make("BlinkPDFViewer", url)
        case .email: return PluginViewer.make("BlinkEmailViewer", url)
        case .spreadsheet: return PluginViewer.make("BlinkQuickLookViewer", url)
        case .gpx: return PluginViewer.make("BlinkGPXViewer", url)
        case .video: return PluginViewer.make("BlinkVideoViewer", url)
        case .audio: return PluginViewer.make("BlinkAudioViewer", url)
        case .markdown: return PluginViewer.make("BlinkMarkdownViewer", url)
        }
    }
}

/// A viewer living in libBlinkViewers.dylib (see Package.swift for why it's separate).
final class PluginViewer: Viewer {
    private let plugin: BlinkPlugin

    private static let loaded: Bool = {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libBlinkViewers.dylib").path
        // Fallback for `swift run` / running the bare build product: the dylib sits next to the executable.
        let dev = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("libBlinkViewers.dylib").path
        let ok = dlopen(path, RTLD_NOW) != nil || dlopen(dev, RTLD_NOW) != nil
        LaunchTiming.mark("dylib loaded: \(ok)")
        return ok
    }()

    static func make(_ className: String, _ url: URL) -> Viewer {
        guard loaded, let cls = NSClassFromString(className) as? BlinkPlugin.Type else {
            return TextViewer(message: "Blink can't show this file: its viewer library is missing.")
        }
        return PluginViewer(plugin: cls.init(url: url))
    }

    private init(plugin: BlinkPlugin) { self.plugin = plugin }

    var view: NSView { plugin.view }
    var preferredContentSize: NSSize? { plugin.preferredSize == .zero ? nil : plugin.preferredSize }
    var supportsZoom: Bool { plugin.supportsZoom }
    func zoomIn() { plugin.zoomIn() }
    func zoomOut() { plugin.zoomOut() }
    func zoomToFit() { plugin.zoomToFit() }
    func actualSize() { plugin.actualSize() }
    func didAppear() { plugin.didAppear() }
    func tearDown() { plugin.tearDown() }
}
