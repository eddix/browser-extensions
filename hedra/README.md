# hedra

A Manifest V3 extension that adds, overrides, or removes HTTP request/response
headers per domain, driven by toggleable presets.

Built as a trustworthy replacement for ModHeader (which was flagged for
silently exfiltrating page content): hedra is **structurally unable** to see
your traffic. It only writes `declarativeNetRequest` rules — the browser
engine applies them; extension code never touches requests, responses, or page
content. No telemetry, no remote requests, config stays in
`chrome.storage.local`. Small enough to audit in one sitting.

## Features

- **Presets**: each has a name, a domain list, a set of header rules, and an
  on/off toggle. A master switch kills everything at once; the toolbar badge
  shows how many presets are live (red `!` if rules failed to apply).
- **Domains** match the request's target domain, subdomains included
  (`example.com` covers `api.example.com`). Leave empty = all sites. Each
  domain has its own checkbox, so you can temporarily drop a few from a preset
  without deleting them (all-unchecked makes the preset inert — it does *not*
  mean all sites).
- **Header rules**: `set` (add-or-overwrite) or `remove`, on request or
  response headers.
- **Most-specific-domain wins**: a rule for `api.example.com` overrides one
  for `example.com`, which overrides an all-sites rule. Implemented via DNR
  priority = domain depth; list order only breaks exact ties.
- **Conflict detection**, live in the popup, two levels:
  - ℹ *override* — one enabled preset shadows another on a parent/child
    domain pair. Legitimate layering; shown for awareness.
  - ⚠ *conflict* — two enabled presets touch the same header on the *same*
    domain scope. The details panel names the winner.
- **Exclusive groups**: presets with identical domain sets and identical
  header sets (e.g. several PPE-lane presets differing only in value) are
  radio buttons — enabling one auto-disables the others. One click to switch
  lanes. Equivalence compares the full domain list, ignoring per-domain
  checkboxes, so temporarily unchecking a domain doesn't break the group.
- **Duplicate**: clone a preset straight into the editor (the copy arrives
  disabled) — the quick way to derive the next lane variant for the same
  domain group.
- **Import/export** presets as JSON (imported presets arrive disabled).

## Install

No build step. In Arc/Chrome: `chrome://extensions` (or `arc://extensions`) →
enable Developer mode → *Load unpacked* → pick this `hedra/` directory.

## Permissions, explained

| Permission | Why |
|---|---|
| `declarativeNetRequestWithHostAccess` | register header-modification rules |
| `host_permissions: <all_urls>` | MV3 requires host access for `modifyHeaders`; granting all upfront keeps per-preset setup frictionless and enables all-site presets |
| `storage` | presets live in `chrome.storage.local` (never `sync` — header values often hold tokens, and sync would upload them) |

## Files

| File | Role |
|---|---|
| `manifest.json` | MV3 manifest |
| `popup.html` / `popup.js` | the entire UI + rule compiler + conflict detection |
| `background.js` | ~10 lines: restore the badge after browser restart |

## 图标

`icons/icon.svg` 是源，同目录的 PNG 是产物；改了 SVG 跑仓库根目录的
`tools/render-icons.sh` 重新生成。Chrome 的图标只吃位图，所以两份都得在仓库里。
图形是 [Phosphor Icons](https://phosphoricons.com) 的 `faders`，duotone 字重（MIT）。

它在方块里画到 88/128，而 nodia 的 archive 是 72/128 —— 同一个数字不等于同样的大小：
faders 是六条细笔画，archive 是两条粗的，几何尺寸对齐时细的那个在 16px 先糊掉，
而 16px 正是工具栏里的实际尺寸。
