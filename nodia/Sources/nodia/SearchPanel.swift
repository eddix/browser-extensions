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
        model.mode = .search
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
            onDedupeCluster: { [weak self] cluster in
                self?.confirmAndClose(cluster.duplicates,
                                      summary: "“\(cluster.keeper.title)” 的 \(cluster.duplicates.count) 个重复")
            },
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
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)

            // Standard text-editing shortcuts. An accessory app has no Edit menu,
            // so we forward these straight to the field editor (first responder).
            if cmd {
                switch event.keyCode {
                case 0:  NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil); return nil // ⌘A
                case 7:  NSApp.sendAction(Selector(("cut:")), to: nil, from: nil); return nil        // ⌘X
                case 8:  NSApp.sendAction(Selector(("copy:")), to: nil, from: nil); return nil       // ⌘C
                case 9:  NSApp.sendAction(Selector(("paste:")), to: nil, from: nil); return nil      // ⌘V
                case 6:  NSApp.sendAction(Selector((shift ? "redo:" : "undo:")), to: nil, from: nil); return nil // ⌘Z / ⌘⇧Z
                case 32: self.model.query = ""; return nil                                           // ⌘U clear field
                case 2:  self.model.toggleMode(); return nil                                         // ⌘D duplicates
                default: break
                }
            }

            switch event.keyCode {
            case 125: self.model.moveSelection(1); return nil   // ↓
            case 126: self.model.moveSelection(-1); return nil  // ↑
            case 36, 76:                                        // return / enter
                if self.model.mode == .duplicates {
                    if cmd { self.dedupeAll() } else { self.dedupeSelectedCluster() }
                } else {
                    self.activateSelected()
                }
                return nil
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
        if !model.query.isEmpty { model.query = "" }
        else if model.mode == .duplicates { model.toggleMode() }
        else { hide() }
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

    // MARK: dedupe

    private func dedupeSelectedCluster() {
        guard let cluster = model.selectedCluster else { return }
        confirmAndClose(cluster.duplicates,
                        summary: "“\(cluster.keeper.title)” 的 \(cluster.duplicates.count) 个重复")
    }

    private func dedupeAll() {
        let duplicates = model.allDuplicates
        confirmAndClose(duplicates, summary: "全部 \(duplicates.count) 个重复标签")
    }

    private func confirmAndClose(_ duplicates: [TabEntry], summary: String) {
        guard !duplicates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "关闭重复标签?"
        alert.informativeText = "将关闭\(summary),每个页面保留最近活跃的一份。此操作不可撤销。"
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if case .permissionDenied = Deduper.execute(closing: duplicates) {
            presentPermissionAlert()
            return
        }
        // Arc rewrites StorableSidebar.json after closing; refresh shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.model.reload()
            self?.model.selectedIndex = 0
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
