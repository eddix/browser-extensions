import AppKit
import SwiftUI

/// Manages the standalone Settings window (created lazily, reused).
final class SettingsWindowController {
    private let themeStore: ThemeStore
    private var window: NSWindow?

    init(themeStore: ThemeStore) { self.themeStore = themeStore }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "nodia 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(themeStore: themeStore))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
