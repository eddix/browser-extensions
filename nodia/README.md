# nodia

A resident macOS menu-bar app for finding things again: it fuzzy-searches
**all** Arc sidebar tabs — including the sleeping/unrealized ones a browser
extension can't see — *and* everything you've saved into an Obsidian vault,
from one prompt.

- **⌘⇧K** (global) → centered search panel. Type to fuzzy-search; **↑↓** to
  move, **⏎** to jump to the tab (waking it if it was asleep) or open a saved
  link, **esc** to close.
- Matched characters are highlighted; rows show favicon + title + Space (for a
  live tab) or kind + summary (for a saved link).
- **⌘D** duplicate clustering, **⌘G** by-domain browsing.
- Themeable frosted-glass UI (7 palettes, 4 fonts, size) via the settings
  window. Menu-bar icon: left-click to search, right-click for Settings / Quit.

## Why search and saving live in one app

A browser tab bar gets used as three different things at once, and they have
nothing in common except being a URL you didn't want to lose:

| Used as | Lifetime | How you want it back | Done when |
|---|---|---|---|
| **bookmark** | months, tracks a project | on demand, instantly | never |
| **read later** | days to weeks | pushed at you when free | read, or dropped |
| **todo** | until finished | at the right moment | completed |

Measured on a real sidebar: of 71 pinned tabs, **75% hadn't been touched in 30
days** and the oldest was 549 days. Meanwhile the unpinned ones were all under
29 days old — the browser's own auto-archive quietly handles those. So the pile
that needs managing is the pinned one, and it had become sediment.

Saving alone doesn't fix it. The earlier setup (a separate Rust daemon writing
to the vault) proved that: of the links already saved to the vault, **every one
was still pinned in the browser**. Saved but not trusted — because getting it
back was uncertain. A save that doesn't let you close the tab is pure overhead,
and overhead decays.

That's why this is one app. Saving is only worth doing if recall is instant,
and recall is only instant if the same ⌘⇧K that finds your open tabs also finds
what you saved. One index, one prompt, one process.

## The extension

`extension/` is the companion MV3 extension (load unpacked from
`chrome://extensions`). It sends the current page to nodia, which files it into
the vault as Markdown.

- **Click the icon** → saves as *read later*. One action, no questions — it's
  the biggest and least committal bucket.
- **Right-click** → save as *bookmark* or *todo* instead. TODOs are written as
  `- [ ]` checkboxes into `Bookmark/00-Todo.md`, so Obsidian Tasks and your
  daily note can pick them up; a tab bar can't represent "done".
- The icon turns green on pages already in the vault.

### Data-safety lines this must not cross

Extracting page text to summarize it is, mechanically, exactly what a malicious
extension does when it exfiltrates your browsing (the reason
[hedra](../hedra) exists). Three things separate them, and all three are
load-bearing:

1. **Text is extracted only when you click save.** No background scraping, no
   history sweeps. Bulk "save all tabs" deliberately skips extraction.
2. **Intranet pages only ever reach an intranet model.** Hosts are matched
   against a configurable suffix list; if the matching endpoint isn't
   configured, the text **is not sent anywhere** and the link is saved without
   a summary. Failing closed is the only safe default — a missing summary costs
   nothing, a leak can't be undone.
3. **Secrets stay out of the repo.** API keys go to the macOS Keychain; the
   pairing token lives in UserDefaults. Neither is ever written to a file in
   this repository.

The local port is guarded too: every request needs `Authorization: Bearer
<token>`, and CORS is granted only to extension origins. Without that, script
on *any* page you visit could read your whole bookmark index off `localhost` —
which the previous backend, with `allow_origin(Any)`, permitted.

## How it works

| Need | Source (all local, offline) |
|---|---|
| Tab list | `~/Library/Application Support/Arc/StorableSidebar.json` |
| Favicons | Arc's Chromium `…/User Data/Default/Favicons` SQLite DB (read-only) |
| Activation | `osascript` → Arc AppleScript `select` + `focus`; fallback `open <url>` |
| Saved links | Obsidian vault Markdown under `Bookmark/` |
| Save endpoint | `127.0.0.1:8787`, token-authenticated |
| Summaries | your own LLM endpoints, routed by host (intranet vs public) |

See [DESIGN.md](./DESIGN.md) for the tab-parsing details.

## Build & run

```sh
swift run nodia              # run from source
swift run nodia-probe        # headless check: tabs, favicons, vault index
swift test                   # 41 tests, incl. HTTP boundary + summary routing
```

## Install as an app

```sh
./build-app.sh               # builds .dist/nodia.app (release, ad-hoc signed)
cp -R .dist/nodia.app /Applications/
open /Applications/nodia.app
```

Then: Settings → 收藏库 → copy the pairing token → paste it into the
extension's options page.

On first activation macOS asks to allow nodia to control Arc (Automation) —
allow it. Until then, activation falls back to opening the URL in a new tab.

## Requirements

macOS 14+, Swift 5.9+, the Arc browser, and an Obsidian vault (any folder of
Markdown, really) for the saving half.
