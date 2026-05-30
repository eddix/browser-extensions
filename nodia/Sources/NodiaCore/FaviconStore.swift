import Foundation
import SQLite3

/// Reads favicon PNGs out of Arc's Chromium `Favicons` SQLite DB (read-only).
///
/// Opened with the `immutable=1` URI so we can read while Arc holds the file.
/// Resolution: exact `page_url` match first, then any page on the same host.
public final class FaviconStore {
    private var db: OpaquePointer?

    public init?(url: URL = ArcPaths.faviconsDB) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // file: URI with percent-encoding for spaces, immutable to bypass the lock.
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file:\(encoded)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if sqlite3_open_v2(uri, &db, flags, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { if db != nil { sqlite3_close(db) } }

    /// Largest available favicon bitmap for a page URL, as PNG data.
    public func favicon(forURL url: String) -> Data? {
        if let exact = query(
            "SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id=m.icon_id WHERE m.page_url = ?1 ORDER BY b.width DESC LIMIT 1",
            bind: url
        ) { return exact }

        guard let host = URLComponents(string: url)?.host else { return nil }
        return query(
            "SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id=m.icon_id WHERE m.page_url LIKE ?1 ORDER BY b.width DESC LIMIT 1",
            bind: "%://\(host)/%"
        )
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLITE_TRANSIENT

    private func query(_ sql: String, bind value: String) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, 0))
        guard len > 0 else { return nil }
        return Data(bytes: blob, count: len)
    }
}
