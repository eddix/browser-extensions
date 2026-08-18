import Foundation

/// Finding the tab you already have open for a URL quick open is about to
/// build.
///
/// The panel exists to make reusing an open window easier than opening a fourth
/// copy of it, so an expanded URL that's already on screen should raise that
/// window rather than add to the pile.
public enum QuickOpenMatch {

    /// Trailing slashes, and the case of the parts where case carries no
    /// meaning.
    ///
    /// Deliberately *not* `VaultStore.normalize`, which truncates at `#`. That
    /// rule is right for saved links, where a fragment is a heading you jumped
    /// to; it is catastrophic here, because platforms that route entirely
    /// through the fragment — `…/#/sg/detail/743188920` — would all collapse to
    /// their bare domain, and asking for one task would switch you to whichever
    /// other task happened to be open. Query strings stay for the same reason:
    /// a dashboard's whole subject is usually in them.
    ///
    /// Scheme and host fold to lowercase because DNS doesn't care and neither
    /// does the browser: a tab opened from a link that shouted the hostname is
    /// the same page as one opened from a template, and treating them as two
    /// left you with a second window on a page you already had. A blanket
    /// `lowercased()` cannot do this job — everything after the host is
    /// case-*sensitive*, and mangling it would collapse `/Detail/AbC` onto
    /// `/detail/abc` and switch you to a different object. Userinfo is left
    /// alone for the same reason: a password is not a hostname.
    public static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }

        guard let scheme = s.range(of: "://") else { return s }
        let rest = s[scheme.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        let hostStart = authority.lastIndex(of: "@").map(authority.index(after:))
            ?? authority.startIndex

        return s[s.startIndex..<scheme.lowerBound].lowercased()
            + "://"
            + authority[..<hostStart]
            + authority[hostStart...].lowercased()
            + rest[authorityEnd...]
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
