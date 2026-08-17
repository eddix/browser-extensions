import Foundation

/// Maps HTTP requests onto the vault. Kept out of the app target so the whole
/// path — request in, Markdown on disk, reply out — can be exercised in tests
/// without launching a menu-bar app.
public struct VaultAPI: Sendable {

    /// What `/api/preview` learned about a page before anything is written.
    public struct Preview: Encodable, Sendable {
        public let summary: String?
        /// Why there is no summary — shown in the panel so a broken endpoint is
        /// visible at save time rather than discovered later in the vault.
        public let reason: String?

        public init(summary: String?, reason: String?) {
            self.summary = summary
            self.reason = reason
        }
    }

    private let store: VaultStore
    /// Generates a summary without saving anything. Nil result means none was
    /// produced; the accompanying reason explains why.
    private let summarize: @Sendable (
        _ title: String, _ url: String, _ content: String,
        _ completion: @escaping @Sendable (Preview) -> Void
    ) -> Void

    public init(
        store: VaultStore,
        summarize: @escaping @Sendable (String, String, String, @escaping @Sendable (Preview) -> Void) -> Void
            = { _, _, _, done in done(Preview(summary: nil, reason: "摘要未启用")) }
    ) {
        self.store = store
        self.summarize = summarize
    }

    public func handle(
        _ request: LocalHTTPServer.Request,
        completion: @escaping @Sendable (LocalHTTPServer.Response) -> Void
    ) {
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            completion(.ok(Health(status: "ok", vault: store.vaultRoot.path)))

        case ("GET", "/api/check-url"):
            guard let url = request.query["url"], !url.isEmpty else {
                return completion(.error(400, "missing url"))
            }
            let existsIn = store.checkDuplicate(url)
            completion(.ok(CheckURL(exists: existsIn != nil, exists_in: existsIn)))

        case ("POST", "/api/preview"):
            // Summarize and hand the text back for review. Nothing is written —
            // seeing what got captured is what makes closing the tab feel safe.
            guard
                let link = try? JSONDecoder().decode(VaultLink.self, from: request.body)
            else {
                return completion(.error(400, "invalid payload"))
            }
            let existsIn = store.checkDuplicate(link.url)
            summarize(link.title, link.url, link.content ?? "") { preview in
                completion(.ok(PreviewResponse(
                    title: link.title,
                    summary: preview.summary,
                    reason: preview.reason,
                    exists_in: existsIn
                )))
            }

        case ("POST", "/api/links"):
            guard !request.body.isEmpty else { return completion(.error(400, "empty body")) }
            let decoder = JSONDecoder()
            let links: [VaultLink]
            // The extension posts a single link, or an array for bulk saves.
            if let one = try? decoder.decode(VaultLink.self, from: request.body) {
                links = [one]
            } else if let many = try? decoder.decode([VaultLink].self, from: request.body) {
                links = many
            } else {
                return completion(.error(400, "invalid payload"))
            }

            let result = store.save(links)
            Log.write("vault: saved \(result.saved), dup \(result.duplicates.count), err \(result.errors.count)")
            completion(.ok(result))

        default:
            completion(.error(404, "not found"))
        }
    }

    private struct Health: Encodable {
        let status: String
        let vault: String
    }

    private struct CheckURL: Encodable {
        let exists: Bool
        let exists_in: String?
    }

    private struct PreviewResponse: Encodable {
        let title: String
        let summary: String?
        let reason: String?
        let exists_in: String?
    }
}
