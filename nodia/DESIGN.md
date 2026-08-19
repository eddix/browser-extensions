# nodia — Arc tab finder (menubar)

A resident macOS menu-bar app that fuzzy-searches **all** Arc sidebar tabs —
including the *sleeping / unrealized* tabs a browser extension can't see
(because `chrome.tabs.query` only returns realized tabs).

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
| Tab list    | `~/Library/Application Support/Arc/StorableSidebar.json`, re-read on each open |
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
`focus`.

Sleeping tabs are *not* the limit here, despite the obvious guess. Reconciled
per-Space against real data — 134 tabs in the JSON, 121 reported by AppleScript:

| Space | AppleScript | JSON |
|---|---|---|
| seven ordinary Spaces | 121 | 121 |
| Top Apps | — | 12 |
| a second profile's untitled Space | — | 1 |

Every ordinary Space agrees **exactly**, unrealized entries included, because
AppleScript asks Arc — which answers from the same sidebar model the JSON is a
dump of. (`chrome.tabs.query` asks Chromium instead, which only knows the tabs
Arc has realized; that gap is why the extension approach was abandoned.)

The real blind spot is structural. Arc's sidebar has three tiers — Favorites
(the icon row shared across every Space) / Pinned / Unpinned — and AppleScript's
object model only offers `application → windows → spaces → tabs`. Favorites
hang off the sidebar root (`parentID: null`, referenced by
`topAppsContainerIDs`), so `tabs of space` can never list them no matter how
awake they are. `SidebarParser` labels them Space "Top Apps"; anything wanting
to switch to a live tab should skip that label rather than pay a multi-second
walk of every Space to fail.

## Scope

**MVP:** hotkey → fuzzy search (with favicons) → activate. Covers only
*sidebar* sleeping tabs (category A).

**Not in MVP:** archived tabs (category B — separate undocumented store),
action menu (copy/close), custom-hotkey recorder, multi-profile.

## Build

SPM. Core verified headlessly first via `swift run nodia-probe [query]`, then
the GUI is layered on. Packaged into a signed `.app` later.
