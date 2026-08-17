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
A native macOS menu-bar app for finding things again — plus the MV3 extension
that feeds it. **⌘⇧K** fuzzy-searches all Arc sidebar tabs (including the
sleeping ones an extension can't see) *and* everything saved into an Obsidian
vault, from one prompt. The extension files pages into that vault as
bookmark / read-later / todo, with optional LLM summaries routed by host so
internal pages never reach a public model. See [nodia/README.md](./nodia/README.md).
