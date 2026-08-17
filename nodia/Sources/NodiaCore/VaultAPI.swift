import Foundation

/// Maps HTTP requests onto the vault. Kept out of the app target so the whole
/// path — request in, Markdown on disk, reply out — can be exercised in tests
/// without launching a menu-bar app.
public struct VaultAPI: Sendable {

    /// What `/api/preview` learned about a page before anything is written.
    public struct Preview: Encodable, Sendable {
        public let summary: String?
        /// Search terms to store alongside the summary.
        public let keywords: [String]
        /// Why there is no summary — shown in the panel so a broken endpoint is
        /// visible at save time rather than discovered later in the vault.
        public let reason: String?

        public init(summary: String?, keywords: [String] = [], reason: String?) {
            self.summary = summary
            self.keywords = keywords
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
            = { _, _, _, done in done(Preview(summary: nil, keywords: [], reason: "摘要未启用")) }
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
            // Carries the saved summary back with the answer: this is polled on
            // every tab switch anyway, and it's what lets the panel show you
            // what a link already says before offering to replace it.
            let existing = store.entry(for: url)
            completion(.ok(CheckURL(
                exists: existing != nil,
                exists_in: existing?.relativePath,
                kind: existing?.kind,
                title: existing?.title,
                summary: existing?.summary,
                summary_at: existing?.summaryAt,
                keywords: existing?.keywords ?? []
            )))

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
                    keywords: preview.keywords,
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

        case ("POST", "/api/update-summary"):
            // Regenerating reuses /api/preview — summarizing is the same work
            // whether or not the link is already saved. This endpoint is only
            // the write-back, so nothing is overwritten until you've seen it.
            guard let patch = try? JSONDecoder().decode(SummaryPatch.self, from: request.body) else {
                return completion(.error(400, "invalid payload"))
            }
            guard !TextClean.strip(patch.summary).isEmpty else {
                // An empty summary would silently erase a good one.
                return completion(.error(400, "summary is empty"))
            }
            let result = store.updateSummary(
                url: patch.url,
                summary: patch.summary,
                keywords: patch.keywords
            )
            completion(result.success ? .ok(result) : .error(404, result.error ?? "update failed"))

        default:
            completion(.error(404, "not found"))
        }
    }

    private struct SummaryPatch: Decodable {
        let url: String
        let summary: String
        let keywords: [String]

        enum CodingKeys: String, CodingKey { case url, summary, keywords }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            keywords = (try c.decodeIfPresent([String].self, forKey: .keywords) ?? [])
                .map(TextClean.strip)
                .filter { !$0.isEmpty }
        }
    }

    private struct Health: Encodable {
        let status: String
        let vault: String
    }

    private struct CheckURL: Encodable {
        let exists: Bool
        let exists_in: String?
        let kind: LinkKind?
        let title: String?
        let summary: String?
        let summary_at: String?
        let keywords: [String]
    }

    private struct PreviewResponse: Encodable {
        let title: String
        let summary: String?
        let keywords: [String]
        let reason: String?
        let exists_in: String?
    }
}
