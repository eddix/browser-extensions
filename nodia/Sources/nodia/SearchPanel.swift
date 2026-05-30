import AppKit
import SwiftUI
import NodiaCore

/// Borderless floating panel that can become key (so the search field can
/// receive typing) even though the app is an accessory.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the search panel: builds it lazily, centers + shows it, installs a local
/// key monitor for ↑↓/⏎/esc while visible, and routes activation.
final class SearchPanelController: NSObject, NSWindowDelegate {
    private let model: TabListModel
    private let themeStore: ThemeStore
    private let onOpenSettings: () -> Void
    private var panel: KeyPanel?
    private var keyMonitor: Any?

    init(model: TabListModel, themeStore: ThemeStore, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.themeStore = themeStore
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        model.reload()
        model.query = ""
        model.selectedIndex = 0

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = themeStore.resolved.nsAppearance
        center(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        DispatchQueue.main.async { [weak self] in self?.model.requestFocus() }
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    // MARK: building

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let root = SearchView(
            model: model,
            themeStore: themeStore,
            onActivate: { [weak self] tab in self?.activate(tab) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12
        ))
    }

    // MARK: keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125: self.model.moveSelection(1); return nil   // ↓
            case 126: self.model.moveSelection(-1); return nil  // ↑
            case 36, 76: self.activateSelected(); return nil    // return / enter
            case 53: self.handleEscape(); return nil            // esc
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleEscape() {
        if model.query.isEmpty { hide() } else { model.query = "" }
    }

    private func activateSelected() {
        guard let tab = model.selectedTab else { return }
        activate(tab)
    }

    private func activate(_ tab: TabEntry) {
        hide()
        if case .permissionDenied = Activator.activate(tab) {
            presentPermissionAlert()
        }
    }

    private func openSettings() {
        hide()
        onOpenSettings()
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要「自动化」权限"
        alert.informativeText = "请到 系统设置 › 隐私与安全性 › 自动化,允许 nodia 控制 Arc,然后重试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
