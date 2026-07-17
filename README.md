# browser-extensions

A small collection of self-made browser tools.

## Projects

### [hedra](./hedra)
A Manifest V3 extension that adds, overrides, or removes HTTP request/response
headers per domain, driven by toggleable presets. A zero-telemetry ModHeader
replacement: pure `declarativeNetRequest`, so the extension never sees page
content or traffic. Most-specific-domain-wins priority, live conflict
detection, and radio-style exclusive presets for switching PPE lanes.
See [hedra/README.md](./hedra/README.md).

### [nodia](./nodia)
A native macOS menu-bar app that fuzzy-searches **all** Arc sidebar tabs —
including the sleeping/unrealized ones the extension can't see. Global hotkey
**⌘⇧K**, match highlighting, and a themeable frosted-glass UI. It reads Arc's
local `StorableSidebar.json` and Chromium favicon database, and activates the
chosen tab through Arc's AppleScript interface. See [nodia/README.md](./nodia/README.md).
