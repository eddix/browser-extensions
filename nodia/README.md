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
- **快速打开** — one entry for a whole family of platform URLs. Search its
  name, then fill in a small form — every field prefilled with what you used
  last — and **⏎** opens it, switching to the tab if you already have one.
- **⌘T** browse every quick-open template, **⌘D** duplicate clustering, **⌘G**
  by-domain browsing.
- Themeable glass UI (10 palettes, 4 fonts, size, tint strength) via the
  settings window. Menu-bar icon: left-click to search, right-click for
  Settings / Quit.

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
- The icon turns green on pages already in the vault. Clicking it there doesn't
  offer to save again — saving a duplicate does nothing — it shows what the
  entry currently says and offers to describe it again.

### Re-summarizing

A summary describes a page as it was the day it was saved. Two things make that
stop being true: most of the archive predates summarizing entirely, and
documents get rewritten under a stable URL. Either way the vault keeps
answering searches with a description that no longer matches the page.

So the summary is replaceable in place. The panel shows the stored text, then
the newly generated one next to it, and only writes after you've compared them.
`saved-at` is left alone — the link is as old as it always was — and a separate
`summary-at` records when the description was last refreshed, which is what
makes staleness answerable at all.

Only the target entry's own `summary`/`keywords` lines are rewritten. Every
other byte of the file — other entries, frontmatter, notes you added by hand —
is carried through untouched, and a regeneration that comes back empty offers
no way to overwrite a good summary with nothing.

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

### Signing the build

`build-app.sh` ad-hoc signs by default, which works but has one cost: an ad-hoc
signature has no identity, so the system falls back to hashing the binary
itself. Every rebuild produces a different hash, the system sees a brand-new
app, and the privacy permissions and Keychain access granted to the last build
are void — you re-approve the Documents folder on every install.

A signing certificate fixes that, and a **self-signed one is enough** — macOS
records permissions against the app's designated requirement, which becomes the
bundle ID plus the certificate rather than the binary's hash:

```
ad-hoc:      designated => cdhash H"394b0c58…"                    ← changes every build
certificate: designated => identifier "com.eddix.nodia" and certificate root = H"afb52521…"
```

Create one in Keychain Access (Certificate Assistant → Create a Certificate →
type **Code Signing**, self-signed), then:

```sh
export NODIA_SIGN_IDENTITY="Your Signing Identity"   # put this in ~/.zshrc
./build-app.sh
```

One certificate can sign every app you build — permissions are keyed on bundle
ID *and* certificate, so separate apps stay separate. It is for local builds
only: distributing a binary to other machines needs a Developer ID certificate
and notarization, which self-signing can't provide. **Never commit the
certificate**: whoever holds the private key can sign something that inherits
the permissions you granted.

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

## 快速打开

Internal platforms encode the same three things over and over — the site in
the hostname, the feature in the path, the target in the query:

```
https://{site}/confighub/namespace/{namespace}?env={env}
        └─┬──┘ └──────┬─────┘            └──┬──┘
         site      feature               target
```

Without a way to express that, each combination has to be saved separately —
which is how the same monitoring console ends up bookmarked once per region
(four copies of one board, in the vault this was built against). A template
collapses the family into one entry, in `Bookmark/00-QuickOpen.json`:

```json
{
  "shared": {
    "region": ["SG=sg", "VA=us", "EU=eu-central-1"]
  },
  "templates": [
    {
      "name": "对账任务详情",
      "keywords": ["ledger", "对账"],
      "url": "https://ledger.example.net/#/{region}/reconciliation-detail/{task_id}",
      "params": {
        "region": { "use": "region" },
        "task_id": { "input": true }
      }
    }
  ]
}
```

Any `{name}` in the URL is a parameter, and the URL — not the `params` object —
decides the order you're asked for them: JSON objects have no order once
parsed, and reading left to right through the address is how you'd fill a form
anyway. Placeholders sit anywhere a string can, including partway through a
hostname.

Three things the format has to get right, each learned from a template that
didn't work without it:

- **A candidate's label is not its value.** `"VA=us"` reads *VA* and expands to
  `us`; the same picker's EU entry expands to `eu-central-1`. Only the first `=`
  splits, since values are URL fragments and routinely contain more.
- **Picking and typing are different gestures.** `choices` renders a list;
  `input` renders a text box. A parameter nobody described defaults to free
  input, which keeps a minimal template down to a name and a URL.
- **The same list appears in template after template.** `shared` names it once
  and `{ "use": "region" }` refers to it — five regions across six templates
  was already six chances to get one wrong.

### The form

Picking a template opens every parameter at once, each prefilled with what you
last put in a parameter of that name — so the common case is ⏎ ⏎, and the
uncommon one is typing into the single field that differs.

