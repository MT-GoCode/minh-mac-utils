import Cocoa

// Serialize — always-on-top task widget. Accessory app: menu-bar icon only.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, not in Cmd-Tab, never frontmost on its own
app.run()
