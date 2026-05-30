import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: GlobalHotkey?
    private let model = TabListModel()
    private let themeStore = ThemeStore()
    private lazy var settings = SettingsWindowController(themeStore: themeStore)
    private lazy var panel = SearchPanelController(
        model: model,
        themeStore: themeStore,
        onOpenSettings: { [weak self] in self?.settings.show() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "nodia")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // ⌘⇧K
        hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.panel.toggle()
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let search = menu.addItem(withTitle: "Search Tabs  ⌘⇧K", action: #selector(openSearch), keyEquivalent: "")
            search.target = self
            let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "Quit nodia", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // reset so a left-click opens the panel next time
        } else {
            panel.toggle()
        }
    }

    @objc private func openSearch() { panel.show() }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
