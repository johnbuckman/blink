import AppKit

/// An arrow drawn on a picture, with an optional label written along it. Points are the
/// picture's (flipped) canvas points; sizes scale with the picture, not the screen, so a
/// saved copy looks the same as the window.
struct Arrow {
    var start: NSPoint
    var end: NSPoint
    var color: NSColor
    var text = ""
    var textColor: NSColor

    /// Outline drawn round the arrow and its text so either reads on any background.
    static func outline(for color: NSColor) -> NSColor {
        luminance(color) > 0.45 ? NSColor(white: 0, alpha: 0.85) : NSColor(white: 1, alpha: 0.9)
    }

    // MARK: Sizes

    static func lineWidth(_ picture: NSSize) -> CGFloat { max(2, min(picture.width, picture.height) * 0.008) }
    static func fontSize(_ picture: NSSize) -> CGFloat { max(12, min(picture.width, picture.height) * 0.045) }

    // MARK: Geometry

    /// The bend: a quadratic curve whose middle bows out by 12% of the arrow's length,
    /// towards whichever side faces away from the picture's centre (the outside edge).
    func control(_ picture: NSSize) -> NSPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return start }
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        var px = -dy / len, py = dx / len
        if px * (mid.x - picture.width / 2) + py * (mid.y - picture.height / 2) < 0 { px = -px; py = -py }
        let bow = len * 0.12
        return NSPoint(x: mid.x + px * bow, y: mid.y + py * bow)
    }

    /// The curved shaft (to be stroked) and the head (to be filled), the head pointing
    /// along the curve's direction where it arrives.
    func shapes(width w: CGFloat, picture: NSSize) -> (shaft: NSBezierPath, head: NSBezierPath) {
        let c = control(picture)
        let tx = end.x - c.x, ty = end.y - c.y
        let tl = max(hypot(tx, ty), 0.001)
        let ux = tx / tl, uy = ty / tl
        let px = -uy, py = ux
        let len = hypot(end.x - start.x, end.y - start.y)
        let headLen = min(w * 4.5, len * 0.6), headHalf = w * 2.4
        let base = NSPoint(x: end.x - ux * headLen, y: end.y - uy * headLen)

        let shaft = NSBezierPath()
        shaft.move(to: start)
        // Quadratic curve start → base via c, as a cubic.
        shaft.curve(to: base,
                    controlPoint1: NSPoint(x: start.x + (c.x - start.x) * 2 / 3, y: start.y + (c.y - start.y) * 2 / 3),
                    controlPoint2: NSPoint(x: base.x + (c.x - base.x) * 2 / 3, y: base.y + (c.y - base.y) * 2 / 3))
        shaft.lineWidth = w
        shaft.lineCapStyle = .round

        let head = NSBezierPath()
        head.move(to: NSPoint(x: base.x + px * headHalf, y: base.y + py * headHalf))
        head.line(to: end)
        head.line(to: NSPoint(x: base.x - px * headHalf, y: base.y - py * headHalf))
        // Back in a little, so the head overlaps the shaft's round end.
        head.line(to: NSPoint(x: base.x + ux * w * 0.3, y: base.y + uy * w * 0.3))
        head.close()
        head.lineJoinStyle = .round
        return (shaft, head)
    }

    // MARK: Label

    /// Where each letter of the label goes: written on the shaft itself, each letter
    /// turned to follow the curve, centred along it and always reading left to right. A
    /// label longer than the shaft is made smaller to fit.
    struct Placement {
        var letters: [(text: NSAttributedString, at: NSPoint, angle: CGFloat, width: CGFloat)]
        /// Just after the last letter (or the shaft's middle when there are none): the caret.
        var caret: (at: NSPoint, angle: CGFloat, height: CGFloat)
    }

    /// The label's letters are drawn in black or white, whichever stands out from the
    /// arrow's colour, with a halo in the arrow's colour: readable on the line itself and
    /// where they spill off it onto the picture, and still clearly this arrow's label.
    var letterColor: NSColor { Self.outline(for: textColor).withAlphaComponent(1) }

    func attributedText(_ picture: NSSize, size: CGFloat, text: String? = nil) -> NSAttributedString {
        NSAttributedString(string: text ?? self.text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: letterColor,
        ])
    }

    func placement(_ picture: NSSize) -> Placement {
        let w = Self.lineWidth(picture)
        let c = control(picture)
        // Sample the shaft (the curve, short of the head) into points with distances along it.
        let len = hypot(end.x - start.x, end.y - start.y)
        let tl = max(hypot(end.x - c.x, end.y - c.y), 0.001)
        let headLen = min(w * 4.5, len * 0.6)
        let base = NSPoint(x: end.x - (end.x - c.x) / tl * headLen, y: end.y - (end.y - c.y) / tl * headLen)
        var pts: [NSPoint] = (0...64).map { i in
            let t = CGFloat(i) / 64, u = 1 - t
            return NSPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * base.x,
                           y: u * u * start.y + 2 * u * t * c.y + t * t * base.y)
        }
        let reversed = base.x < start.x
        if reversed { pts.reverse() }   // so the text runs left to right
        var dist: [CGFloat] = [0]
        for k in 1..<pts.count { dist.append(dist[k - 1] + hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y)) }
        let total = dist.last!
        func at(_ d: CGFloat) -> (NSPoint, CGFloat) {
            // Past either end (a label too long even at its smallest), carry straight on.
            if d < 0 || d > total {
                let (k0, k1) = d < 0 ? (0, 1) : (pts.count - 2, pts.count - 1)
                let a = pts[k0], b = pts[k1]
                let angle = atan2(b.y - a.y, b.x - a.x)
                let from = d < 0 ? a : b, over = d < 0 ? d : d - total
                return (NSPoint(x: from.x + cos(angle) * over, y: from.y + sin(angle) * over), angle)
            }
            var k = 1
            while k < dist.count - 1 && dist[k] < d { k += 1 }
            let a = pts[k - 1], b = pts[k]
            let f = (d - dist[k - 1]) / max(dist[k] - dist[k - 1], 0.001)
            return (NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), atan2(b.y - a.y, b.x - a.x))
        }

        // Shrunk until it fits on the shaft, with a little room left at each end, but never
        // below half the normal size (and 14 points): smaller than that can't be read.
        // Still too long at that size, it wraps onto more lines, side by side along the curve.
        let fit = total * 0.85
        var size = Self.fontSize(picture)
        let full = attributedText(picture, size: size).size().width
        if full > fit, full > 0 { size = max(size * fit / full, min(max(Self.fontSize(picture) * 0.5, 14), size)) }
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        func width(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        var lines: [String] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            if let last = lines.last, width(last + " " + word) <= fit {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        if lines.isEmpty { lines = [""] }

        let lineHeight = font.ascender - font.descender
        var letters: [(NSAttributedString, NSPoint, CGFloat, CGFloat)] = []
        var caret = (at: NSPoint.zero, angle: CGFloat(0))
        for (n, lineText) in lines.enumerated() {
            // Lines stack across the curve, centred on it: line 0 on top.
            let across = (CGFloat(n) - CGFloat(lines.count - 1) / 2) * lineHeight
            func place(_ d: CGFloat) -> (NSPoint, CGFloat) {
                let (p, a) = at(d)
                return (NSPoint(x: p.x - sin(a) * across, y: p.y + cos(a) * across), a)
            }
            let str = attributedText(picture, size: size, text: lineText)
            let line = CTLineCreateWithAttributedString(str)
            let w = str.size().width
            let begin = (total - w) / 2
            let ns = lineText as NSString
            var idx = 0
            while idx < ns.length {
                let r = ns.rangeOfComposedCharacterSequence(at: idx)
                let x0 = CTLineGetOffsetForStringIndex(line, r.location, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, r.location + r.length, nil)
                let (p, angle) = place(begin + (x0 + x1) / 2)
                letters.append((str.attributedSubstring(from: r), p, angle, x1 - x0))
                idx = r.location + r.length
            }
            caret = place(text.isEmpty ? total / 2 : begin + w + size * 0.08)
        }
        return Placement(letters: letters.map { (text: $0.0, at: $0.1, angle: $0.2, width: $0.3) },
                         caret: (at: caret.at, angle: caret.angle, height: font.capHeight * 1.3))
    }

    /// Draws arrows and their labels into the current (flipped) graphics context, in
    /// canvas points.
    static func draw(_ arrows: [Arrow], picture: NSSize) {
        let w = lineWidth(picture)
        let ctx = NSGraphicsContext.current!.cgContext
        for a in arrows {
            // A little see-through, like the labels: one layer per arrow, so its outline,
            // shaft and head don't darken each other where they overlap.
            ctx.saveGState()
            ctx.setAlpha(0.8)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { ctx.endTransparencyLayer(); ctx.restoreGState() }
            let (shaft, head) = a.shapes(width: w, picture: picture)
            let rim = w * 0.3
            outline(for: a.color).set()
            shaft.lineWidth = w + rim * 2
            shaft.stroke()
            head.lineWidth = rim * 2
            head.stroke()
            head.fill()
            a.color.set()
            shaft.lineWidth = w
            shaft.stroke()
            head.fill()
        }
        for a in arrows where !a.text.isEmpty {
            let place = a.placement(picture)
            let rim = a.textColor
            // The label sits on the line, a little see-through so the line shows under it.
            // One transparency layer for the whole label, so overlapping outlines and
            // letters don't darken each other.
            let layerCtx = NSGraphicsContext.current!.cgContext
            layerCtx.saveGState()
            layerCtx.setAlpha(0.8)
            layerCtx.beginTransparencyLayer(auxiliaryInfo: nil)
            // Outline first, then the fill on top: the heavy font's overlapping strokes
            // would otherwise show as lines inside the letters.
            for pass in 0..<2 {
                for l in place.letters {
                    let ctx = NSGraphicsContext.current!.cgContext
                    ctx.saveGState()
                    ctx.translateBy(x: l.at.x, y: l.at.y)
                    ctx.rotate(by: l.angle)
                    let s = NSMutableAttributedString(attributedString: l.text)
                    let range = NSRange(location: 0, length: s.length)
                    if pass == 0 {
                        s.addAttributes([.foregroundColor: NSColor.clear, .strokeColor: rim, .strokeWidth: 9], range: range)
                    }
                    // Centred on the point both ways: capitals straddle the line.
                    let font = l.text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
                    s.draw(at: NSPoint(x: -l.width / 2, y: -font.ascender + font.capHeight / 2))
                    ctx.restoreGState()
                }
            }
            layerCtx.endTransparencyLayer()
            layerCtx.restoreGState()
        }
    }

    // MARK: Colour

    /// Bright annotation colours, tried in this order; plain white and black are the fallback.
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.17, blue: 0.17, alpha: 1),     // red
        NSColor(srgbRed: 1, green: 0.85, blue: 0.0, alpha: 1),      // yellow
        NSColor(srgbRed: 0.15, green: 0.85, blue: 1, alpha: 1),     // cyan
        NSColor(srgbRed: 0.25, green: 1, blue: 0.35, alpha: 1),     // green
        NSColor(srgbRed: 1, green: 0.2, blue: 0.85, alpha: 1),      // magenta
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
    ]

    static let paletteNames = ["red", "yellow", "cyan", "green", "magenta", "white", "black"]

    var colorName: String {
        Self.palette.firstIndex(of: color).map { Self.paletteNames[$0] } ?? "coloured"
    }

    /// The palette colour that stands out most from the given background: highest
    /// contrast, with bright colours preferred over white and black, and a penalty for
    /// being the same hue as the background (a red arrow on a red sunset).
    /// Colours already on other arrows are skipped while any are left, so each arrow and
    /// its label can be told apart.
    static func pick(against bg: NSColor, avoiding used: [NSColor] = []) -> NSColor {
        let fresh = palette.filter { !used.contains($0) }
        return (fresh.isEmpty ? palette : fresh).max { score($0, bg) < score($1, bg) }!
    }

    static func score(_ c: NSColor, _ bg: NSColor) -> CGFloat {
        let l1 = luminance(c), l2 = luminance(bg)
        var s = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        let c1 = c.usingColorSpace(.sRGB)!, c2 = bg.usingColorSpace(.sRGB)!
        if c1.saturationComponent > 0.5 {
            s *= 1.35
            let dh = abs(c1.hueComponent - c2.hueComponent)
            if c2.saturationComponent > 0.25, min(dh, 1 - dh) < 0.08 { s *= 0.5 }
        }
        return s
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        guard let c = c.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}

/// A small copy of the picture for "what colour is behind this?" questions.
struct ColorSampler {
    private let pixels: [UInt8]
    private let side = 64
    private let picture: NSSize

    init?(_ image: CGImage, picture: NSSize) {
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &buf, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        pixels = buf
        self.picture = picture
    }

    /// Average colour of a rectangle in canvas points (y down, like the bitmap rows).
    func average(_ rect: NSRect) -> NSColor {
        let sx = CGFloat(side) / picture.width, sy = CGFloat(side) / picture.height
        let x0 = max(0, min(side - 1, Int(rect.minX * sx))), x1 = max(x0, min(side - 1, Int(rect.maxX * sx)))
        let y0 = max(0, min(side - 1, Int(rect.minY * sy))), y1 = max(y0, min(side - 1, Int(rect.maxY * sy)))
        var r = 0, g = 0, b = 0, n = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let i = (y * side + x) * 4
                r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2]); n += 1
            }
        }
        let d = CGFloat(max(n, 1)) * 255
        return NSColor(srgbRed: CGFloat(r) / d, green: CGFloat(g) / d, blue: CGFloat(b) / d, alpha: 1)
    }
}

