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
            Self.seedQuickOpenFileIfMissing(vaultRoot: settings.vaultURL)

            let api = VaultAPI(store: store) {
                [weak self] title, url, content, onProgress, done in
                self?.preview(
                    title: title, url: url, content: content,
                    onProgress: onProgress, done: done
                ) ?? done(VaultAPI.Preview(summary: nil, reason: "服务未就绪"))
            }
            let server = LocalHTTPServer(
                port: UInt16(settings.port),
                tokenProvider: { [weak settings] in settings?.token ?? "" },
                handler: { request, completion in api.handle(request, completion: completion) }
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

    /// Writes the quick-open template file once, with worked examples.
    ///
    /// A config format nobody knows exists is a feature nobody uses — the file
    /// documents itself by being there and already working. Never overwritten.
    private static func seedQuickOpenFileIfMissing(vaultRoot: URL) {
        let file = vaultRoot.appendingPathComponent(QuickOpenStore.fileName)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try QuickOpenStore.starterFile().write(to: file, atomically: true, encoding: .utf8)
            Log.write("quick-open: seeded \(QuickOpenStore.fileName)")
        } catch {
            Log.write("quick-open: could not seed template file — \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak settings] in settings?.status = text }
    }

    /// Summarizes for the review panel. Page text exists only for this call —
    /// it is never written to the vault, and is dropped as soon as a summary
    /// comes back (or doesn't).
    ///
    /// The summary now happens *before* saving rather than after: the extension
    /// shows it, and only what you approve reaches disk.
    private func preview(
        title: String,
        url: String,
        content: String,
        onProgress: @escaping @Sendable (Summarizer.Progress) -> Void,
        done: @escaping @Sendable (VaultAPI.Preview) -> Void
    ) {
        let summarizer = Summarizer(config: settings.summarizer)

        // Routing decides whether the text may leave this machine at all, and
        // says so in words the panel can show.
        if case .skip(let reason) = summarizer.route(for: url) {
            return done(VaultAPI.Preview(summary: nil, reason: reason))
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return done(VaultAPI.Preview(summary: nil, reason: "没抓到正文"))
        }

        Task.detached(priority: .userInitiated) {
            switch await summarizer.summarize(
                title: title, url: url, content: content, onProgress: onProgress
            ) {
            case .summarized(let result):
                done(VaultAPI.Preview(
                    summary: result.summary, keywords: result.keywords, reason: nil
                ))
            case .failed(let reason):
                // The reason is shown in the panel. The log still has the
                // long form, but you shouldn't need it to know what happened.
                done(VaultAPI.Preview(summary: nil, keywords: [], reason: reason))
            }
        }
    }
}
