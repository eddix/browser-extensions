import Foundation

/// Finding the tab you already have open for a URL quick open is about to
/// build.
///
/// The panel exists to make reusing an open window easier than opening a fourth
/// copy of it, so an expanded URL that's already on screen should raise that
/// window rather than add to the pile.
public enum QuickOpenMatch {

    /// Trailing slashes, and nothing else.
    ///
    /// Deliberately *not* `VaultStore.normalize`, which truncates at `#`. That
    /// rule is right for saved links, where a fragment is a heading you jumped
    /// to; it is catastrophic here, because platforms that route entirely
    /// through the fragment — `…/#/sg/detail/743188920` — would all collapse to
    /// their bare domain, and asking for one task would switch you to whichever
    /// other task happened to be open. Query strings stay for the same reason:
    /// a dashboard's whole subject is usually in them.
    public static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The open tab showing exactly this URL, if there is one.
    ///
    /// Skips Top Apps: they hang off the sidebar root rather than any Space,
    /// and Arc's AppleScript can only reach tabs through `spaces → tabs`, so
    /// "switching" to one means several seconds of walking every Space before
    /// falling back to opening it anyway. Reaching for quick open instead of
    /// clicking a favourite you can see is its own answer about which you
    /// wanted.
    public static func liveTab(for url: URL, in tabs: [TabEntry]) -> TabEntry? {
        let target = normalize(url.absoluteString)
        return tabs.first {
            $0.origin == .arcTab
                && $0.spaceTitle != SidebarParser.topAppsSpaceTitle
                && normalize($0.url) == target
        }
    }
}
