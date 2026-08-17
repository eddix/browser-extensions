import AppKit
import SwiftUI

/// Manages the standalone Settings window (created lazily, reused).
final class SettingsWindowController {
    private let themeStore: ThemeStore
    private let vaultSettings: VaultSettings
    private let onVaultSettingsChanged: () -> Void
    private var window: NSWindow?

    init(
        themeStore: ThemeStore,
        vaultSettings: VaultSettings,
        onVaultSettingsChanged: @escaping () -> Void
    ) {
        self.themeStore = themeStore
        self.vaultSettings = vaultSettings
        self.onVaultSettingsChanged = onVaultSettingsChanged
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "nodia 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(
                themeStore: themeStore,
                vaultSettings: vaultSettings,
                onVaultSettingsChanged: onVaultSettingsChanged
            ))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
