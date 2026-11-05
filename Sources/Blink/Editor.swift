import AppKit

/// The app the Edit button (⌘E) hands a file to. John's choice per format; edit the
/// tables below to change it. Formats with no entry, or whose app isn't installed,
/// get no Edit button.
struct Editor {
    let name: String
    let bundleID: String

    static let photoshop = Editor(name: "Photoshop", bundleID: "com.adobe.Photoshop")
    static let finalCut = Editor(name: "Final Cut Pro", bundleID: "com.apple.FinalCut")
    static let audition = Editor(name: "Audition", bundleID: "com.adobe.Audition")
    static let excel = Editor(name: "Excel", bundleID: "com.microsoft.Excel")
    static let word = Editor(name: "Word", bundleID: "com.microsoft.Word")
    static let powerPoint = Editor(name: "PowerPoint", bundleID: "com.microsoft.Powerpoint")
    static let numbers = Editor(name: "Numbers", bundleID: "com.apple.iWork.Numbers")
    static let pages = Editor(name: "Pages", bundleID: "com.apple.iWork.Pages")
    static let keynote = Editor(name: "Keynote", bundleID: "com.apple.iWork.Keynote")
    static let illustrator = Editor(name: "Illustrator", bundleID: "com.adobe.illustrator")
    static let mapOut = Editor(name: "MapOut", bundleID: "ch.valnova.MapOut")
    static let macDown = Editor(name: "MacDown", bundleID: "com.uranusjr.macdown")
    static let sublime = Editor(name: "Sublime Text", bundleID: "com.sublimetext.4")

    private static let byExtension: [String: Editor] = {
        var map: [String: Editor] = [:]
        func set(_ editor: Editor, _ exts: [String]) { for e in exts { map[e] = editor } }
        set(photoshop, ["jpg", "jpeg", "png", "gif", "tif", "tiff", "avif", "heic", "heif", "webp", "bmp"])
        set(finalCut, ["mp4", "mov", "m4v"])
        set(audition, ["m4a", "mp3", "wav", "aac", "aiff", "aif", "flac"])
        set(excel, ["xlsx", "xls", "csv", "tsv"])
        set(word, ["rtf", "doc", "docx"])
        set(powerPoint, ["pptx", "ppt"])
        set(numbers, ["numbers"])
        set(pages, ["pages"])
        set(keynote, ["key"])
        set(illustrator, ["pdf"])
        set(mapOut, ["gpx"])
        set(macDown, ["md", "markdown", "mdown"])
        set(sublime, ["eml", "emlx"])
        return map
    }()

    /// Kinds that fall back to a text editor when the extension isn't listed above
    /// (.txt, .tcl, .adp, .js, and extensionless text).
    static func of(_ url: URL, kind: FileKind) -> Editor? {
        let editor = byExtension[url.pathExtension.lowercased()] ?? (kind == .text ? sublime : nil)
        guard let editor, editor.appURL != nil else { return nil }
        return editor
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    func open(_ url: URL) {
        guard let app = appURL else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }
}
