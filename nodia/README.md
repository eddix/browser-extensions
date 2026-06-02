# nodia

A resident macOS menu-bar app that fuzzy-searches **all** Arc sidebar tabs —
including the sleeping/unrealized tabs a browser extension can't see.

- **⌘⇧K** (global) → centered search panel. Type to fuzzy-search; **↑↓** to
  move, **⏎** to jump to the tab (waking it if it was asleep), **esc** to close.
- Matched characters are highlighted; rows show favicon + title + Space.
- Themeable frosted-glass UI (7 palettes, 4 fonts, size) via the ⚙️ settings
  window. Menu-bar icon: left-click to search, right-click for Settings / Quit.

## How it works

| Need        | Source (all local, offline)                                           |
|-------------|-----------------------------------------------------------------------|
| Tab list    | `~/Library/Application Support/Arc/StorableSidebar.json`               |
| Favicons    | Arc's Chromium `…/User Data/Default/Favicons` SQLite DB (read-only)    |
| Activation  | `osascript` → Arc AppleScript `select` + `focus`; fallback `open <url>`|

See [DESIGN.md](./DESIGN.md) for details.

## Build & run

```sh
swift run nodia              # run from source
swift run nodia-probe doc    # headless smoke test of the data layer
```

## Install as an app

```sh
./build-app.sh               # builds .dist/nodia.app (release, ad-hoc signed)
cp -R .dist/nodia.app /Applications/
open /Applications/nodia.app
```

On first activation macOS asks to allow nodia to control Arc (Automation) —
allow it. Until then, activation falls back to opening the URL in a new tab.

## Requirements

macOS 14+, Swift 5.9+, the Arc browser.
