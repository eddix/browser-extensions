import Foundation

/// Reads and writes the Obsidian vault: appends saved links as Markdown and
/// keeps a URL index so duplicates are caught and so nodia's search can offer
/// vault entries next to live Arc tabs.
///
/// The on-disk format is deliberately identical to what the old Rust backend
/// wrote — the vault already holds files in that shape, and staying compatible
/// means the index sees old and new entries alike.
///
/// All mutating work runs on a private serial queue: HTTP requests arrive on
/// arbitrary connection queues.
public final class VaultStore: @unchecked Sendable {

    public struct Entry: Sendable {
        public let title: String
        public let url: String
        public let kind: LinkKind
        public let summary: String?
        public let relativePath: String
    }

    public struct Duplicate: Codable, Sendable {
        public let url: String
        public let exists_in: String
    }

    public struct SaveError: Codable, Sendable {
        public let url: String
        public let error: String
    }

    public struct SaveResult: Codable, Sendable {
        public let success: Bool
        public let saved: Int
        public let duplicates: [Duplicate]
        public let errors: [SaveError]
    }

    public enum VaultError: LocalizedError {
        case notADirectory(String)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let p): return "vault 路径不可用：\(p)"
            }
        }
    }

    public let vaultRoot: URL
    private let queue = DispatchQueue(label: "com.eddix.nodia.vault")
    private var urlIndex: [String: String] = [:]   // normalized url -> relative path
    private var entries: [Entry] = []

    public init(vaultRoot: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw VaultError.notADirectory(vaultRoot.path)
        }
        self.vaultRoot = vaultRoot
        rebuildIndex()
    }

    // MARK: - Layout

    private var bookmarkDir: URL { vaultRoot.appendingPathComponent("Bookmark") }
    private var inboxDir: URL { bookmarkDir.appendingPathComponent("01-Inbox") }

    /// TODOs go to one accumulating file rather than a per-day one: a todo you
    /// can't see is a todo you won't do, and dating them scatters the list.
    private var todoFile: URL { bookmarkDir.appendingPathComponent("00-Todo.md") }

    private func dailyFile() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return inboxDir.appendingPathComponent("links-\(f.string(from: Date())).md")
    }

    private func targetFile(for kind: LinkKind) -> URL {
        kind == .todo ? todoFile : dailyFile()
    }

    // MARK: - Index

    /// Path of `url` relative to the vault root.
    ///
    /// Compares resolved path components rather than trimming a string prefix:
    /// on macOS the enumerator hands back `/private/var/…` while the root may
    /// be `/var/…` (a symlink), and prefix-trimming there silently produces
    /// garbage like `/privateBookmark/…`.
    private func relativePath(_ url: URL) -> String {
        let rootParts = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileParts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileParts.count > rootParts.count,
              Array(fileParts.prefix(rootParts.count)) == rootParts else {
            return url.lastPathComponent
        }
        return fileParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    /// Trailing slashes and fragments shouldn't make the same page look new.
    public static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[s.startIndex..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public func rebuildIndex() {
        queue.sync { rebuildIndexLocked() }
    }

    private func rebuildIndexLocked() {
        urlIndex.removeAll()
        entries.removeAll()
        guard let walker = FileManager.default.enumerator(
            at: bookmarkDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Log.write("vault: no Bookmark/ directory under \(vaultRoot.path)")
            return
        }

        var fileCount = 0
        for case let url as URL in walker where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            fileCount += 1
            ingest(text: text, relativePath: relativePath(url))
        }
        Log.write("vault index: \(fileCount) files, \(urlIndex.count) links")
    }

    /// Parses the bullet format written by `append`. A title line is a
    /// top-level `- …`; its fields are the indented `- key: value` lines that
    /// follow, so we track the most recent title as we go.
    private func ingest(text: String, relativePath: String) {
        var title: String?
        var kind: LinkKind = .readlater
        var summary: String?
        var url: String?

        // An entry is only complete at its boundary: `summary:` comes *after*
        // `url:`, so emitting on the url line would drop every summary.
        func flush() {
            defer { title = nil; summary = nil; url = nil; kind = .readlater }
            guard let url else { return }
            let key = Self.normalize(url)
            if urlIndex[key] == nil { urlIndex[key] = relativePath }
            entries.append(Entry(
                title: title ?? url,
                url: url,
                kind: kind,
                summary: summary,
                relativePath: relativePath
            ))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip invisibles first: a watermark joiner right after "- " makes
            // the prefix check fail (see TextClean.removeInvisible).
            let line = TextClean.removeInvisible(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")

            if !indented, trimmed.hasPrefix("- ") {
                flush()
                var t = String(trimmed.dropFirst(2))
                // TODOs are checkboxes: "- [ ] Title" / "- [x] Title"
                if t.hasPrefix("[ ] ") || t.hasPrefix("[x] ") || t.hasPrefix("[X] ") {
                    t = String(t.dropFirst(4))
                    kind = .todo
                }
                title = TextClean.strip(t.replacingOccurrences(of: "\\[", with: "[")
                                          .replacingOccurrences(of: "\\]", with: "]"))
                continue
            }

            guard indented, trimmed.hasPrefix("- ") else { continue }
            let field = String(trimmed.dropFirst(2))

            if field.hasPrefix("tag:") {
                for k in LinkKind.allCases where field.contains(k.tag) { kind = k }
            } else if field.hasPrefix("summary:") {
                let s = TextClean.strip(String(field.dropFirst("summary:".count)))
                summary = s.isEmpty ? nil : s
            } else if field.hasPrefix("url:") {
                let raw = String(field.dropFirst("url:".count))
                    .trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("http") { url = raw }
            }
        }
        flush()
    }

    public func checkDuplicate(_ url: String) -> String? {
        queue.sync { urlIndex[Self.normalize(url)] }
    }

    /// Snapshot for the search index.
    public func allEntries() -> [Entry] {
        queue.sync { entries }
    }

    // MARK: - Write

    public func save(_ links: [VaultLink]) -> SaveResult {
        queue.sync {
            var saved = 0
            var duplicates: [Duplicate] = []
            var errors: [SaveError] = []

            for link in links {
                let key = Self.normalize(link.url)
                if let existing = urlIndex[key] {
                    duplicates.append(Duplicate(url: link.url, exists_in: existing))
                    continue
                }
                let file = targetFile(for: link.kind)
                do {
                    try append(link, to: file)
                    let relative = relativePath(file)
                    urlIndex[key] = relative
                    entries.append(Entry(
                        title: link.title,
                        url: link.url,
                        kind: link.kind,
                        summary: link.summary,
                        relativePath: relative
                    ))
                    saved += 1
                } catch {
                    errors.append(SaveError(url: link.url, error: error.localizedDescription))
                }
            }
            return SaveResult(success: errors.isEmpty, saved: saved,
                              duplicates: duplicates, errors: errors)
        }
    }

    /// Fills in the `summary:` field of an already-saved entry.
    ///
    /// Summaries are generated after the fact: the extension must get its
    /// response immediately, while a model call takes seconds. So the link
    /// lands with an empty summary and this patches the line once the text
    /// comes back.
    @discardableResult
    public func updateSummary(url: String, summary: String) -> Bool {
        queue.sync {
            let key = Self.normalize(url)
            guard let relative = urlIndex[key] else { return false }
            let file = vaultRoot.appendingPathComponent(relative)
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { return false }

            var lines = text.components(separatedBy: "\n")
            guard let urlLine = lines.firstIndex(where: { line in
                let t = TextClean.removeInvisible(line).trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- url:") else { return false }
                return Self.normalize(String(t.dropFirst("- url:".count))) == key
            }) else { return false }

            // Stay inside this entry: stop at the next top-level bullet.
            var i = urlLine + 1
            while i < lines.count {
                let line = TextClean.removeInvisible(lines[i])
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
                if !indented, trimmed.hasPrefix("- ") { break }
                if indented, trimmed.hasPrefix("- summary:") {
                    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    lines[i] = "\(indent)- summary: \(summary)"
                    text = lines.joined(separator: "\n")
                    do {
                        try text.write(to: file, atomically: true, encoding: .utf8)
                        for (idx, entry) in entries.enumerated()
                        where Self.normalize(entry.url) == key {
                            entries[idx] = Entry(
                                title: entry.title, url: entry.url, kind: entry.kind,
                                summary: summary, relativePath: entry.relativePath
                            )
                        }
                        return true
                    } catch {
                        Log.write("vault: failed to write summary for \(url)")
                        return false
                    }
                }
                i += 1
            }
            return false
        }
    }

    private func append(_ link: VaultLink, to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var text = ""
        if !fm.fileExists(atPath: file.path) {
            text += frontmatter(for: file)
        }
        text += body(for: link)

        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: file, options: .atomic)
        }
    }

    private func frontmatter(for file: URL) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let isTodo = file.lastPathComponent == todoFile.lastPathComponent
        return """
        ---
        date: \(f.string(from: Date()))
        type: \(isTodo ? "browser-todos" : "browser-links")
        ---


        """
    }

    private func body(for link: VaultLink) -> String {
        let stamp = ISO8601DateFormatter.vesperWriter.string(from: link.createdAt ?? Date())
        let title = link.title
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")

        var out = link.kind == .todo ? "- [ ] \(title)\n" : "- \(title)\n"
        out += "  - url: \(link.url)\n"
        out += "  - saved-at: \(stamp)\n"
        out += "  - source: \(link.source ?? "unknown")\n"
        if link.kind != .todo {
            out += "  - mode: \(link.mode ?? "single")\n"
        }
        if let w = link.windowTitle, !w.isEmpty {
            out += "  - window-title: \(w)\n"
        }
        out += "  - tag: #from-browser \(link.kind.tag)\n"
        out += "  - summary: \(link.summary ?? "")\n"
        out += "\n"
        return out
    }
}

extension ISO8601DateFormatter {
    static let vesperWriter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()
}
