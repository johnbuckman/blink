import AppKit
import ServiceManagement

/// Blink never quits on its own: an already-running Blink shows a file in ~0.2 s
/// against ~0.6 s for a cold launch. With no windows open it leaves the Dock and
/// waits as a menu-bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether any file arrived during launch (a plain launch shows an Open panel).
    private var openedSomething = false
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTiming.mark("willFinishLaunching")
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTiming.mark("didFinishLaunching")
        // Command-line paths (`Blink file.jpg`) — Finder and `open` use application(_:open:).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = args.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { open(urls) }

        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if atLogin {
            enterMenuBarMode()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        // Finder's open event normally arrives before this point; give it one
        // more turn of the run loop before deciding nobody asked for a file.
        DispatchQueue.main.async { [self] in
            if !openedSomething { showOpenPanel(nil) }
            offerLoginItemOnce()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOpenPanel(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        openedSomething = true
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        for url in urls {
            DocumentWindowController.open(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    @objc func showOpenPanel(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            open(panel.urls)
        } else if DocumentWindowController.isEmpty {
            enterMenuBarMode()
        }
    }

    // MARK: Menu-bar mode

    /// Called by DocumentWindowController when its last window closes.
    func lastWindowClosed() {
        DispatchQueue.main.async { [self] in
            if DocumentWindowController.isEmpty { enterMenuBarMode() }
        }
    }

    private func enterMenuBarMode() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Blink")
            let menu = NSMenu()
            menu.addItem(withTitle: "Open…", action: #selector(showOpenPanel(_:)), keyEquivalent: "o").target = self
            menu.addItem(.separator())
            let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
            login.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Blink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        statusItem?.isVisible = true
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }

    /// Turn on "Open at Login" the first time Blink runs, so the first file after a
    /// restart opens as fast as the rest. Untick it in the menu-bar menu to undo.
    private func offerLoginItemOnce() {
        let key = "LoginItemOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Open at Login")?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
