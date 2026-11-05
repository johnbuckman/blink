import AppKit

/// What Blink did to make a cropped or arrowed picture, kept on the saved file in an
/// extended attribute, so reopening it shows the original's pixels with the arrows and
/// labels still editable. Arrow positions are in the saved file's pixels.
struct BlinkEdits: Codable {
    struct StoredArrow: Codable {
        var start: [Double], end: [Double]
        var color: [Double], textColor: [Double]
        var text: String
    }

    var version = 1
    /// Full path of the picture it was made from.
    var original: String
    /// The original's size and the part of it that was kept, in its (upright) pixels.
    var originalSize: [Double]
    var region: [Double]
    var arrows: [StoredArrow]

    static let attribute = "com.decentespresso.blink.edits"

    var regionRect: CGRect { CGRect(x: region[0], y: region[1], width: region[2], height: region[3]) }

    static func read(_ url: URL) -> BlinkEdits? {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard got == size, let edits = try? JSONDecoder().decode(BlinkEdits.self, from: data),
              edits.version == 1, edits.region.count == 4, edits.originalSize.count == 2 else { return nil }
        return edits
    }

    func write(_ url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        _ = data.withUnsafeBytes { setxattr(url.path, Self.attribute, $0.baseAddress, data.count, 0, 0) }
    }

    /// Arrows back in canvas points, `pointsPerPixel` being the picture's scale.
    func restoredArrows(pointsPerPixel k: CGFloat) -> [Arrow] {
        func color(_ c: [Double]) -> NSColor {
            guard c.count == 4 else { return Arrow.palette[0] }
            let made = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            return Arrow.palette.first { $0 == made } ?? made
        }
        return arrows.compactMap { a in
            guard a.start.count == 2, a.end.count == 2 else { return nil }
            var arrow = Arrow(start: NSPoint(x: a.start[0] * k, y: a.start[1] * k),
                              end: NSPoint(x: a.end[0] * k, y: a.end[1] * k),
                              color: color(a.color), textColor: color(a.textColor))
            arrow.text = a.text
            return arrow
        }
    }

    static func store(_ a: Arrow, scale: CGFloat, origin: CGPoint) -> StoredArrow {
        func rgba(_ c: NSColor) -> [Double] {
            let s = c.usingColorSpace(.sRGB) ?? c
            return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map(Double.init)
        }
        return StoredArrow(start: [a.start.x * scale - origin.x, a.start.y * scale - origin.y].map(Double.init),
                           end: [a.end.x * scale - origin.x, a.end.y * scale - origin.y].map(Double.init),
                           color: rgba(a.color), textColor: rgba(a.textColor), text: a.text)
    }
}
