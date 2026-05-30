import AppKit

// nodia — menu-bar Arc tab finder. Runs as an accessory app (no Dock icon).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
