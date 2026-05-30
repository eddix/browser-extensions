# browser-extensions

A small collection of self-made browser tools.

## Projects

### [arc-tab-sorter](./arc-tab-sorter)
A Manifest V3 browser extension: a toolbar popup that lists and searches the
current Arc tabs, grouped by domain. Limited to tabs the browser has realized.

### [nodia](./nodia)
A native macOS menu-bar app that fuzzy-searches **all** Arc sidebar tabs —
including the sleeping/unrealized ones the extension can't see. Global hotkey
**⌘⇧K**, match highlighting, and a themeable frosted-glass UI. It reads Arc's
local `StorableSidebar.json` and Chromium favicon database, and activates the
chosen tab through Arc's AppleScript interface. See [nodia/README.md](./nodia/README.md).
