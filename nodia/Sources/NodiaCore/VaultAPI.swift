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
    /// Live counters for summaries still being written, so the panel can show
    /// that something is happening during a wait measured in tens of seconds.
    public let progress = PreviewProgressStore()
    /// Generates a summary without saving anything. Nil result means none was
    /// produced; the accompanying reason explains why. `onProgress` fires on
    /// every delta while the model writes.
    private let summarize: @Sendable (
        _ title: String, _ url: String, _ content: String,
        _ onProgress: @escaping @Sendable (Summarizer.Progress) -> Void,
        _ completion: @escaping @Sendable (Preview) -> Void
    ) -> Void

    public init(
        store: VaultStore,
        summarize: @escaping @Sendable (
            String, String, String,
            @escaping @Sendable (Summarizer.Progress) -> Void,
            @escaping @Sendable (Preview) -> Void
        ) -> Void = { _, _, _, _, done in
            done(Preview(summary: nil, keywords: [], reason: "摘要未启用"))
        }
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
            // The caller invents the job id and polls it, because it has to be
            // known before the request that would otherwise return it.
            let job = request.query["job"].flatMap { $0.isEmpty ? nil : $0 }
            if let job { progress.start(job) }
            let progressStore = progress
            summarize(
                link.title, link.url, link.content ?? "",
                { update in
                    if let job { progressStore.update(job, update) }
                },
                { preview in
                    if let job { progressStore.finish(job) }
                    completion(.ok(PreviewResponse(
                        title: link.title,
                        summary: preview.summary,
                        keywords: preview.keywords,
                        reason: preview.reason,
                        exists_in: existsIn
                    )))
                }
            )

        case ("GET", "/api/preview-progress"):
            guard let job = request.query["job"], !job.isEmpty else {
                return completion(.error(400, "missing job"))
            }
            guard let entry = progress.read(job) else {
                // Either the preview hasn't started yet or it's long finished.
                // Both are "nothing to show", not an error worth surfacing.
                return completion(.ok(ProgressResponse(
                    found: false, thinking_chars: 0, text_chars: 0,
                    elapsed_ms: 0, done: false
                )))
            }
            completion(.ok(ProgressResponse(
                found: true,
                thinking_chars: entry.thinkingChars,
                text_chars: entry.textChars,
                elapsed_ms: Int(entry.elapsed * 1000),
                done: entry.done
            )))

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

    private struct ProgressResponse: Encodable {
        let found: Bool
        let thinking_chars: Int
        let text_chars: Int
        let elapsed_ms: Int
        let done: Bool
    }

    private struct PreviewResponse: Encodable {
        let title: String
        let summary: String?
        let keywords: [String]
        let reason: String?
        let exists_in: String?
    }
}
