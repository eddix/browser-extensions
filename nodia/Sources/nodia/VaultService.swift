import Foundation
import NodiaCore

/// Owns the vault store and the local HTTP endpoint the browser extension
/// posts to. This is what replaced the standalone Rust backend: nodia is
/// already a resident app with a settings window, so a second daemon bought
/// nothing but a second thing to keep alive — and split ownership of one pile
/// of Markdown between two processes.
final class VaultService {
    private let settings: VaultSettings
    private var store: VaultStore?
    private var server: LocalHTTPServer?

    init(settings: VaultSettings) {
        self.settings = settings
    }

    var vaultStore: VaultStore? { store }

    func start() {
        // Opening the vault can hang: if it sits under ~/Documents, macOS
        // holds the first access until the privacy prompt is answered — and a
        // menu-bar-only app may never show that prompt on its own. Say so,
        // otherwise the settings window just reads "未启动" forever.
        setStatus("正在打开收藏库…")
        do {
            let store = try VaultStore(vaultRoot: settings.vaultURL)
            self.store = store

            let api = VaultAPI(store: store) { [weak self] links in
                self?.summarize(links, store: store)
            }
            let server = LocalHTTPServer(
                port: UInt16(settings.port),
                tokenProvider: { [weak settings] in settings?.token ?? "" },
                handler: { api.handle($0) }
            )
            try server.start()
            self.server = server
            setStatus("监听 127.0.0.1:\(settings.port)")
        } catch {
            setStatus("启动失败：\(error.localizedDescription)")
            Log.write("vault service: \(error.localizedDescription)")
        }
    }

    func restart() {
        server?.stop()
        server = nil
        store = nil
        start()
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak settings] in settings?.status = text }
    }

    /// Page text exists only for this call: it is never written to the vault
    /// and is dropped as soon as a summary comes back (or doesn't).
    private func summarize(_ links: [VaultLink], store: VaultStore) {
        let summarizer = Summarizer(config: settings.summarizer)
        Task.detached(priority: .background) {
            for link in links {
                guard let summary = await summarizer.summarize(
                    title: link.title, url: link.url, content: link.content ?? ""
                ) else { continue }
                if store.updateSummary(url: link.url, summary: summary) {
                    Log.write("vault: summarized \(link.url)")
                }
            }
        }
    }
}
