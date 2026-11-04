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
        self.viewer = FileKind.of(url).makeViewer(url)
        LaunchTiming.mark("viewer made")
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
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: control.frame.width + 12, height: control.frame.height))
        control.frame.origin = .zero
        holder.addSubview(control)
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
