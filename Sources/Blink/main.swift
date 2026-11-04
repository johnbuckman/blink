import AppKit

LaunchTiming.mark("main")

// No nib, no storyboard, no NSDocument: the fewer things AppKit has to load
// and wire up before the first window, the sooner that window appears.
UserDefaults.standard.register(defaults: [
    "NSQuitAlwaysKeepsWindows": false,
    "ApplePersistenceIgnoreState": true,
])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
