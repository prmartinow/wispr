import AppKit

// Menu-bar agent app with a Dock icon so it can be pinned/launched like a normal Mac app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
