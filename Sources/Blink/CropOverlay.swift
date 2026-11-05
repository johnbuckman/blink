import AppKit

/// What's drawn over a picture with the mouse.
///
/// Normally, a rectangle to crop to: drag on the picture to draw one, drag one of its
/// eight handles to resize it, or drag inside it to move it. Esc, or a click outside it,
/// clears it.
///
/// In arrow mode, each drag draws an arrow, coloured to stand out from what's under it.
/// Typing straight afterwards labels the arrow at its tail; Return or Esc finishes the
/// label. ⌘Z takes arrows back off.
///
/// Coordinates are the picture's points (the canvas is flipped, so y runs down like the
/// image's pixels).
final class CropOverlay: NSView {
    private(set) var selection: NSRect? { didSet { needsDisplay = true; onChange?(selection != nil) } }
    var onChange: ((Bool) -> Void)?

    var arrowMode = false { didSet { editing = nil; window?.invalidateCursorRects(for: self) } }
    private(set) var arrows: [Arrow] = [] { didSet { needsDisplay = true; onArrowsChange?(!arrows.isEmpty) } }
    var onArrowsChange: ((Bool) -> Void)?
    /// Supplies a small copy of the picture once it has decoded.
    var sampler: (() -> ColorSampler?)?
    /// The arrow whose label is being typed.
    private var editing: Int?
    private var pending: Arrow?

    private enum Drag { case new(NSPoint), move(NSPoint, NSRect), handle(Int, NSRect), arrow(NSPoint) }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Drawing works on the first click, even when the window was in the background.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Screen-constant sizes, in canvas points, at the current zoom.
    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var handleSize: CGFloat { 9 / magnification }

    func clear() { selection = nil }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Arrow.draw(arrows + (pending.map { [$0] } ?? []), picture: bounds.size)
        if let i = editing, i < arrows.count {
            // A caret where the next letter goes.
            let a = arrows[i]
            let c = a.placement(bounds.size).caret
            let caret = NSBezierPath()
            caret.move(to: NSPoint(x: c.at.x - sin(c.angle) * c.height / 2, y: c.at.y + cos(c.angle) * c.height / 2))
            caret.line(to: NSPoint(x: c.at.x + sin(c.angle) * c.height / 2, y: c.at.y - cos(c.angle) * c.height / 2))
            caret.lineWidth = max(2 / magnification, c.height * 0.08)
            a.letterColor.setStroke()
            caret.stroke()
        }
        guard let sel = selection else { return }
        // Dim everything outside the selection.
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: sel).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        outside.fill()

        let line = 1 / magnification
        let border = NSBezierPath(rect: sel.insetBy(dx: -line / 2, dy: -line / 2))
        border.lineWidth = line
        NSColor.white.setStroke()
        border.stroke()
        let dashes = NSBezierPath(rect: sel.insetBy(dx: -line / 2, dy: -line / 2))
        dashes.lineWidth = line
        dashes.setLineDash([4 * line, 4 * line], count: 2, phase: 0)
        NSColor.black.setStroke()
        dashes.stroke()

        for r in handleRects(sel) {
            let h = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            h.fill()
            h.lineWidth = line
            NSColor.controlAccentColor.setStroke()
            h.stroke()
        }
    }

    /// Corners and edge midpoints, clockwise from top-left.
    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    private func handleRects(_ r: NSRect) -> [NSRect] {
        let s = handleSize
        return handlePoints(r).map { NSRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard !arrowMode, let sel = selection else { return }
        addCursorRect(sel, cursor: .openHand)
        let cursors: [NSCursor] = [.crosshair, .resizeUpDown, .crosshair, .resizeLeftRight,
                                   .crosshair, .resizeUpDown, .crosshair, .resizeLeftRight]
        for (r, c) in zip(handleRects(sel), cursors) { addCursorRect(r.insetBy(dx: -2 / magnification, dy: -2 / magnification), cursor: c) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = clamp(convert(event.locationInWindow, from: nil))
        if arrowMode {
            editing = nil
            drag = .arrow(p)
            return
        }
        if let sel = selection {
            let slop = 3 / magnification
            if let i = handleRects(sel).firstIndex(where: { $0.insetBy(dx: -slop, dy: -slop).contains(p) }) {
                drag = .handle(i, sel)
                return
            }
            if sel.contains(p) {
                drag = .move(p, sel)
                NSCursor.closedHand.push()
                return
            }
        }
        drag = .new(p)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .arrow(let start):
            pending = makeArrow(start, p)
        case .new(let start):
            selection = rect(start, p)
        case .move(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
            selection = r
        case .handle(let i, let r):
            // Move the dragged corner/edge; the opposite one stays put.
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            if [0, 6, 7].contains(i) { minX = p.x }
            if [2, 3, 4].contains(i) { maxX = p.x }
            if [0, 1, 2].contains(i) { minY = p.y }
            if [4, 5, 6].contains(i) { maxY = p.y }
            selection = rect(NSPoint(x: minX, y: minY), NSPoint(x: maxX, y: maxY))
        case nil:
            break
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if case .arrow = drag {
            drag = nil
            if let a = pending, hypot(a.end.x - a.start.x, a.end.y - a.start.y) * magnification >= 10 {
                setArrows(arrows + [a])
                editing = arrows.count - 1
            }
            pending = nil
            needsDisplay = true
            return
        }
        if case .move = drag { NSCursor.pop() }
        drag = nil
        // A click without a drag clears the selection rather than leaving a 0×0 one.
        if let sel = selection, sel.width * magnification < 3 || sel.height * magnification < 3 { selection = nil }
        window?.invalidateCursorRects(for: self)
    }

    override func cancelOperation(_ sender: Any?) {
        if editing != nil { editing = nil; needsDisplay = true } else { selection = nil }
    }

    // MARK: Arrows

    private func makeArrow(_ start: NSPoint, _ end: NSPoint) -> Arrow {
        let picture = bounds.size
        let sample = sampler?()
        // The colour behind the arrow, then behind where its label will go.
        let w = Arrow.lineWidth(picture) * 3
        let box = NSRect(x: min(start.x, end.x) - w, y: min(start.y, end.y) - w,
                         width: abs(end.x - start.x) + 2 * w, height: abs(end.y - start.y) + 2 * w)
        let used = arrows.map(\.color)
        let color = sample.map { Arrow.pick(against: $0.average(box), avoiding: used) }
            ?? Arrow.palette.first { !used.contains($0) } ?? Arrow.palette[0]
        // The label is written right alongside the arrow, outlined like it, in its colour.
        let a = Arrow(start: start, end: end, color: color, textColor: color)
        return a
    }

    /// Changes the arrows undoably.
    private func setArrows(_ new: [Arrow]) {
        let old = arrows
        window?.undoManager?.registerUndo(withTarget: self) { $0.setArrows(old); $0.editing = nil }
        window?.undoManager?.setActionName("Arrow")
        arrows = new
    }

    func clearArrows() { setArrows([]) }

    override func keyDown(with event: NSEvent) {
        guard let i = editing, i < arrows.count else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76, 53:             // Return, Enter, Esc: done
            editing = nil
            needsDisplay = true
        case 51:                     // Delete
            var a = arrows
            if !a[i].text.isEmpty { a[i].text.removeLast(); arrows = a }
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return super.keyDown(with: event)
            }
            var a = arrows
            if a[i].text.isEmpty { setArrows(a) }   // one undo step for the whole label
            a[i].text += chars
            arrows = a
        }
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
