import Foundation

/// Live progress of in-flight summaries, keyed by a job id the caller invents.
///
/// The panel needs to answer one question while it waits: is anything still
/// arriving? It can't hold a stream open — the extension speaks plain `fetch`
/// against a local port — so it polls this instead, and the model's own output
/// counters are what make the answer honest rather than a spinner that means
/// nothing.
///
/// Finishing doesn't remove anything — the entry stays, marked done, so the
/// poll already in flight gets an answer rather than "unknown job". Age is what
/// removes it, swept on the next `start`, which means a finished job and one
/// abandoned halfway leave by the same door and neither can pile up in a
/// process that stays running for weeks.
public final class PreviewProgressStore: @unchecked Sendable {

    public struct Entry: Sendable, Equatable {
        public var thinkingChars: Int
        public var textChars: Int
        public var startedAt: Date
        /// True once the summary has been handed back — one last poll can see
        /// it finished rather than merely stopping.
        public var done: Bool

        public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    }

    /// How long an abandoned entry survives. Well past the slowest observed
    /// summary (~40s), short enough that a walked-away client is forgotten.
    static let ttl: TimeInterval = 600

    private let lock = NSLock()
    private var jobs: [String: Entry] = [:]

    public init() {}

    public func start(_ job: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now)
        jobs[job] = Entry(thinkingChars: 0, textChars: 0, startedAt: now, done: false)
    }

    /// Called on every delta, so it does the least work that is still correct.
    public func update(_ job: String, _ progress: Summarizer.Progress) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = jobs[job] else { return }
        entry.thinkingChars = progress.thinkingChars
        entry.textChars = progress.textChars
        jobs[job] = entry
    }

    /// Marks the job finished and keeps it until the TTL sweep, so a poll
    /// already in flight gets a real answer instead of "unknown job".
    public func finish(_ job: String) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = jobs[job] else { return }
        entry.done = true
        jobs[job] = entry
    }

    public func read(_ job: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return jobs[job]
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.count
    }

    /// Drops entries older than the TTL. Runs on `start`, which is the only
    /// path that can add one — so the table is bounded by concurrent saves.
    private func pruneLocked(now: Date) {
        jobs = jobs.filter { now.timeIntervalSince($0.value.startedAt) < Self.ttl }
    }
}
