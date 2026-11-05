// Makes Blink the default app for every file type it views.
// Usage: swift tools/set-defaults.swift "/Applications/AI Apps/Blink.app" [--dry-run]
import AppKit
import UniformTypeIdentifiers

let app = URL(fileURLWithPath: CommandLine.arguments[1])
let dryRun = CommandLine.arguments.contains("--dry-run")
let extensions = ["jpg", "jpeg", "png", "gif", "tif", "tiff", "avif", "heic",
                  "pdf", "csv", "eml", "xlsx", "gpx", "mp4", "m4a", "txt", "md",
                  "rtf", "doc", "docx", "js", "tcl", "adp"]

var types: [UTType] = []
for ext in extensions {
    guard let t = UTType(filenameExtension: ext), !types.contains(t) else { continue }
    types.append(t)
}

let sem = DispatchSemaphore(value: 0)
var failed = 0
for t in types {
    let before = NSWorkspace.shared.urlForApplication(toOpen: t)?.deletingPathExtension().lastPathComponent ?? "none"
    if dryRun {
        print("\(t.identifier) (\(t.preferredFilenameExtension ?? "")): currently \(before)")
        continue
    }
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) { error in
        if let error { failed += 1; print("✗ \(t.identifier): \(error.localizedDescription)") }
        else { print("✓ \(t.identifier) (was \(before))") }
        sem.signal()
    }
    sem.wait()
}
exit(failed == 0 ? 0 : 1)
