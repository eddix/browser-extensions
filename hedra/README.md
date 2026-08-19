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

图形是两个推子，画在这里而不是从图标集里拿的。[Phosphor Icons](https://phosphoricons.com)
的 `faders` 是三轨三把手，在 16px 下就是六条约一像素宽的笔画，渲染出来是噪点 ——
而 16px 正是工具栏里的实际尺寸，也是唯一天天看到的尺寸。

透明底、单色，跟工具栏里其它图标一个路子。没有 duotone 的第二层，这点和 nodia 不同：
透明底上 `opacity` 不是「更淡的同色」，是和背后的东西混合，同一条 0.38 的轨道在浅色
工具栏上太淡、在深色上又太暗。轨道和把手改用粗细区分，任何尺寸下都不花钱。

颜色由 `tools/icon-contrast.py` 守着，对浅色和深色两种工具栏各算一遍。两端夹逼是有
上限的（对脚本里那两个参考底色是 3.55:1），所以「不够清楚就调深」这条路走不通 ——
要突破只能换参考底色，或者按 `prefers-color-scheme` 出两套图。
