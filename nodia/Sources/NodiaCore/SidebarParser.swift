import Foundation

/// Parses Arc's `StorableSidebar.json` into a flat list of `TabEntry`.
///
/// Structure (see DESIGN.md): `sidebar.containers` holds one or more containers
/// with `spaces` and `items`, each an alternating `[idString, object, …]`
/// array. We only need the object elements (every object carries its own `id`).
/// A tab item is `data.tab`; we map it to a Space by climbing `parentID` until
/// an ancestor id matches one of that Space's root container ids. We merge
/// EVERY container that has items+spaces — Arc started shipping a second
/// (small) one, and picking just the first silently dropped the real sidebar.
public enum SidebarParser {

    public enum ParseError: Error { case unreadable, badShape }

    public static func parse(url: URL = ArcPaths.storableSidebar) throws -> [TabEntry] {
        guard let data = try? Data(contentsOf: url) else { throw ParseError.unreadable }
        let root = try JSONSerialization.jsonObject(with: data)
        guard
            let top = root as? [String: Any],
            let sidebar = top["sidebar"] as? [String: Any],
            let containers = sidebar["containers"] as? [Any]
        else { throw ParseError.badShape }

        // Merge EVERY container that has items + spaces (not just the first).
        let boxes = containers.compactMap { $0 as? [String: Any] }
            .filter { $0["items"] != nil && $0["spaces"] != nil }
        guard !boxes.isEmpty else { throw ParseError.badShape }

        var rootToSpace: [String: String] = [:]
        var itemsByID: [String: [String: Any]] = [:]
        var allItems: [[String: Any]] = []

        for box in boxes {
            let spaceObjs = (box["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            let itemObjs  = (box["items"]  as? [Any] ?? []).compactMap { $0 as? [String: Any] }

            // Map every Space root-container id -> Space title. `containerIDs` is
            // an alternating `[label, rootId, label, rootId]` array (labels are
            // "pinned"/"unpinned"; rootIds may be UUIDs OR literal strings like
            // "thebrowser.company.defaultPersonalSpace…ContainerID"), so we take
            // the value following each label rather than guessing by format.
            for s in spaceObjs {
                let title = (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
                let cids = s["containerIDs"] as? [Any] ?? []
                var i = 1
                while i < cids.count {
                    if let rootId = cids[i] as? String { rootToSpace[rootId] = title }
                    i += 2
                }
            }
            // "Top Apps" are the global pinned apps shown above all spaces.
            let topRoots = box["topAppsContainerIDs"] as? [Any] ?? []
            var ti = 1
            while ti < topRoots.count {
                if let rootId = topRoots[ti] as? String { rootToSpace[rootId] = "Top Apps" }
                ti += 2
            }

            for it in itemObjs {
                if let id = it["id"] as? String { itemsByID[id] = it }
                allItems.append(it)
            }
        }

        func spaceTitle(for item: [String: Any]) -> String {
            var pid = item["parentID"] as? String
            var hops = 0
            while let p = pid, hops < 100 {
                if let title = rootToSpace[p] { return title }
                pid = itemsByID[p]?["parentID"] as? String
                hops += 1
            }
            return "?"
        }

        var entries: [TabEntry] = []
        var seenIDs = Set<String>()
        for it in allItems {
            guard
                let data = it["data"] as? [String: Any],
                let tab = data["tab"] as? [String: Any],
                let urlStr = (tab["savedURL"] as? String) ?? (tab["activeTabURL"] as? String),
                !urlStr.isEmpty
            else { continue }

            let rawID = it["id"] as? String
            if let rawID { if seenIDs.contains(rawID) { continue }; seenIDs.insert(rawID) }

            let itemTitle = (it["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let savedTitle = (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let title = itemTitle ?? savedTitle ?? urlStr
            let lastActive = (tab["timeLastActiveAt"] as? Double) ?? 0

            entries.append(TabEntry(
                id: rawID ?? UUID().uuidString,
                title: title,
                url: urlStr,
                spaceTitle: spaceTitle(for: it),
                lastActiveAt: lastActive
            ))
        }
        return entries
    }
}
