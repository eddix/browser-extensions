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
- **Jump templates** — one entry for a whole family of platform URLs. Search
  its name, then fill the parameters one at a time (candidates are a list;
  anything without one takes free input), and it opens.
- **⌘T** browse every jump template, **⌘D** duplicate clustering, **⌘G**
  by-domain browsing.
- Themeable frosted-glass UI (7 palettes, 4 fonts, size) via the settings
  window. Menu-bar icon: left-click to search, right-click for Settings / Quit.

## Why search and saving live in one app

A browser tab bar gets used as three different things at once, and they have
nothing in common except being a URL you didn't want to lose:

| Used as | What it really is | Lifetime | Done when |
|---|---|---|---|
| **platform** | a console you jump to (Ledger, Grafana, ConfigHub) — a **staging area**, not an asset | short: until it becomes a launcher script | it's a script; the entry can go |
| **archive** | the actual long-term asset — most of it never gets read again, and that's fine | permanent | never; it just has to stay findable |
| **todo** | work you can't do now | until finished | completed |

The middle row is the one that gets mislabeled. "Read later" sounds like a
debt you owe — but you won't read 80% of it, and that isn't the failure. Its
job is to answer *"I saved something about opening an HSBC account, where is
it?"* months later. That's why it's the only kind that gets a summary and
keywords: it is saved to be **found**, while a console link is saved to be
**clicked**, and summarizing the latter would spend 15 seconds on text nobody
will ever read.

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

- **Click the icon** → the panel asks for the kind first (`1`/`2`/`3`, `⏎` for
  the one you used last, `esc` to cancel). Nothing has been read from the page
  at that point.
  - **平台 / 待办** → saved instantly. The page text is never read at all.
  - **档案** → *then* it extracts, summarizes, and shows you the summary and
    keywords before writing. Edit either if the model drifted, `⏎` to save.
- **Right-click** → save as a given kind directly, skipping the panel.
- TODOs are written as `- [ ]` checkboxes into `Bookmark/00-Todo.md`, so
  Obsidian Tasks and your daily note can pick them up; a tab bar can't
  represent "done".
- The icon turns green on pages already in the vault, and the panel says so
  before you save a duplicate.

Asking for the kind *before* doing the work is what keeps the common case
fast: the kind decides whether a model is called at all.

The review step is deliberate. Saving without seeing the result is what
produced the original problem: every link already in the vault was *also*
still pinned in the browser, because a save you can't inspect isn't one you'll
trust enough to close the tab on. Reviewing costs a few seconds and buys the
thing the whole tool is for. It also surfaces a broken summary endpoint at
save time rather than weeks later, as a vault full of empty `summary:` fields.

Expect the summary itself to take a few seconds — on a thinking-capable model
(most current ones) it can be 5–15s, and some, like `glm-5.3`, don't allow
thinking to be switched off. The panel shows progress while it works.

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

## Jump templates

Internal platforms encode the same three things over and over — the region in
the hostname, the feature in the path, the target in the query:

```
https://{site}/confighub/namespace/{namespace}?env={env}
        └─┬──┘ └──────┬─────┘            └──┬──┘
         site      feature               target
```

Without a way to express that, each combination has to be saved separately —
which is how the same monitoring console ends up bookmarked once per region
(four copies of one Metrics board, in the vault this was built against). A
template collapses the family into one entry:

```markdown
- Metrics 服务大盘
  - url: https://console-{region}.example.com/metrics/overview/server_overview?service={service}&from={window}
  - region: i18n, us, eu
  - window: now-1h, now-6h, now-24h
  - keywords: metrics, 监控
```

**⌘T** lists every template — plain search finds them too, but only if you
remember one exists, and "what can I jump to?" isn't a question search can
answer.

Any `{name}` is a parameter. A field of the same name lists its candidates;
a parameter with no such field takes free input (a service, say). Placeholders can
sit anywhere a string can — including partway through a hostname.

Templates live in the vault as Markdown for the same reason everything else
does: the file outlives this app and is editable without it.

## How it works

| Need | Source (all local, offline) |
|---|---|
| Tab list | `~/Library/Application Support/Arc/StorableSidebar.json` |
| Favicons | Arc's Chromium `…/User Data/Default/Favicons` SQLite DB (read-only) |
| Activation | `osascript` → Arc AppleScript `select` + `focus`; fallback `open <url>` |
| Saved links | Obsidian vault Markdown under `Bookmark/` |
| Jump templates | `Bookmark/00-Jumps.md` (seeded with examples on first run) |
| Save endpoint | `127.0.0.1:8787`, token-authenticated |
| Summaries | your own LLM endpoints, routed by host (intranet vs public) |

Each summary endpoint speaks either wire format, selected per endpoint:

| | OpenAI | Anthropic |
|---|---|---|
| Path | `/v1/chat/completions` | `/v1/messages` |
| Auth | `Authorization: Bearer` | `x-api-key` + `anthropic-version` |
| System prompt | a `role: "system"` message | top-level `system` field |
| Reply text | `choices[0].message.content` | `content` blocks of `type: "text"` |

The last row is the one that bites: `content` is an array, and on a
thinking-capable model the reasoning block comes first — indexing `content[0]`
returns empty text. `temperature` is also omitted on the Anthropic path, since
current Claude models reject it outright.

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
