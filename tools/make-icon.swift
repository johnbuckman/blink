// Draws Blink's icon — an eye caught mid-blink on an indigo squircle — into an
// .iconset at every size, then iconutil turns it into the .icns.
// Usage: swift tools/make-icon.swift Resources/Blink.icns [preview.png]
import AppKit

let out = CommandLine.arguments[1]
let previewPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Blink.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
}

/// The almond outline of an open eye, centred at (cx, cy).
func almond(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - w / 2, y: cy))
    p.addCurve(to: CGPoint(x: cx + w / 2, y: cy),
               control1: CGPoint(x: cx - w * 0.22, y: cy + h * 0.68), control2: CGPoint(x: cx + w * 0.22, y: cy + h * 0.68))
    p.addCurve(to: CGPoint(x: cx - w / 2, y: cy),
               control1: CGPoint(x: cx + w * 0.22, y: cy - h * 0.68), control2: CGPoint(x: cx - w * 0.22, y: cy - h * 0.68))
    p.closeSubpath()
    return p
}

func draw(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)   // draw in a 1024 grid
    ctx.interpolationQuality = .high

    // Body: Apple's icon grid — 824 pt squircle centred in 1024, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(squircle); ctx.setFillColor(rgb(40, 30, 110)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(92, 72, 238), rgb(52, 36, 160), rgb(24, 18, 84)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A soft glow behind the eye.
    ctx.drawRadialGradient(gradient([rgb(140, 200, 255, 0.55), rgb(140, 200, 255, 0)], [0, 1]),
                           startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 400, options: [])

    // The eye.
    let cx: CGFloat = 512, cy: CGFloat = 470
    let eye = almond(cx: cx, cy: cy, w: 640, h: 400)
    ctx.saveGState()
    ctx.addPath(eye); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(255, 255, 255), rgb(222, 230, 248)], [0, 1]),
                           start: CGPoint(x: cx, y: cy + 140), end: CGPoint(x: cx, y: cy - 140),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Iris: cyan into blue, with a darker rim.
    let irisR: CGFloat = 132
    let irisC = CGPoint(x: cx, y: cy - 6)
    ctx.drawRadialGradient(gradient([rgb(120, 240, 255), rgb(40, 150, 255), rgb(20, 70, 200), rgb(12, 40, 130)],
                                    [0, 0.45, 0.88, 1]),
                           startCenter: irisC, startRadius: 0, endCenter: irisC, endRadius: irisR, options: [])
    // Pupil and catch-lights.
    ctx.setFillColor(rgb(10, 14, 40))
    ctx.fillEllipse(in: CGRect(x: irisC.x - 56, y: irisC.y - 56, width: 112, height: 112))
    ctx.setFillColor(rgb(255, 255, 255, 0.95))
    ctx.fillEllipse(in: CGRect(x: irisC.x + 18, y: irisC.y + 28, width: 46, height: 46))
    ctx.setFillColor(rgb(255, 255, 255, 0.6))
    ctx.fillEllipse(in: CGRect(x: irisC.x - 52, y: irisC.y - 50, width: 20, height: 20))

    // Upper eyelid, coming down: the blink. Filled in the body colour so the eye reads
    // as half-closed, with a bright lid edge.
    let lidY = cy + 70
    let lid = CGMutablePath()
    lid.move(to: CGPoint(x: cx - 360, y: cy - 10))
    lid.addCurve(to: CGPoint(x: cx + 360, y: cy - 10),
                 control1: CGPoint(x: cx - 200, y: lidY + 40), control2: CGPoint(x: cx + 200, y: lidY + 40))
    lid.addLine(to: CGPoint(x: cx + 360, y: cy + 400))
    lid.addLine(to: CGPoint(x: cx - 360, y: cy + 400))
    lid.closeSubpath()
    ctx.addPath(lid); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(70, 54, 200), rgb(110, 92, 250)], [0, 1]),
                           start: CGPoint(x: cx, y: lidY), end: CGPoint(x: cx, y: cy + 240), options: [])
    ctx.restoreGState()

    // Eye outline.
    ctx.addPath(eye)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.95)); ctx.setLineWidth(18); ctx.setLineJoin(.round)
    ctx.strokePath()

    // The lid's closing edge.
    let edge = CGMutablePath()
    edge.move(to: CGPoint(x: cx - 312, y: cy + 6))
    edge.addCurve(to: CGPoint(x: cx + 312, y: cy + 6),
                  control1: CGPoint(x: cx - 180, y: lidY + 34), control2: CGPoint(x: cx + 180, y: lidY + 34))
    ctx.addPath(edge)
    ctx.setStrokeColor(rgb(255, 255, 255)); ctx.setLineWidth(22); ctx.setLineCap(.round)
    ctx.strokePath()

    // Glassy top sheen.
    ctx.drawLinearGradient(gradient([rgb(255, 255, 255, 0.18), rgb(255, 255, 255, 0)], [0, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func png(_ img: CGImage) -> Data { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])! }

for size in [16, 32, 128, 256, 512] {
    try! png(draw(size)).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! png(draw(size * 2)).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
if let previewPath { try! png(draw(1024)).write(to: URL(fileURLWithPath: previewPath)) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
print("wrote \(out)")
