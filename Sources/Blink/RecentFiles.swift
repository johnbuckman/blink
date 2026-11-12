import AppKit

/// The last twenty files Blink opened, newest first, for the menu-bar icon's menu,
/// where they're grouped under the day they were opened.
enum RecentFiles {
    private static let key = "RecentFiles"
    static let limit = 20

    struct Entry {
        let path: String
        let opened: Date
    }

    static var entries: [Entry] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let path = d["path"] as? String, let opened = d["opened"] as? Date else { return nil }
            return Entry(path: path, opened: opened)
        }
    }

    /// Opening a file again moves it to the top, under today.
    static func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        var list = entries.filter { $0.path != path }
        list.insert(Entry(path: path, opened: Date()), at: 0)
        let raw = list.prefix(limit).map { ["path": $0.path, "opened": $0.opened] as [String: Any] }
        UserDefaults.standard.set(Array(raw), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// "Today", "Yesterday", the weekday within the last week, else the date.
    static func dayTitle(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        let f = DateFormatter()
        if days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEEE")
        } else if cal.component(.year, from: date) == cal.component(.year, from: now) {
            f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        } else {
            f.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        }
        return f.string(from: date)
    }

    /// Menu items for the files, under one header per day. Each opens its file
    /// through `action` on `target`, with the URL as the item's representedObject.
    static func menuItems(target: AnyObject, action: Selector) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        var lastDay: String?
        for entry in entries {
            let day = dayTitle(entry.opened)
            if day != lastDay {
                if lastDay != nil { items.append(.separator()) }
                items.append(.sectionHeader(title: day))
                lastDay = day
            }
            let url = URL(fileURLWithPath: entry.path)
            let item = NSMenuItem(title: url.lastPathComponent, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = url
            item.toolTip = entry.path
            let icon = NSWorkspace.shared.icon(forFile: entry.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if !FileManager.default.fileExists(atPath: entry.path) { item.isEnabled = false }
            items.append(item)
        }
        return items
    }
}
