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

/// A grid for CSV files and for .xlsx sheets. Spreadsheets get Excel's column letters and
/// row numbers, plus sheet tabs along the bottom when there is more than one sheet.
final class CSVViewer: NSObject, Viewer, NSTableViewDataSource, NSTableViewDelegate {
    private let container = NSView()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var header: [String] = []
    private var rows: [[String]] = []
    private var zoom = FontZoom()
    private var workbook: XLSXWorkbook?

    var view: NSView { container }
    var preferredContentSize: NSSize? {
        let w = table.tableColumns.reduce(0) { $0 + $1.width + table.intercellSpacing.width } + 20
        let h = CGFloat(min(rows.count, 40) + 1) * (table.rowHeight + table.intercellSpacing.height) + 30
        return NSSize(width: min(max(w, 500), 1400), height: max(h, 240) + (workbook.map { $0.sheets.count > 1 ? 30 : 0 } ?? 0))
    }

    init(url: URL) {
        super.init()
        setUp(tabs: nil)
        var all = parseCSV(readText(url))
        // Treat the first row as a header unless the file has only one row.
        var header: [String] = []
        if all.count > 1 { header = all.removeFirst() }
        load(header: header, rows: all)
    }

    init(workbook: XLSXWorkbook) {
        self.workbook = workbook
        super.init()
        var tabs: NSSegmentedControl?
        if workbook.sheets.count > 1 {
            let t = NSSegmentedControl(labels: workbook.sheets.map(\.name), trackingMode: .selectOne,
                                       target: nil, action: nil)
            t.target = self
            t.action = #selector(sheetChosen(_:))
            t.selectedSegment = 0
            t.controlSize = .small
            tabs = t
        }
        setUp(tabs: tabs)
        showSheet(0)
    }

    private func setUp(tabs: NSSegmentedControl?) {
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        var constraints = [
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ]
        if let tabs {
            tabs.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tabs)
            constraints += [
                tabs.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 5),
                tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            ]
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func sheetChosen(_ sender: NSSegmentedControl) { showSheet(sender.selectedSegment) }

    private func showSheet(_ i: Int) {
        guard let workbook, i < workbook.sheets.count else { return }
        let rows = workbook.sheets[i].rows
        let width = rows.map(\.count).max() ?? 0
        load(header: (0..<width).map(Self.columnName), rows: rows)
    }

    /// 0 → "A", 26 → "AA"
    static func columnName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    private func load(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
        for col in table.tableColumns { table.removeTableColumn(col) }
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        // Row-number column, then one per field.
        addColumn(id: "#", title: "")
        for c in 0..<columns {
            addColumn(id: "\(c)", title: c < header.count ? header[c] : "Column \(c + 1)")
        }
        applyZoom()
        table.scrollRowToVisible(0)
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
