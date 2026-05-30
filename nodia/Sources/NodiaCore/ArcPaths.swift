import Foundation

/// Well-known on-disk locations of Arc's local data.
public enum ArcPaths {
    static var appSupport: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
    }

    /// The authoritative sidebar model: every space + every tab (incl. sleeping).
    public static var storableSidebar: URL {
        appSupport.appendingPathComponent("StorableSidebar.json")
    }

    /// Chromium favicon database (page_url -> PNG bitmap).
    public static var faviconsDB: URL {
        appSupport.appendingPathComponent("User Data/Default/Favicons")
    }
}
