# nodia — Arc tab finder (menubar)

A resident macOS menu-bar app that fuzzy-searches **all** Arc sidebar tabs —
including the *sleeping / unrealized* tabs that the `arc-tab-sorter` browser
extension can't see (because `chrome.tabs.query` only returns realized tabs).

## Why native (not an extension)

A browser extension is sandboxed: it can't read Arc's data files and can't run
AppleScript. To see sleeping tabs and to activate them we must leave the
sandbox → a native resident app. That's the whole reason this exists.

## Interaction

- Resident `.accessory` app (menu-bar only, no Dock icon).
- Global hotkey **⌘⇧K** → centered floating `NSPanel`. Menu-bar icon opens the
  same panel.
- Panel: search field + flat fuzzy-ranked list (favicon + title + Space
  subtitle). Empty query → sorted by most-recently-active. ↑↓ move, ⏎ activate,
  Esc clear/close.

## Data sources (all local, offline)

| Need        | Source                                                                 |
|-------------|------------------------------------------------------------------------|
| Tab list    | `~/Library/Application Support/Arc/StorableSidebar.json` (FSEvents watch) |
| Favicons    | Arc's Chromium `…/User Data/Default/Favicons` SQLite DB (read-only)     |
| Activation  | `osascript` → Arc AppleScript `select` + `focus`; fallback `open <url>` |

### StorableSidebar.json shape
`sidebar.containers[1]` has `spaces` and `items`, both stored as alternating
`[idString, object, …]` arrays. Each **space** has `title`, `id`, and
`containerIDs = ["pinned", <id>, "unpinned", <id>]` (its two root containers).
Each **item** has `id`, `parentID`, `data`. A tab item is
`data.tab { savedURL, savedTitle, timeLastActiveAt }`. Map a tab → its space by
climbing `parentID` until an ancestor id matches a space's root container id.

### Activation join
The sidebar JSON and Arc's AppleScript both expose tab **URL**, so we activate
by matching URL within the tab's Space (`tab of space "Name"`), then `select` +
`focus`. Verified on real data: AppleScript sees ~207 tabs across spaces ≈ the
~218 in the JSON, so `select` reaches sleeping tabs (it wakes them).

## Scope

**MVP:** hotkey → fuzzy search (with favicons) → activate. Covers only
*sidebar* sleeping tabs (category A).

**Not in MVP:** archived tabs (category B — separate undocumented store),
domain grouping, action menu (copy/close), settings UI, custom-hotkey recorder,
multi-profile.

## Build

SPM. Core verified headlessly first via `swift run nodia-probe [query]`, then
the GUI is layered on. Packaged into a signed `.app` later.
