// Draws Blink's icon (an eye on a blue squircle) into an .iconset, then iconutil makes the .icns.
// Usage: swift tools/make-icon.swift Resources/Blink.icns
import AppKit

let out = CommandLine.arguments[1]
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Blink.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.20, green: 0.62, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.27, green: 0.20, blue: 0.85, alpha: 1))!.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let eye = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let r = NSRect(x: (s - eye.size.width) / 2, y: (s - eye.size.height) / 2, width: eye.size.width, height: eye.size.height)
        eye.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
print("wrote \(out)")
