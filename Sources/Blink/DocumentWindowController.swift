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
        if viewer.canCrop {
            let crop = NSSegmentedControl(labels: ["Crop"], trackingMode: .momentary,
                                          target: self, action: #selector(cropImage(_:)))
            crop.setToolTip("Drag on the picture to choose an area, then Crop saves it as a new file (⌘K)", forSegment: 0)
            crop.controlSize = .small
            crop.segmentStyle = .separated
            crop.isEnabled = false
            crop.sizeToFit()
            (viewer as? ImageViewer)?.onCropSelectionChange = { [weak crop] has in crop?.isEnabled = has }
            controls.insert(crop, at: 0)

            let save = NSSegmentedControl(labels: ["Save"], trackingMode: .momentary,
                                          target: self, action: #selector(saveWithArrows(_:)))
            save.setToolTip("Save a copy of the picture with its arrows (⌘S)", forSegment: 0)
            save.controlSize = .small
            save.segmentStyle = .separated
            save.isEnabled = false
            save.sizeToFit()
            (viewer as? ImageViewer)?.onArrowsChange = { [weak save] has in save?.isEnabled = has }
            controls.insert(save, at: 1)

            let arrow = NSSegmentedControl(labels: ["Arrow"], trackingMode: .selectAny,
                                           target: self, action: #selector(arrowButton(_:)))
            arrow.setToolTip("Draw arrows on the picture; type straight after one to label it (⇧⌘A)", forSegment: 0)
            arrow.controlSize = .small
            arrow.segmentStyle = .separated
            arrow.sizeToFit()
            arrowControl = arrow
            controls.insert(arrow, at: 0)
        }
        if let editor {
            let edit = NSSegmentedControl(labels: ["Edit in \(editor.name)"], trackingMode: .momentary,
                                          target: self, action: #selector(editFile(_:)))
            edit.setToolTip("Open this file in \(editor.name) (⌘E)", forSegment: 0)
            edit.controlSize = .small
            edit.segmentStyle = .separated
            edit.sizeToFit()
            controls.insert(edit, at: 0)
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

    @objc func blinkZoomIn(_ sender: Any?) { viewer.zoomIn() }
    @objc func blinkZoomOut(_ sender: Any?) { viewer.zoomOut() }
    @objc func blinkZoomToFit(_ sender: Any?) { viewer.zoomToFit() }
    @objc func blinkActualSize(_ sender: Any?) { viewer.actualSize() }

    @objc func zoomControl(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: viewer.zoomOut()
        case 1: viewer.zoomIn()
        case 2: viewer.zoomToFit()
        default: viewer.actualSize()
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// After a crop or save: the new file's full path goes on the clipboard (to paste into
    /// a chat or a terminal), and the file opens in its own window.
    private static func saved(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        open(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @objc func cropImage(_ sender: Any?) {
        do {
            guard let out = try viewer.crop() else { NSSound.beep(); return }
            Self.saved(out)
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc func arrowButton(_ sender: NSSegmentedControl) {
        viewer.arrowMode = sender.isSelected(forSegment: 0)
    }

    @objc func toggleArrows(_ sender: Any?) {
        viewer.arrowMode.toggle()
        arrowControl?.setSelected(viewer.arrowMode, forSegment: 0)
    }

    @objc func saveWithArrows(_ sender: Any?) {
        do {
            guard let out = try viewer.saveWithArrows() else { NSSound.beep(); return }
            Self.saved(out)
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
            return viewer.hasCropSelection
        case #selector(toggleArrows(_:)):
            item.state = viewer.arrowMode ? .on : .off
            return viewer.canCrop
        case #selector(saveWithArrows(_:)):
            return viewer.hasArrows
        case #selector(editFile(_:)):
            item.title = editor.map { "Edit in \($0.name)" } ?? "Edit"
            return editor != nil
        default:
            return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        viewer.tearDown()
        Self.open.removeAll { $0 === self }
        if Self.open.isEmpty { (NSApp.delegate as? AppDelegate)?.lastWindowClosed() }
    }
}
