import Foundation

/// Reads the cell values of an .xlsx workbook into rows of strings, one table per sheet.
/// An .xlsx is a zip of XML parts; /usr/bin/unzip -p pulls each part out (a few ms each),
/// which keeps this in the main executable with no extra framework to load.
/// Shows what Excel shows for the common cases: shared and inline strings, booleans,
/// errors, General numbers, percentages, dates, and a formula's cached result (or the
/// formula itself when the file was saved without results).
struct XLSXWorkbook {
    struct Sheet { var name: String; var rows: [[String]] }
    var sheets: [Sheet] = []

    init?(url: URL) {
        func part(_ path: String) -> Data? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 && !data.isEmpty ? data : nil
        }
        guard let workbook = part("xl/workbook.xml") else { return nil }
        let wb = XMLScan(workbook)
        let rels = XMLScan(part("xl/_rels/workbook.xml.rels") ?? Data())
        let targets = Dictionary(rels.elements("Relationship").compactMap { a -> (String, String)? in
            guard let id = a["Id"], let t = a["Target"] else { return nil }
            return (id, t.hasPrefix("/") ? String(t.dropFirst()) : "xl/" + t)
        }, uniquingKeysWith: { a, _ in a })
        let date1904 = wb.elements("workbookPr").first?["date1904"].map { $0 == "1" || $0 == "true" } ?? false

        let strings = SharedStrings(part("xl/sharedStrings.xml") ?? Data()).strings
        let styles = Styles(part("xl/styles.xml") ?? Data())

        for sheet in wb.elements("sheet") {
            guard let name = sheet["name"], let rid = sheet["r:id"], let path = targets[rid],
                  let xml = part(path) else { continue }
            let rows = SheetReader(xml, strings: strings, styles: styles, date1904: date1904).rows
            sheets.append(Sheet(name: name, rows: rows))
        }
        if sheets.isEmpty { return nil }
    }
}

/// Collects the attributes of every element with a given name.
private final class XMLScan: NSObject, XMLParserDelegate {
    private var found: [String: [[String: String]]] = [:]
    init(_ data: Data) {
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
    }
    func elements(_ name: String) -> [[String: String]] { found[name] ?? [] }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        found[e, default: []].append(attributes)
    }
}

private final class SharedStrings: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current: String?
    private var inText = false
    private var inPhonetic = false
    init(_ data: Data) {
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch e {
        case "si": current = ""
        case "t": inText = true
        case "rPh": inPhonetic = true   // furigana: not part of the visible text
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) {
        if inText, !inPhonetic { current? += s }
    }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        switch e {
        case "t": inText = false
        case "rPh": inPhonetic = false
        case "si": strings.append(current ?? ""); current = nil
        default: break
        }
    }
}

/// Which cell styles are dates or percentages, from styles.xml.
private struct Styles {
    enum Kind { case general, date, percent }
    var kinds: [Kind] = []

    init(_ data: Data) {
        let scan = XMLScan(data)
        var custom: [Int: String] = [:]
        for f in scan.elements("numFmt") {
            if let id = f["numFmtId"].flatMap(Int.init), let code = f["formatCode"] { custom[id] = code }
        }
        // cellXfs' <xf> come after cellStyleXfs' in the file; the cell "s" index is into cellXfs.
        let all = scan.elements("xf")
        let cellXfsCount = scan.elements("cellXfs").first?["count"].flatMap(Int.init) ?? all.count
        for xf in all.suffix(cellXfsCount) {
            let id = xf["numFmtId"].flatMap(Int.init) ?? 0
            kinds.append(Self.kind(id, custom[id]))
        }
    }

    static func kind(_ id: Int, _ code: String?) -> Kind {
        if [9, 10].contains(id) { return .percent }
        if (14...22).contains(id) || (45...47).contains(id) { return .date }
        guard let code else { return .general }
        // Ignore quoted text and [colour] sections before looking for date letters.
        let bare = code.replacingOccurrences(of: #""[^"]*"|\[[^\]]*\]|\\."#, with: "", options: .regularExpression)
        if bare.contains("%") { return .percent }
        if bare.lowercased().range(of: "[dmyhs]", options: .regularExpression) != nil, !bare.contains("0") { return .date }
        return .general
    }

    func kind(_ index: Int?) -> Kind {
        guard let index, index < kinds.count else { return .general }
        return kinds[index]
    }
}

private final class SheetReader: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    private let strings: [String]
    private let styles: Styles
    private let date1904: Bool
    private var cellRef = "", cellType = "", cellStyle: Int?
    private var value: String?, formula: String?, inline: String?
    private var text = ""
    private var inCell = false

    init(_ data: Data, strings: [String], styles: Styles, date1904: Bool) {
        self.strings = strings
        self.styles = styles
        self.date1904 = date1904
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        // Trim empty trailing columns so the grid isn't padded out to Excel's used range.
        let width = rows.map { r in (r.lastIndex { !$0.isEmpty } ?? -1) + 1 }.max() ?? 0
        rows = rows.map { Array($0.prefix(width)) + Array(repeating: "", count: max(0, width - $0.count)) }
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch e {
        case "row":
            let r = a["r"].flatMap(Int.init) ?? rows.count + 1
            while rows.count < r { rows.append([]) }
        case "c":
            inCell = true
            cellRef = a["r"] ?? ""
            cellType = a["t"] ?? "n"
            cellStyle = a["s"].flatMap(Int.init)
            value = nil; formula = nil; inline = nil
        case "v", "f", "t": text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        guard inCell else { return }
        switch e {
        case "v": value = text
        case "f": formula = text
        case "t": inline = (inline ?? "") + text
        case "c":
            inCell = false
            let col = Self.column(cellRef)
            guard !rows.isEmpty, col >= 0 else { return }
            var row = rows[rows.count - 1]
            while row.count <= col { row.append("") }
            row[col] = display()
            rows[rows.count - 1] = row
        default: break
        }
    }

    private func display() -> String {
        switch cellType {
        case "s": return value.flatMap(Int.init).flatMap { $0 < strings.count ? strings[$0] : nil } ?? ""
        case "inlineStr": return inline ?? ""
        case "str", "e": return value ?? ""
        case "b": return value == "1" ? "TRUE" : "FALSE"
        default:
            guard let v = value, let n = Double(v) else { return formula.map { "=" + $0 } ?? "" }
            switch styles.kind(cellStyle) {
            case .percent: return Self.general(n * 100) + "%"
            case .date: return Self.date(n, date1904: date1904)
            case .general: return Self.general(n)
            }
        }
    }

    /// "B12" → 1
    static func column(_ ref: String) -> Int {
        var n = 0
        for c in ref.unicodeScalars {
            guard c.properties.isAlphabetic else { break }
            n = n * 26 + Int(c.value) - 64
        }
        return n - 1
    }

    /// Like Excel's General format: up to 10 significant digits, no trailing zeros.
    static func general(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.10g", n)
        if s.contains("e") { return s }
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func date(_ serial: Double, date1904: Bool) -> String {
        // Day 0 is 1899-12-30 in the 1900 system (Excel's 1900-02-29 bug is absorbed by that).
        let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 30)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let start = cal.date(from: base) else { return general(serial) }
        let d = start.addingTimeInterval(serial * 86400)
        let f = DateFormatter()
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = serial == serial.rounded() ? "yyyy-MM-dd" : (serial < 1 ? "HH:mm" : "yyyy-MM-dd HH:mm")
        return f.string(from: d)
    }
}
