import Foundation

/// Maps HTTP requests onto the vault. Kept out of the app target so the whole
/// path — request in, Markdown on disk, reply out — can be exercised in tests
/// without launching a menu-bar app.
public struct VaultAPI: Sendable {
    private let store: VaultStore
    /// Called after a successful save with the links that carried page text.
    /// Summarizing happens off to the side: the extension gets its reply now,
    /// the model call takes seconds.
    private let onSaved: @Sendable ([VaultLink]) -> Void

    public init(store: VaultStore, onSaved: @escaping @Sendable ([VaultLink]) -> Void = { _ in }) {
        self.store = store
        self.onSaved = onSaved
    }

    public func handle(_ request: LocalHTTPServer.Request) -> LocalHTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            return .ok(Health(status: "ok", vault: store.vaultRoot.path))

        case ("GET", "/api/check-url"):
            guard let url = request.query["url"], !url.isEmpty else {
                return .error(400, "missing url")
            }
            let existsIn = store.checkDuplicate(url)
            return .ok(CheckURL(exists: existsIn != nil, exists_in: existsIn))

        case ("POST", "/api/links"):
            guard !request.body.isEmpty else { return .error(400, "empty body") }
            let decoder = JSONDecoder()
            let links: [VaultLink]
            // The extension posts a single link, or an array for bulk saves.
            if let one = try? decoder.decode(VaultLink.self, from: request.body) {
                links = [one]
            } else if let many = try? decoder.decode([VaultLink].self, from: request.body) {
                links = many
            } else {
                return .error(400, "invalid payload")
            }

            let result = store.save(links)
            Log.write("vault: saved \(result.saved), dup \(result.duplicates.count), err \(result.errors.count)")

            let withContent = links.filter { !($0.content ?? "").isEmpty }
            if !withContent.isEmpty { onSaved(withContent) }
            return .ok(result)

        default:
            return .error(404, "not found")
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
}
