import Foundation

/// Minimal append-only logger → `~/Library/Logs/nodia.log`
/// (visible in Console.app, or `tail -f ~/Library/Logs/nodia.log`).
public enum Log {
    public static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/nodia.log")

    public static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
