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
        public let keywords: [String]
        public let relativePath: String
        /// When the summary was last written, if it was ever rewritten. Absent
        /// on entries whose summary dates from the day they were saved — for
        /// those `saved-at` already answers it.
        public let summaryAt: String?

        public init(
            title: String, url: String, kind: LinkKind,
            summary: String?, keywords: [String] = [], relativePath: String,
            summaryAt: String? = nil
        ) {
            self.title = title
            self.url = url
            self.kind = kind
            self.summary = summary
            self.keywords = keywords
            self.relativePath = relativePath
            self.summaryAt = summaryAt
        }
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

    public struct UpdateResult: Codable, Sendable {
        public let success: Bool
        /// Where the rewritten entry lives, so the panel can name it.
        public let file: String?
        public let error: String?
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
    /// The root's path components, resolved once. `relativePath` runs per file
    /// during a rebuild and per link during a save, and `resolvingSymlinksInPath`
    /// touches the filesystem — the root does not change under us, so resolving
    /// it inside that loop was work done thousands of times for one answer.
    private let rootParts: [String]
    private let queue = DispatchQueue(label: "com.eddix.nodia.vault")
    /// Normalized url -> the entry already on disk. Doubles as the duplicate
    /// check and as the lookup that lets the extension show you the summary a
    /// link was saved with before offering to replace it.
    private var entryByURL: [String: Entry] = [:]
    private var entries: [Entry] = []
    /// What the directory looked like when the index was last built. See
    /// `refreshIfStaleLocked`.
    private var indexedSnapshot = Snapshot()
    /// How many times the vault has been re-parsed from disk.
    ///
    /// Internal so a test can assert on it. The thing worth asserting — that
    /// saving a link doesn't make the next reader pay for a rebuild — has no
    /// other observable trace: the answers are identical either way, only the
    /// work differs.
    private(set) var rebuildCount = 0

    public init(vaultRoot: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw VaultError.notADirectory(vaultRoot.path)
        }
        self.vaultRoot = vaultRoot
        self.rootParts = vaultRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
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
        queue.sync { rebuildIndexLocked(snapshot: diskSnapshot()) }
    }

    // MARK: - Staying current

    /// A fingerprint of the Markdown on disk: how many files, and a combined
    /// stamp of each one's path, size and modification time.
    ///
    /// The parent directory's own mtime would have been cheaper and is the
    /// wrong signal — it moves only when a file is added or removed from the
    /// directory, and an editor rewriting a file in place leaves it alone.
    /// Measured: appending to a file bumps the file's mtime and not the
    /// directory's. Editing in place is the whole case we're here for.
    private struct Snapshot: Equatable {
        var fileCount = 0
        /// Summed rather than fed through a single hasher, because the
        /// enumerator promises no particular order and a reordering is not a
        /// change. Only ever compared against another snapshot from this same
        /// process, which is what makes `Hasher`'s per-process seed harmless.
        var digest: UInt64 = 0
    }

    private static let freshnessKeys: [URLResourceKey] = [
        .contentModificationDateKey, .fileSizeKey,
    ]

    private func diskSnapshot() -> Snapshot {
        guard let walker = FileManager.default.enumerator(
            at: bookmarkDir,
            includingPropertiesForKeys: Self.freshnessKeys,
            options: [.skipsHiddenFiles]
        ) else { return Snapshot() }

        var snapshot = Snapshot()
        for case let url as URL in walker where url.pathExtension == "md" {
            let values = try? url.resourceValues(forKeys: Set(Self.freshnessKeys))
            var hasher = Hasher()
            hasher.combine(url.path)
            hasher.combine(values?.contentModificationDate)
            hasher.combine(values?.fileSize)
            snapshot.fileCount += 1
            snapshot.digest = snapshot.digest &+ UInt64(bitPattern: Int64(hasher.finalize()))
        }
        return snapshot
    }

    /// Re-reads the vault if it changed under us, before answering anything.
    ///
    /// The index used to be built once, at startup, and nothing ever refreshed
    /// it — but the vault is a folder of Markdown whose whole point is that the
    /// user edits it in Obsidian. Deleting an entry by hand was the sharp
    /// version: `check-url` went on reporting the link as saved, so the
    /// extension offered to refresh a summary that `update-summary` then
    /// couldn't find in the file, and 404'd. That link could not be saved again
    /// until nodia was restarted, and the only thing that would have fixed it
    /// is a settings button labelled "restart the service" — which nobody has a
    /// reason to press.
    ///
    /// Checked here rather than from a directory watcher: every answer this
    /// class gives already funnels through the serial queue, so this is the one
    /// place staleness can be caught, with no background thread, no debouncing
    /// of an editor's mid-save churn, and no window where a watcher has fired
    /// but the index hasn't caught up yet.
    ///
    /// Affordable on every single call, including the `check-url` the extension
    /// polls on every tab switch, because the two walks are not remotely the
    /// same price. The enumerator fetches size and mtime in bulk as it reads
    /// the directory, so the check costs no syscall per file: measured over 500
    /// files it was 3.4 ms, against 800 ms merely to *open and read* the same
    /// files — before parsing any of them. Checking is ~200x cheaper than the
    /// rebuild it usually avoids, which is what makes "just look every time"
    /// the simple answer rather than the expensive one.
    private func refreshIfStaleLocked() {
        let current = diskSnapshot()
        guard current != indexedSnapshot else { return }
        Log.write("vault: files changed on disk, reindexing")
        rebuildIndexLocked(snapshot: current)
    }

    /// Takes the snapshot as an argument, and the caller measures it *before*
    /// reading the files: a file that changes mid-rebuild then leaves the
    /// stored snapshot describing the older state, so the next check sees a
    /// difference and rebuilds again. The other order loses the edit for good.
    private func rebuildIndexLocked(snapshot: Snapshot) {
        rebuildCount += 1
        indexedSnapshot = snapshot
        entryByURL.removeAll()
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
        Log.write("vault index: \(fileCount) files, \(entryByURL.count) links")
    }

    /// Parses the bullet format written by `append`. A title line is a
    /// top-level `- …`; its fields are the indented `- key: value` lines that
    /// follow, so we track the most recent title as we go.
    private func ingest(text: String, relativePath: String) {
        var title: String?
        var kind: LinkKind = .readlater
        var summary: String?
        var summaryAt: String?
        var keywords: [String] = []
        var url: String?

        // An entry is only complete at its boundary: `summary:` comes *after*
        // `url:`, so emitting on the url line would drop every summary.
        func flush() {
            defer {
                title = nil; summary = nil; summaryAt = nil
                keywords = []; url = nil; kind = .readlater
            }
            guard let url else { return }
            let entry = Entry(
                title: title ?? url,
                url: url,
                kind: kind,
                summary: summary,
                keywords: keywords,
                relativePath: relativePath,
                summaryAt: summaryAt
            )
            // First occurrence wins, so the duplicate report names the file the
            // link was originally filed into.
            let key = Self.normalize(url)
            if entryByURL[key] == nil { entryByURL[key] = entry }
            entries.append(entry)
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
            } else if field.hasPrefix("summary-at:") {
                let s = TextClean.strip(String(field.dropFirst("summary-at:".count)))
                summaryAt = s.isEmpty ? nil : s
            } else if field.hasPrefix("summary:") {
                let s = TextClean.strip(String(field.dropFirst("summary:".count)))
                summary = s.isEmpty ? nil : s
            } else if field.hasPrefix("keywords:") {
                keywords = String(field.dropFirst("keywords:".count))
                    .split(separator: ",")
                    .map { TextClean.strip(String($0)) }
                    .filter { !$0.isEmpty }
            } else if field.hasPrefix("url:") {
                let raw = String(field.dropFirst("url:".count))
                    .trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("http") { url = raw }
            }
        }
        flush()
    }

    public func checkDuplicate(_ url: String) -> String? {
        queue.sync {
            refreshIfStaleLocked()
            return entryByURL[Self.normalize(url)]?.relativePath
        }
    }

    /// The entry already saved for `url`, if any — including the summary it
    /// was saved with, so it can be shown before anything replaces it.
    public func entry(for url: String) -> Entry? {
        queue.sync {
            refreshIfStaleLocked()
            return entryByURL[Self.normalize(url)]
        }
    }

    /// Snapshot for the search index.
    public func allEntries() -> [Entry] {
        queue.sync {
            refreshIfStaleLocked()
            return entries
        }
    }

    // MARK: - Write

    public func save(_ links: [VaultLink]) -> SaveResult {
        queue.sync {
            // A link the user deleted by hand should save again, not come back
            // as a duplicate of an entry that no longer exists.
            refreshIfStaleLocked()
            var saved = 0
            var duplicates: [Duplicate] = []
            var errors: [SaveError] = []

            for link in links {
                let key = Self.normalize(link.url)
                if let existing = entryByURL[key] {
                    duplicates.append(Duplicate(url: link.url, exists_in: existing.relativePath))
                    continue
                }
                let file = targetFile(for: link.kind)
                do {
                    try append(link, to: file)
                    // Indexed as the file will read back, not as the request
                    // happened to arrive. The two used to disagree: a summary
                    // with a newline in it went to disk on one line and into
                    // the index on several, and an empty one was nil after a
                    // restart but "" before — so `check-url` gave one answer
                    // today and another tomorrow for a record nobody touched.
                    let summary = TextClean.singleLine(link.summary ?? "")
                    let entry = Entry(
                        title: link.title,
                        url: link.url,
                        kind: link.kind,
                        summary: summary.isEmpty ? nil : summary,
                        keywords: link.keywords.map(TextClean.singleLine),
                        relativePath: relativePath(file)
                    )
                    entryByURL[key] = entry
                    entries.append(entry)
                    saved += 1
                } catch {
                    errors.append(SaveError(url: link.url, error: error.localizedDescription))
                }
            }
            // Reindex here, where the writing happened, rather than leaving it
            // to whoever reads next.
            //
            // Our own writes move the files' timestamps, so the stored snapshot
            // ends up describing the vault as it was before them — and the next
            // read, seeing a difference it cannot attribute, re-parses
            // everything to rebuild what it is already holding. That read is
            // usually the hotkey: save a link in the browser, press ⌘⇧K, wait
            // on the main thread. Doing it here spends the same milliseconds on
            // the connection queue of a request that is already several seconds
            // long.
            //
            // A full rebuild rather than patching the snapshot, because the
            // snapshot is one summed digest with no per-file entries to patch,
            // and stamping a fresh one over an index built before the write
            // would swallow any edit that landed in between — the very race the
            // snapshot-before-read order elsewhere exists to avoid.
            if saved > 0 { rebuildIndexLocked(snapshot: diskSnapshot()) }
            return SaveResult(success: errors.isEmpty, saved: saved,
                              duplicates: duplicates, errors: errors)
        }
    }

    /// Replaces the summary and keywords of an entry already on disk.
    ///
    /// A summary describes a page as it was on the day it was saved. Pages
    /// change, and most of the archive predates summaries entirely — so the
    /// summary has to be replaceable without re-saving the link and losing the
    /// original `saved-at`.
    ///
    /// Only the target entry's own field lines are touched. Everything else in
    /// the file — other entries, frontmatter, hand-written notes, blank lines —
    /// is carried through unchanged, because this is editing a file the user
    /// owns and may well have edited themselves.
    public func updateSummary(url: String, summary: String, keywords: [String]) -> UpdateResult {
        queue.sync {
            // The index is what decides which file to open and rewrite. If it
            // disagrees with disk, this is the call that discovers it the hard
            // way — by not finding the entry it was told was there.
            refreshIfStaleLocked()
            let key = Self.normalize(url)
            guard let existing = entryByURL[key] else {
                return UpdateResult(success: false, file: nil, error: "这个链接不在收藏库里")
            }
            let file = vaultRoot.appendingPathComponent(existing.relativePath)
            let stamp = ISO8601DateFormatter.vesperWriter.string(from: Date())
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                guard let rewritten = Self.rewritingSummary(
                    in: text, url: key, summary: summary, keywords: keywords, at: stamp
                ) else {
                    // The index says it's here but the file no longer agrees —
                    // stop rather than guess which entry was meant.
                    return UpdateResult(success: false, file: existing.relativePath,
                                        error: "在 \(existing.relativePath) 里找不到这条记录")
                }
                try rewritten.write(to: file, atomically: true, encoding: .utf8)

                let updated = Entry(
                    title: existing.title, url: existing.url, kind: existing.kind,
                    summary: summary.isEmpty ? nil : TextClean.singleLine(summary),
                    // Flattened the same way `save` flattens it, so the entry
                    // in memory matches what a restart would read back.
                    keywords: keywords.map(TextClean.singleLine),
                    relativePath: existing.relativePath,
                    summaryAt: stamp
                )
                entryByURL[key] = updated
                if let i = entries.firstIndex(where: { Self.normalize($0.url) == key }) {
                    entries[i] = updated
                }
                // Same reason as in `save`: our own write must not read back as
                // a foreign change and cost the next reader a full re-parse.
                rebuildIndexLocked(snapshot: diskSnapshot())
                Log.write("vault: updated summary in \(existing.relativePath)")
                return UpdateResult(success: true, file: existing.relativePath, error: nil)
            } catch {
                return UpdateResult(success: false, file: existing.relativePath,
                                    error: error.localizedDescription)
            }
        }
    }

    /// Rewrites one entry's `keywords`/`summary` lines in `text`, or nil if no
    /// entry with that URL is in this file.
    ///
    /// Works on the block between the entry's own title bullet and the next
    /// one. Within it the stale field lines are dropped and fresh ones appended
    /// after the last surviving field, which keeps the fields together even
    /// when the block ends in blank lines.
    static func rewritingSummary(
        in text: String, url key: String, summary: String, keywords: [String], at stamp: String
    ) -> String? {
        var lines = text.components(separatedBy: "\n")

        func isTitleBullet(_ line: String) -> Bool {
            let clean = TextClean.removeInvisible(line)
            return !clean.hasPrefix(" ") && !clean.hasPrefix("\t")
                && clean.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
        }
        /// The `key:` of an indented `  - key: value` line, else nil.
        func fieldName(_ line: String) -> String? {
            let clean = TextClean.removeInvisible(line)
            guard clean.hasPrefix(" ") || clean.hasPrefix("\t") else { return nil }
            let trimmed = clean.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "), let colon = trimmed.firstIndex(of: ":") else { return nil }
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon])
        }

        // Locate the block: scan for the url line, remembering the title bullet
        // above it.
        var blockStart: Int?
        var current: Int?
        for (i, line) in lines.enumerated() {
            if isTitleBullet(line) { current = i; continue }
            guard fieldName(line) == "url", let start = current else { continue }
            let clean = TextClean.removeInvisible(line).trimmingCharacters(in: .whitespaces)
            guard let colon = clean.firstIndex(of: ":") else { continue }
            let value = String(clean[clean.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if Self.normalize(value) == key { blockStart = start; break }
        }
        guard let start = blockStart else { return nil }

        var end = lines.count
        for i in (start + 1)..<lines.count where isTitleBullet(lines[i]) {
            end = i
            break
        }

        // Match the indentation already in use rather than assuming two spaces.
        var indent = "  "
        var kept: [String] = []
        var lastField = -1
        for i in start..<end {
            guard let name = fieldName(lines[i]) else { kept.append(lines[i]); continue }
            if name == "url" {
                indent = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))
            }
            if ["summary", "keywords", "summary-at"].contains(name) { continue }
            kept.append(lines[i])
            lastField = kept.count - 1
        }

        var fresh: [String] = []
        if !keywords.isEmpty {
            fresh.append("\(indent)- keywords: \(keywords.map(TextClean.singleLine).joined(separator: ", "))")
        }
        fresh.append("\(indent)- summary: \(TextClean.singleLine(summary))")
        // Dating the summary separately from `saved-at` is what makes staleness
        // answerable: the link is old, but the description of it may not be.
        fresh.append("\(indent)- summary-at: \(stamp)")
        kept.insert(contentsOf: fresh, at: lastField >= 0 ? lastField + 1 : min(1, kept.count))

        lines.replaceSubrange(start..<end, with: kept)
        return lines.joined(separator: "\n")
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
        if !link.keywords.isEmpty {
            // Before summary: short, scannable, and the thing you skim for.
            out += "  - keywords: \(link.keywords.map(TextClean.singleLine).joined(separator: ", "))\n"
        }
        // Flattened: one field per line, and a hand-edited summary can contain
        // newlines (see TextClean.singleLine).
        out += "  - summary: \(TextClean.singleLine(link.summary ?? ""))\n"
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