| | |
|---|---|
| **⏎** | open, with whatever the fields say right now |
| **⇥** | next field, wrapping; keeps whatever the highlight is on |
| **↑↓** | walk the candidates under the focused field |
| **esc** | back to the list you came from |

⏎ means *open* rather than *next field*, which is only possible because no
field is ever empty. The one exception is free input you've never used, and
there ⏎ moves the cursor into that field instead of refusing — the answer to
"why won't it open" should be the cursor sitting in the reason. The footer
shows the URL as it currently stands, built from the same values that opening
uses, so it can't drift from what actually happens.

Prefill is remembered per parameter *name*, across templates: having just
looked at a namespace's config, its change history is the next thing you want
and it's the same namespace. Two templates can share a name without sharing a
meaning, though — `region` means one set of values on one platform and another
set elsewhere — so a remembered value that isn't among *this* template's
candidates is dropped rather than forced into a URL that can't work.

Free input keeps its last five values as that field's candidate list, since a
parameter with no configured list still has a history.

### Which one you meant

**⌘T** lists every template — plain search finds them too, but only if you
remember one exists, and "what can I open?" isn't a question search can answer.
That list is ordered by use: opening one adds 1 to its score and fades every
score by 2%, so the order blends how often and how recently in a single number.

Decay counts *openings*, not days. Come back from two weeks away and nothing
was opened in the meantime, so the list is exactly as you left it — ordinary
time-based decay would have faded everything toward zero and greeted you with
an order carrying no information. A score halves every ~34 openings, long
enough for the top few to hold still and be worth learning by position.

In plain ⌘⇧K a template outranks a saved link on a tie but loses to an open
tab: reusing the window you already have is the point, and templates have ⌘T of
their own besides. Templates tied with each other fall back to that same score.

### Opening

If a tab is already showing the exact URL, quick open raises it instead of
adding a second copy. "Exact" includes the query string and the fragment,
unlike the normalization used for saved links — platforms that route entirely
through the fragment (`…/#/sg/detail/743188920`) would otherwise all collapse
to their bare domain, and asking for one task would switch you to another.

Two exceptions open a new tab without trying: **Top Apps** (the global
favourites row hangs off the sidebar root rather than any Space, and Arc's
AppleScript can only reach tabs through `spaces → tabs`), and anything whose
window Arc can't find, which falls back the same way activation always has.

### Why JSON and not Markdown

Everything else in the vault is Markdown, and this file was too, as indented
bullets. It's the one file that shouldn't be. The rest of the vault is *content
you'll read*; this is *configuration you write*, and a config syntax
hand-rolled on Markdown bullets had already bought one arbitrary limitation
(candidates were comma-separated, so no value could contain a comma) before
label-vs-value or shared lists were even attempted. What it was becoming was a
worse YAML.

JSON also round-trips cleanly, which the planned "make a template out of this
tab" needs — rewriting a YAML file without destroying its comments and anchors
is a project of its own. The cost, stated plainly: JSON has no comments.
Per-template `note` covers explaining an entry; file-level commentary has
nowhere to go.

Usage — the scores above, the remembered values, the input history — stays out
of this file and in UserDefaults. It changes on every open, and rewriting a
file you hand-edit that often is the round-trip risk picking JSON was meant to
avoid.

## How it works

| Need | Source (all local, offline) |
|---|---|
| Tab list | `~/Library/Application Support/Arc/StorableSidebar.json` |
| Favicons | Arc's Chromium `…/User Data/Default/Favicons` SQLite DB (read-only) |
| Activation | `osascript` → Arc AppleScript `select` + `focus`; fallback `open <url>` |
| Saved links | Obsidian vault Markdown under `Bookmark/` |
| 快速打开模板 | `Bookmark/00-QuickOpen.json` (seeded with examples on first run) |
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
swift test                   # 208 tests, incl. HTTP boundary + summary routing
python3 tools/scrub-check.py # 内网标识词闸门，推之前跑
```

这是公开仓库，示例里的域名和平台名都得是通用的。`scrub-check.py` 扫 git 会发布的
每个文件，命中就打印 `文件:行号` 并以非零退出 —— 词表在脚本里，改动会出现在 diff 里。
上一次泄漏不是因为没扫，是因为扫描命令每次手打，词表在重写时丢了一项，检查自己
悄悄退化了。

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

macOS 26+ and the matching SDK (Xcode 26), the Arc browser, and an Obsidian
vault (any folder of Markdown, really) for the saving half.

The floor is 26 because the panel *is* a piece of the system glass —
`NSGlassEffectView`, which contains the content instead of sitting behind it.
There was a frosted-material fallback for older systems; it went away, because
maintaining a second look nobody here runs cost more than it was worth.
