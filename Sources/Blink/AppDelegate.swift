import AppKit
import ServiceManagement

/// Blink never quits on its own: an already-running Blink shows a file in ~0.2 s
/// against ~0.6 s for a cold launch. With no windows open it leaves the Dock and
/// waits as a menu-bar icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// Set by the menu-bar icon's Quit, the only way to actually quit (besides logout).
    private var reallyQuit = false

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
        // A plain launch just comes forward, with its menus: File ▸ Open… (⌘O) opens a file.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [self] in offerLoginItemOnce() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    /// Clicking Blink's Dock icon (or launching it again) brings it forward with its menus,
    /// leaving the menu bar if it was waiting there. No Open panel: that's File ▸ Open….
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q (and the Dock's Quit) closes Blink's windows but leaves it waiting in the
    /// menu bar. Only Quit in the menu-bar icon's menu, or logging out / restarting,
    /// really quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let systemQuit = event?.eventID == kAEQuitApplication && event?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
            || event?.paramDescriptor(forKeyword: kAEQuitReason) != nil
        if reallyQuit || systemQuit { return .terminateNow }
        for window in NSApp.windows where window.windowController is DocumentWindowController {
            window.performClose(nil)
        }
        if DocumentWindowController.isEmpty { enterMenuBarMode() }
        return .terminateCancel
    }

    @objc private func quitCompletely(_ sender: Any?) {
        reallyQuit = true
        NSApp.terminate(sender)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
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
            menu.addItem(withTitle: "Quit Blink", action: #selector(quitCompletely(_:)), keyEquivalent: "q").target = self
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
