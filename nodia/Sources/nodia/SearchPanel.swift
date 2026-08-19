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
    /// Held so tinting doesn't have to search the view tree for it.
    private var glassView: NSView?

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
        // Every other piece of panel state gets reset here; the form used to be
        // the exception, and it outranks the mode in the view. So walking away
        // from a half-filled template — esc out of the panel, or click
        // elsewhere and let it resign key — meant the next time you hit the
        // hotkey you were handed that same abandoned form instead of a search
        // field, with no way to tell why.
        model.cancelFilling()
        model.query = ""
        model.mode = .search
        model.selectedIndex = 0

        let panel = panel ?? makePanel()
        self.panel = panel
        let resolved = themeStore.resolved
        panel.appearance = resolved.nsAppearance
        // Re-read on every show rather than observed: the panel is built once
        // and shown constantly, and the usual route into Settings — the footer
        // button — closes the panel on the way, so the next show is the first
        // moment a change there could reach the screen anyway.
        //
        // Passed even when nil: switching back to a palette without a tint has
        // to *clear* the previous one, and `if let` would quietly leave the old
        // color on the glass while the appearance flipped to light.
        if let glass = glassView {
            SystemGlass.tint(glass, resolved.palette.tint.map(NSColor.init),
                             strength: CGFloat(resolved.tintStrength))
        }

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
            contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window's own alpha stays at 1 and gets no setting, because glass
        // needs the window composited normally: any alpha below 1 sends the
        // whole window through an offscreen buffer that is then blended with
        // the very backdrop the effect just sampled, which washes the
        // refraction and the edge highlights back out. A window-opacity slider
        // could only turn the panel back into a plain tinted blur.
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let root = SearchView(
            model: model,
            themeStore: themeStore,
            onActivate: { [weak self] row in self?.activate(row: row) },
            onDedupeCluster: { [weak self] cluster in
                self?.confirmAndClose(cluster.duplicates,
                                      summary: "“\(cluster.keeper.title)” 的 \(cluster.duplicates.count) 个重复")
            },
            onTakeCandidate: { [weak self] choice in self?.model.takeCandidate(choice) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: PanelMetrics.size)
        // The glass *contains* the content rather than sitting behind it, so it
        // owns the background and the shape — the SwiftUI side draws neither.
        //
        // It lays its innards out with constraints, so the content has to stop
        // carrying an autoresizing mask or the two layout systems deadlock:
        // measured, the glass's own render view and the holder around our
        // content both came out 0×0, which drew no glass at all while the
        // content spilled out of its zero-sized parent and looked almost right.
        host.translatesAutoresizingMaskIntoConstraints = false
        let shell = SystemGlass.wrap(host, cornerRadius: PanelMetrics.cornerRadius)
        shell.frame = NSRect(origin: .zero, size: PanelMetrics.size)
        shell.autoresizingMask = [.width, .height]

        // The clip is what makes the window's shadow follow the panel's shape.
        //
        // A window shadow is cut from the window's alpha mask, and the glass
        // fills that mask corner to corner — its backdrop and SDF layers cover
        // the full rect whatever the corner radius says the *visible* shape is.
        // So the system draws a hard dark rectangle around a rounded panel.
        // Clipping to a rounded layer trims the alpha to the shape you can
        // actually see, and the shadow follows it.
        //
        // Reproduced in isolation, and only for windows that become key: an
        // ordinary `orderFront` panel has a shadow faint enough to hide the
        // square. `invalidateShadow()` doesn't help and neither does turning
        // the shadow on after the window is up — both recompute from a mask
        // that was square to begin with. It was never a question of timing.
        let clip = NSView(frame: NSRect(origin: .zero, size: PanelMetrics.size))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = PanelMetrics.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.autoresizingMask = [.width, .height]
        clip.addSubview(shell)
        panel.contentView = clip
        glassView = shell
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
                // Mode switches would swap the list behind a form that stays
                // on screen, leaving the footer describing one thing and the
                // panel showing another.
                case 2 where self.model.filling == nil: self.model.toggleMode(); return nil          // ⌘D duplicates
                case 5 where self.model.filling == nil: self.model.toggleDomainMode(); return nil    // ⌘G by-domain
                case 17 where self.model.filling == nil: self.model.toggleQuickOpenMode(); return nil // ⌘T quick open
                default: break
                }
            }

            switch event.keyCode {
            case 125: self.model.moveSelection(1); return nil   // ↓
            case 126: self.model.moveSelection(-1); return nil  // ↑
            case 48 where self.model.filling != nil:            // ⇥
                // Taken from AppKit's own key-view loop on purpose: it would
                // wander into the gear button and wrap in its own order, and
                // the form wants exactly one cycle through the parameters.
                self.model.focusNextField()
                return nil
            case 36, 76:                                        // return / enter
                if self.model.filling != nil {
                    self.openFilled()
                } else if self.model.mode == .duplicates {
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
        // Backing out of a half-filled template returns to search, not out of the
        // panel — you were mid-task.
        if model.filling != nil { model.cancelFilling() }
        else if !model.query.isEmpty { model.query = "" }
        else if model.mode == .duplicates { model.toggleMode() }
        else if model.mode == .byDomain { model.toggleDomainMode() }
        else if model.mode == .quickOpen { model.toggleQuickOpenMode() }
        else { hide() }
    }

    private func activateSelected() {
        guard let tab = model.selectedTab else { return }
        activate(row: tab)
    }

    /// The single door every row goes through, whether you pressed ⏎ or clicked
    /// it.
    ///
    /// Two doors is how the click broke: it went straight to `Activator`, which
    /// treats `tab.url` as a URL, and for a template that string is still a
    /// template. A placeholder in the host position makes `URL(string:)` return
    /// nil and the click does nothing at all; one in the path survives as
    /// percent-encoded braces and opens a real 404. Neither says a word about
    /// the parameter form you were supposed to get.
    private func activate(row: TabEntry) {
        guard let template = model.template(for: row) else { return activateTab(row) }
        // A template with parameters isn't a URL yet — collect them first. One
        // without any already is, so asking would be a form with nothing on it.
        if model.beginFilling(row) { return }
        // Through `expand` rather than straight to `URL(string:)`, so both ways
        // of opening a template judge the same config by the same rule.
        // `URL(string:)` alone accepts things that can't be opened — anything
        // without a host sails through it — and the score was booked before
        // anyone found out, so a typo'd template climbed the ranking on
        // openings that never happened.
        guard let url = template.expand([:]) else { return }
        model.quickOpenState.recordOpen(template: template, values: [:])
        openQuickOpen(url)
    }

    /// ⏎ from the form: open with what's there.
    ///
    /// The one thing that stops it is a parameter still holding nothing, and
    /// then it jumps you to that field rather than refusing — the answer to
    /// "why won't it open" should be the cursor sitting in the reason.
    private func openFilled() {
        guard let filling = model.filling else { return }
        if let blank = model.firstBlankField {
            if blank != filling.focus { model.focusField(blank) }
            return
        }
        guard let url = model.fillingURL else { return }
        model.quickOpenState.recordOpen(template: filling.template, values: filling.values)
        model.cancelFilling()
        openQuickOpen(url)
    }

    /// Raise the tab already showing this URL, or open it.
    ///
    /// Switching counts as a use of the template either way — it's how you got
    /// there, and the ranking should say so.
    private func openQuickOpen(_ url: URL) {
        hide()
        if let live = model.liveTab(for: url) {
            Log.write("quick-open: switching to open tab \(url.absoluteString)")
            if case .permissionDenied = Activator.activate(live) { presentPermissionAlert() }
            return
        }
        NSWorkspace.shared.open(url)
        Log.write("quick-open: opened \(url.absoluteString)")
    }

    private func activateTab(_ tab: TabEntry) {
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
