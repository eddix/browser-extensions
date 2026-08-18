import Foundation
import NodiaCore

/// Owns the vault store and the local HTTP endpoint the browser extension
/// posts to. This is what replaced the standalone Rust backend: nodia is
/// already a resident app with a settings window, so a second daemon bought
/// nothing but a second thing to keep alive — and split ownership of one pile
/// of Markdown between two processes.
final class VaultService {
    private let settings: VaultSettings
    /// Handed the live store on the main thread every time it changes, nil
    /// included. A push rather than a `vaultStore` property to read, because
    /// the only correct moment to read one is "after the queue below is done",
    /// and a property invites reading it at any other.
    private let onStoreChanged: (VaultStore?) -> Void

    /// `store` and `server` belong to this queue and are touched nowhere else.
    ///
    /// They used to be touched from two threads: startup opens the vault off
    /// the main thread (see `start`), while a vault-path change calls `restart`
    /// from the settings window on main. Interleaved, the two runs each set
    /// both properties and the survivors came from different runs — the old
    /// server, still holding the port and still serving the *old* vault path,
    /// with the new one left as a `server` object that reports "listening"
    /// while owning no socket. The visible symptom was that changing the vault
    /// path did nothing at all, silently.
    private let queue = DispatchQueue(label: "com.eddix.nodia.vault-service")
    private var store: VaultStore?
    private var server: LocalHTTPServer?

    init(settings: VaultSettings, onStoreChanged: @escaping (VaultStore?) -> Void) {
        self.settings = settings
        self.onStoreChanged = onStoreChanged
    }

    /// Off the main thread, always: the vault typically sits under ~/Documents,
    /// and the first access there blocks until the system's privacy prompt is
    /// answered. On main that freezes launch outright — no menu-bar icon, no
    /// hotkey — and a menu-bar-only app may never manage to show the prompt.
    func start() {
        queue.async { [weak self] in self?.open() }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.server?.stop()
            self.server = nil
            self.store = nil
            self.open()
        }
    }

    private func open() {
        // The privacy prompt can hold this for as long as it takes someone to
        // notice it, so say what's happening — otherwise the settings window
        // just reads "未启动" forever and looks like a failure.
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
        // Announced whatever happened, and announced from here rather than only
        // on the happy path: a vault that opened onto a port already in use is
        // still a vault worth searching, and a vault that failed to open has to
        // take the previous one out of the panel rather than leave it there.
        let opened = store
        DispatchQueue.main.async { [onStoreChanged] in onStoreChanged(opened) }
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
