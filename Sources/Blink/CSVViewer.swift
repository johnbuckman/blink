import AppKit
import BlinkShared

/// RFC 4180 parsing: quoted fields may hold the delimiter, doubled quotes and newlines.
/// The delimiter (comma, semicolon or tab) is whichever is most common in the first line.
func parseCSV(_ text: String) -> [[String]] {
    let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
    let delim: Character = [",", ";", "\t"].max { a, b in
        firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
    } ?? ","

    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var it = text.makeIterator()
    var pending: Character? = nil
    while let c = pending ?? it.next() {
        pending = nil
        if inQuotes {
            if c == "\"" {
                if let n = it.next() {
                    if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                } else { inQuotes = false }
            } else { field.append(c) }
        } else if c == "\"" && field.isEmpty {
            inQuotes = true
        } else if c == delim {
            row.append(field); field = ""
        } else if c == "\n" || c == "\r" || c == "\r\n" {
            row.append(field); field = ""
            rows.append(row); row = []
        } else {
            field.append(c)
        }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

final class CSVViewer: NSObject, Viewer, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var header: [String] = []
    private var rows: [[String]] = []
    private var zoom = FontZoom()

    var view: NSView { scroll }
    var preferredContentSize: NSSize? {
        let w = table.tableColumns.reduce(0) { $0 + $1.width + table.intercellSpacing.width } + 20
        let h = CGFloat(min(rows.count, 40) + 1) * (table.rowHeight + table.intercellSpacing.height) + 30
        return NSSize(width: min(max(w, 400), 1400), height: max(h, 200))
    }

    init(url: URL) {
        super.init()
        var all = parseCSV(readText(url))
        // Treat the first row as a header unless the file has only one row.
        if all.count > 1 { header = all.removeFirst() }
        rows = all
        let columns = max(header.count, rows.map(\.count).max() ?? 0)

        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.style = .plain

        // Row-number column, then one per field.
        addColumn(id: "#", title: "")
        for c in 0..<columns {
            addColumn(id: "\(c)", title: c < header.count ? header[c] : "Column \(c + 1)")
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        applyZoom()
    }

    private func addColumn(id: String, title: String) {
        let col = NSTableColumn(identifier: .init(id))
        col.title = title
        col.minWidth = 24
        table.addTableColumn(col)
    }

    /// Size columns to their content (sampling the first 500 rows), capped so one
    /// long cell can't make a column a screen wide.
    private func sizeColumns() {
        let font = zoom.font
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: zoom.size)]
        let sample = rows.prefix(500)
        for (i, col) in table.tableColumns.enumerated() {
            var w: CGFloat
            if i == 0 {
                w = ("\(rows.count)" as NSString).size(withAttributes: attrs).width
            } else {
                let c = i - 1
                w = (col.title as NSString).size(withAttributes: bold).width
                for r in sample where c < r.count {
                    w = max(w, (r[c] as NSString).size(withAttributes: attrs).width)
                }
            }
            col.width = min(w + 14, 420)
        }
    }

    private func applyZoom() {
        table.rowHeight = ceil(zoom.size * 1.45)
        sizeColumns()
        table.reloadData()
    }

    func zoomIn() { zoom.step(true); applyZoom() }
    func zoomOut() { zoom.step(false); applyZoom() }
    func zoomToFit() { zoom.reset(); applyZoom() }
    func actualSize() { zoomToFit() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.cell?.truncatesLastVisibleLine = true
            return f
        }()
        cell.font = zoom.font
        if id.rawValue == "#" {
            cell.stringValue = "\(row + 1)"
            cell.textColor = .tertiaryLabelColor
            cell.alignment = .right
        } else {
            let c = Int(id.rawValue)!
            let r = rows[row]
            cell.stringValue = c < r.count ? r[c] : ""
            cell.textColor = .labelColor
            cell.alignment = Double(cell.stringValue.replacingOccurrences(of: ",", with: "")) != nil ? .right : .left
            cell.toolTip = cell.stringValue.count > 40 ? cell.stringValue : nil
        }
        return cell
    }
}
