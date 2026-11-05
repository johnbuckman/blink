import AppKit

/// Accepts ⌘= as Zoom In: "+" needs Shift on most layouts, and Preview takes both.
final class BlinkWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "=" {
            (windowController as? DocumentWindowController)?.blinkZoomIn(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One window per opened file. Opening the same file twice brings its window forward.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ZoomActions {
    private static var open: [DocumentWindowController] = []
    static var isEmpty: Bool { open.isEmpty }

    let url: URL
    let viewer: Viewer
    /// The app the Edit button opens this file in; nil = no Edit button.
    let editor: Editor?
    private weak var arrowControl: NSSegmentedControl?
    private weak var cropControl: NSSegmentedControl?
    private weak var saveControl: NSSegmentedControl?
    /// A paused video's frame being marked up, laid over the player.
    private var markup: ImageViewer?
    /// Where the picture tools act: the still being marked up, else the window's own viewer.
    private var tools: Viewer { markup ?? viewer }
    /// Over a playing video while Arrow or Box stays chosen: a drag on the video pauses on
    /// that frame and starts drawing straight away.
    private var catcher: ToolCatcher?
    private var armedArrow: Bool { arrowControl?.isSelected(forSegment: 0) ?? false }
    private var armedBox: Bool { boxControl?.isSelected(forSegment: 0) ?? false }
    private weak var boxControl: NSSegmentedControl?

    static func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = open.first(where: { $0.url == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        LaunchTiming.mark("open \(url.lastPathComponent)")
        let controller = DocumentWindowController(url: url)
        open.append(controller)
        controller.present()
    }

    private init(url: URL) {
        self.url = url
        let kind = FileKind.of(url)
        self.viewer = kind.makeViewer(url)
        LaunchTiming.mark("viewer made")
        self.editor = Editor.of(url, kind: kind)
        LaunchTiming.mark("editor found")
        let window = BlinkWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 200)
        LaunchTiming.mark("NSWindow made")
        super.init(window: window)
        window.delegate = self
        window.title = url.lastPathComponent
        window.representedURL = url
        window.contentView = viewer.view

        // Zoom buttons as a titlebar accessory with text labels: an NSToolbar with
        // SF Symbol images costs ~90 ms at launch, this costs a few.
        let control = NSSegmentedControl(labels: ["−", "+", "Fit", "1:1"], trackingMode: .momentary,
                                         target: nil, action: nil)
        for (i, tip) in ["Zoom Out (⌘−)", "Zoom In (⌘+)", "Zoom to Fit (⌘0)", "Actual Size (⌘1)"].enumerated() {
            control.setToolTip(tip, forSegment: i)
            control.setWidth(i < 2 ? 26 : 34, forSegment: i)
        }
        control.target = self
        control.action = #selector(zoomControl(_:))
        control.controlSize = .small
        control.segmentStyle = .separated
        control.isEnabled = viewer.supportsZoom
        control.sizeToFit()
        var controls: [NSControl] = [control]
        if viewer.canCrop || viewer.canMarkUpFrames {
            let crop = NSSegmentedControl(labels: ["Crop"], trackingMode: .momentary,
                                          target: self, action: #selector(cropImage(_:)))
            crop.setToolTip("Drag on the picture to choose an area, then Crop saves it as a new file (⌘K)", forSegment: 0)
            crop.controlSize = .small
            crop.segmentStyle = .separated
            crop.isEnabled = false
            crop.sizeToFit()
            crop.isEnabled = viewer.canMarkUpFrames    // on a video, Crop first pauses on the frame
            cropControl = crop
            controls.insert(crop, at: 0)

            let save = NSSegmentedControl(labels: ["Save"], trackingMode: .momentary,
                                          target: self, action: #selector(saveWithArrows(_:)))
            save.setToolTip("Save a copy of the picture with its arrows and boxes (⌘S)", forSegment: 0)
            save.controlSize = .small
            save.segmentStyle = .separated
            save.isEnabled = false
            save.sizeToFit()
            saveControl = save
            controls.insert(save, at: 1)

            let arrow = NSSegmentedControl(labels: ["Arrow"], trackingMode: .selectAny,
                                           target: self, action: #selector(arrowButton(_:)))
            arrow.setToolTip("Draw arrows on the picture; type straight after one to label it (⇧⌘A)", forSegment: 0)
            arrow.controlSize = .small
            arrow.segmentStyle = .separated
            arrow.sizeToFit()
            arrowControl = arrow
            controls.insert(arrow, at: 0)

            let box = NSSegmentedControl(labels: ["Box"], trackingMode: .selectAny,
                                         target: self, action: #selector(boxButton(_:)))
            box.setToolTip("Draw boxes on the picture; type straight after one to label it (⇧⌘B)", forSegment: 0)
            box.controlSize = .small
            box.segmentStyle = .separated
            box.sizeToFit()
            boxControl = box
            controls.insert(box, at: 1)
        }
        if let iv = viewer as? ImageViewer { wire(iv) }
        if let editor {
            let edit = NSSegmentedControl(labels: ["Edit in \(editor.name)"], trackingMode: .momentary,
                                          target: self, action: #selector(editFile(_:)))
            edit.setToolTip("Open this file in \(editor.name) (⌘E)", forSegment: 0)
            edit.controlSize = .small
            edit.segmentStyle = .separated
            edit.sizeToFit()
            controls.insert(edit, at: 0)
        }
        // Pictures and PDFs can go to Preview too, for what Blink doesn't do (rotate, export, print…).
        if kind == .image || kind == .pdf {
            let preview = NSSegmentedControl(labels: ["Preview"], trackingMode: .momentary,
                                             target: self, action: #selector(openInPreview(_:)))
            preview.setToolTip("Open this file in Preview", forSegment: 0)
            preview.controlSize = .small
            preview.segmentStyle = .separated
            preview.sizeToFit()
            controls.insert(preview, at: 0)
        }
        let gap: CGFloat = 10
        let width = controls.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(controls.count - 1)
        // A little taller than the buttons, with them raised, so they sit inside the
        // title bar rather than on the edge of the content below it.
        let lift: CGFloat = 6
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: width + 12, height: control.frame.height + lift))
        var x: CGFloat = 0
        for c in controls {
            c.frame.origin = NSPoint(x: x, y: lift)
            holder.addSubview(c)
            x += c.frame.width + gap
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        LaunchTiming.mark("window + zoom buttons made")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func present() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Start at the content's natural size, shrunk to fit 90% of the screen.
        let visible = screen.visibleFrame
        let chrome = window.frame.height - window.contentLayoutRect.height
        let maxW = visible.width * 0.9, maxH = visible.height * 0.9 - chrome
        var size = viewer.preferredContentSize ?? NSSize(width: 900, height: 700)
        let scale = min(1, maxW / max(size.width, 1), maxH / max(size.height, 1))
        size = NSSize(width: max(size.width * scale, window.minSize.width),
                      height: max(size.height * scale, window.minSize.height - chrome))
        window.setContentSize(size)

        if let last = Self.open.dropLast().last?.window, last.isVisible {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26))
        } else {
            window.center()
        }
        LaunchTiming.mark("sized")
        window.makeKeyAndOrderFront(nil)
        LaunchTiming.mark("ordered front")
        viewer.didAppear()
        LaunchTiming.mark("window shown: \(url.lastPathComponent)")
        if LaunchTiming.enabled {
            DispatchQueue.main.async { LaunchTiming.mark("first runloop turn after window") }
        }
    }

    // MARK: Zoom

    @objc func blinkZoomIn(_ sender: Any?) { tools.zoomIn() }
    @objc func blinkZoomOut(_ sender: Any?) { tools.zoomOut() }
    @objc func blinkZoomToFit(_ sender: Any?) { tools.zoomToFit() }
    @objc func blinkActualSize(_ sender: Any?) { tools.actualSize() }

    @objc func zoomControl(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: tools.zoomOut()
        case 1: tools.zoomIn()
        case 2: tools.zoomToFit()
        default: tools.actualSize()
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// After a crop or save: the new file's full path goes on the clipboard (to paste into
    /// a chat or a terminal), and the file opens in its own window.
    /// A still from a video isn't opened: you're watching, so the video stays in front.
    private static func saved(_ url: URL, open show: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        if show { open(url) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Points the Crop and Save buttons at a picture's selection and marks.
    private func wire(_ iv: ImageViewer) {
        iv.onCropSelectionChange = { [weak self] has in self?.cropControl?.isEnabled = has || (self?.markup == nil && self?.viewer.canMarkUpFrames == true) }
        iv.onArrowsChange = { [weak self] has in self?.saveControl?.isEnabled = has }
    }

    // MARK: Marking up a video frame

    /// Pauses the video and lays its current frame over the player, ready for the
    /// picture tools. Returns false if there's no frame to mark up.
    @discardableResult
    private func beginMarkup() -> Bool {
        if markup != nil { return true }
        guard viewer.canMarkUpFrames, let content = window?.contentView,
              let frame = viewer.pauseAndGrabFrame() else { return false }
        viewer.showControls(false)
        let iv = ImageViewer(frame: frame, video: url)
        markup = iv
        wire(iv)
        cropControl?.isEnabled = false
        iv.onPlayKey = { [weak self] in self?.endMarkup(play: true) }
        iv.view.frame = content.bounds
        iv.view.autoresizingMask = [.width, .height]
        content.addSubview(iv.view)
        iv.didAppear()
        iv.focusMarkup()
        return true
    }

    /// Back to the video: Space, or after Save or Crop.
    private func endMarkup(play: Bool = false) {
        guard let iv = markup else { return }
        iv.tearDown()
        iv.view.removeFromSuperview()
        markup = nil
        viewer.showControls(true)
        // Arrow or Box stays chosen, for the next still.
        cropControl?.isEnabled = true
        saveControl?.isEnabled = false
        window?.makeFirstResponder(viewer.view)
        updateCatcher()
        if play { viewer.resumePlaying() }
    }

    /// Puts the drag-catcher over the video while a tool is chosen and no still is up.
    private func updateCatcher() {
        let want = viewer.canMarkUpFrames && markup == nil && (armedArrow || armedBox)
        if want, catcher == nil, let content = window?.contentView {
            let c = ToolCatcher(frame: content.bounds)
            c.autoresizingMask = [.width, .height]
            c.onDown = { [weak self] in self?.startStillFromDrag() }
            content.addSubview(c)
            catcher = c
        } else if !want {
            catcher?.removeFromSuperview()
            catcher = nil
        }
    }

    /// A drag on the playing video with a tool chosen: pause on this frame and hand the
    /// drag to the still's drawing layer.
    private func startStillFromDrag() -> NSView? {
        catcher?.removeFromSuperview()
        catcher = nil
        guard beginMarkup() else { return nil }
        tools.arrowMode = armedArrow
        tools.boxMode = armedBox
        return markup?.overlayView
    }

    @objc func cropImage(_ sender: Any?) {
        if viewer.canMarkUpFrames, markup == nil { beginMarkup(); return }   // first, pause to draw the area
        do {
            guard let out = try tools.crop() else { NSSound.beep(); return }
            let fromVideo = markup != nil
            endMarkup()
            Self.saved(out, open: !fromVideo)
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc func arrowButton(_ sender: NSSegmentedControl) {
        setTool(arrow: sender.isSelected(forSegment: 0), box: false)
    }

    @objc func boxButton(_ sender: NSSegmentedControl) {
        setTool(arrow: false, box: sender.isSelected(forSegment: 0))
    }

    @objc func toggleArrows(_ sender: Any?) { setTool(arrow: !tools.arrowMode, box: false) }
    @objc func toggleBoxes(_ sender: Any?) { setTool(arrow: false, box: !tools.boxMode) }

    /// Arrow and Box are one-or-the-other.
    private func setTool(arrow: Bool, box: Bool) {
        // On a video, choosing a tool pauses on the frame to mark it up.
        if (arrow || box), viewer.canMarkUpFrames, !beginMarkup() { NSSound.beep(); return }
        tools.arrowMode = arrow
        tools.boxMode = box
        markup?.focusMarkup()
        arrowControl?.setSelected(arrow, forSegment: 0)
        boxControl?.setSelected(box, forSegment: 0)
        updateCatcher()
    }

    @objc func saveWithArrows(_ sender: Any?) {
        do {
            guard let out = try tools.saveWithArrows() else { NSSound.beep(); return }
            let fromVideo = markup != nil
            endMarkup()
            Self.saved(out, open: !fromVideo)
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc func editFile(_ sender: Any?) {
        editor?.open(url)
    }

    @objc func openInPreview(_ sender: Any?) {
        let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        let kind = FileKind.of(url)
        if let preview, kind == .image || kind == .pdf {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else if let app = NSWorkspace.shared.urlForApplication(toOpen: url),
                  app.lastPathComponent != Bundle.main.bundleURL.lastPathComponent {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(blinkZoomIn(_:)), #selector(blinkZoomOut(_:)),
             #selector(blinkZoomToFit(_:)), #selector(blinkActualSize(_:)):
            return viewer.supportsZoom
        case #selector(cropImage(_:)):
            return tools.hasCropSelection || (markup == nil && viewer.canMarkUpFrames)
        case #selector(toggleArrows(_:)):
            item.state = tools.arrowMode ? .on : .off
            return viewer.canCrop || viewer.canMarkUpFrames
        case #selector(toggleBoxes(_:)):
            item.state = tools.boxMode ? .on : .off
            return viewer.canCrop || viewer.canMarkUpFrames
        case #selector(saveWithArrows(_:)):
            return tools.hasArrows
        case #selector(editFile(_:)):
            item.title = editor.map { "Edit in \($0.name)" } ?? "Edit"
            return editor != nil
        default:
            return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        markup?.tearDown()
        catcher?.removeFromSuperview()
        viewer.tearDown()
        Self.open.removeAll { $0 === self }
        if Self.open.isEmpty { (NSApp.delegate as? AppDelegate)?.lastWindowClosed() }
    }
}

/// Lies over a playing video while Arrow or Box is chosen. A drag on it pauses on the
/// frame (onDown returns the still's drawing layer) and is passed on to draw there. The
/// bottom strip is left alone, for the player's controls.
final class ToolCatcher: NSView {
    var onDown: (() -> NSView?)?
    private weak var target: NSView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) && p.y > 70 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        target = onDown?()
        target?.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) { target?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { target?.mouseUp(with: event) }
}
