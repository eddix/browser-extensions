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
            button.image = Self.makeStatusIcon()
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

    /// Monochrome "A+" template glyph for the menu bar (matches the app icon).
    private static func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let H = rect.height, W = rect.width
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)

            // the A
            ctx.setLineWidth(H * 0.155)
            let pad = H * 0.10
            let bl = CGPoint(x: pad, y: pad)
            let br = CGPoint(x: W * 0.60, y: pad)
            let apex = CGPoint(x: (bl.x + br.x) / 2, y: H - pad)
            ctx.move(to: bl); ctx.addLine(to: apex); ctx.addLine(to: br); ctx.strokePath()
            let t: CGFloat = 0.40
            ctx.move(to: CGPoint(x: bl.x + (apex.x - bl.x) * t, y: bl.y + (apex.y - bl.y) * t))
            ctx.addLine(to: CGPoint(x: br.x + (apex.x - br.x) * t, y: br.y + (apex.y - br.y) * t))
            ctx.strokePath()

            // the +
            let pc = CGPoint(x: W * 0.83, y: H * 0.66)
            let pa = H * 0.135
            ctx.setLineWidth(H * 0.135)
            ctx.move(to: CGPoint(x: pc.x - pa, y: pc.y)); ctx.addLine(to: CGPoint(x: pc.x + pa, y: pc.y)); ctx.strokePath()
            ctx.move(to: CGPoint(x: pc.x, y: pc.y - pa)); ctx.addLine(to: CGPoint(x: pc.x, y: pc.y + pa)); ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
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
