import AppKit

/// Zoom actions travel the responder chain to the frontmost DocumentWindowController.
/// The selectors are prefixed so PDFView's and NSScrollView's own zoomIn:/zoomOut:
/// never intercept them.
@objc protocol ZoomActions {
    func blinkZoomIn(_ sender: Any?)
    func blinkZoomOut(_ sender: Any?)
    func blinkZoomToFit(_ sender: Any?)
    func blinkActualSize(_ sender: Any?)
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Blink", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Blink", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close All Windows", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Blink", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.showOpenPanel(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Show in Finder", action: #selector(DocumentWindowController.showInFinder(_:)), keyEquivalent: "R")
        file.addItem(withTitle: "Edit", action: #selector(DocumentWindowController.editFile(_:)), keyEquivalent: "e")
        file.addItem(withTitle: "Open in Preview", action: #selector(DocumentWindowController.openInPreview(_:)), keyEquivalent: "P")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Crop to Selection", action: #selector(DocumentWindowController.cropImage(_:)), keyEquivalent: "k")
        edit.addItem(withTitle: "Draw Arrows", action: #selector(DocumentWindowController.toggleArrows(_:)), keyEquivalent: "A")
        edit.addItem(withTitle: "Draw Boxes", action: #selector(DocumentWindowController.toggleBoxes(_:)), keyEquivalent: "B")
        edit.addItem(withTitle: "Save with Arrows and Boxes", action: #selector(DocumentWindowController.saveWithArrows(_:)), keyEquivalent: "s")
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        // ⌘= is also accepted (see BlinkWindow), since "+" needs Shift on most keyboards.
        view.addItem(withTitle: "Zoom In", action: #selector(ZoomActions.blinkZoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(ZoomActions.blinkZoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(ZoomActions.blinkZoomToFit(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Actual Size", action: #selector(ZoomActions.blinkActualSize(_:)), keyEquivalent: "1")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        add(view, title: "View", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
