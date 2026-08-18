import Foundation

/// Minimal append-only logger → `~/Library/Logs/nodia.log`
/// (visible in Console.app, or `tail -f ~/Library/Logs/nodia.log`).
public enum Log {
    public static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/nodia.log")

    /// Appends one line, atomically with respect to every other writer.
    ///
    /// `O_APPEND` is doing the locking here. The obvious spelling — seek to the
    /// end, then write — is two syscalls with a gap in the middle, and anything
    /// that lands in that gap makes both writers agree on the same offset and
    /// one line overwrite the other. That is not hypothetical for this app:
    /// HTTP requests are logged from arbitrary connection queues while the
    /// panel logs from the main thread. A serial queue would have fixed it
    /// within one process only, and `nodia-probe` writes to this same file.
    public static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
