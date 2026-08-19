// The save panel, injected into the page. Two stages:
//
//   1. Pick a kind — instant, no network, no page text read yet.
//   2. Only for archive saves: extract, summarize, review, confirm.
//
// The split exists because the two kinds want opposite things. A console link
// is saved to be *clicked later*; summarizing it costs 15 seconds for text
// you'll never read. An archive entry is saved to be *found later*, and the
// summary is the whole point.
//
// Everything here runs in the page via chrome.scripting.executeScript, so it
// is written as self-contained functions with no imports and no state beyond
// `window.__nodiaPanel`. Markup lives in a shadow root: page CSS can't reach
// in, and nothing here leaks out.

function nodiaPanelStyles() {
  return `
    :host { all: initial; }
    * { box-sizing: border-box; }
    /* Sized for what a summary actually is: 100–150 Chinese characters, which
       needs roughly seven lines to read without scrolling. */
    .card {
      width: 460px;
      font: 13px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: #1f2328; background: #ffffff;
      border: 1px solid #d0d7de; border-radius: 12px;
      box-shadow: 0 8px 28px rgba(0,0,0,.16);
      overflow: hidden; animation: in .18s ease-out;
    }
    @keyframes in { from { opacity: 0; transform: translateY(-6px); } }
    .body { padding: 12px 14px 10px; }
    .title { font-weight: 600; margin-bottom: 8px; line-height: 1.4;
             display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
             overflow: hidden; }
    .status { color: #656d76; font-size: 12px; display: flex; align-items: center; gap: 6px; }
    .spin { width: 11px; height: 11px; border: 2px solid currentColor;
            border-right-color: transparent; border-radius: 50%;
            animation: sp .7s linear infinite; }
    @keyframes sp { to { transform: rotate(360deg); } }
    textarea { width: 100%; min-height: 150px; max-height: 45vh; resize: vertical;
               font: inherit; padding: 8px 10px; color: #1f2328; background: #f6f8fa;
               border: 1px solid #d0d7de; border-radius: 8px; }
    /* The summary already on disk: readable, scrollable, clearly not the field
       you're editing. */
    .prev { font-size: 12px; line-height: 1.6; color: #656d76;
            background: rgba(127,127,127,.07); border: 1px solid #d0d7de;
            border-radius: 8px; padding: 8px 10px;
            max-height: 132px; overflow-y: auto; white-space: pre-wrap; }
    .prev.empty { font-style: italic; }
    /* Live byte counts while the model works. Tabular figures so the digits
       don't jitter as they tick up. */
    .meter { font-size: 11px; color: #656d76; margin-top: 6px;
             font-variant-numeric: tabular-nums; }
    .label { font-size: 11px; color: #656d76; margin: 10px 0 4px; }
    .label:first-child { margin-top: 0; }
    .meta { font-size: 12px; color: #656d76; margin-bottom: 8px; }
    .meta b { font-weight: 600; color: #1f2328; }
    .kw { width: 100%; margin-top: 6px; font: inherit; font-size: 12px;
          padding: 6px 10px; color: #1f2328; background: #f6f8fa;
          border: 1px solid #d0d7de; border-radius: 8px; }
    textarea:focus, .kw:focus { outline: none; border-color: #0969da; }
    .warn { color: #9a6700; background: #fff8c5; border: 1px solid #eac54f;
            border-radius: 8px; padding: 8px 10px; font-size: 12px; }
    .dup { color: #0969da; font-size: 12px; margin-top: 8px; }
    .hint { color: #656d76; font-size: 11px; margin-top: 8px; }
    .actions { display: flex; gap: 10px; padding: 10px 14px;
               border-top: 1px solid #d0d7de; background: rgba(127,127,127,.06); }
    /* The kinds are one choice, so they read as one control: joined, same
       colour, told apart by icon rather than by emphasis. */
    .group { display: flex; flex: 1; }
    .group button {
      flex: 1; display: flex; align-items: center; justify-content: center; gap: 5px;
      font: inherit; padding: 7px 4px; cursor: pointer;
      color: #1f2328; background: #ffffff;
      border: 1px solid #d0d7de; border-right-width: 0; border-radius: 0;
    }
    .group button:first-child { border-radius: 7px 0 0 7px; }
    .group button:last-child { border-radius: 0 7px 7px 0; border-right-width: 1px; }
    .group button:hover { background: #eef1f4; }
    .group button.preferred { font-weight: 600; }
    .group button.preferred .dot { opacity: 1; }
    .dot { width: 4px; height: 4px; border-radius: 50%; background: currentColor;
           opacity: 0; flex: none; }
    svg { width: 13px; height: 13px; flex: none; }
    .ghost { flex: 0 0 auto; font: inherit; padding: 7px 12px; cursor: pointer;
             color: #656d76; background: #f6f8fa;
             border: 1px solid #d0d7de; border-radius: 7px; }
    .ghost:hover { border-color: #868f99; }
    .save { flex: 1; font: inherit; font-weight: 600; padding: 7px 4px; cursor: pointer;
            color: #fff; background: #1f883d; border: 1px solid #1f883d; border-radius: 7px; }
    kbd { font: inherit; font-size: 10px; opacity: .65; }
    @media (prefers-color-scheme: dark) {
      .card { color: #e6edf3; background: #1c1f24; border-color: #383e46; }
      .title { color: #e6edf3; }
      textarea, .kw { color: #e6edf3 !important; background: #22262c !important;
                      border-color: #383e46 !important; }
      .actions { border-color: #383e46; }
      .group button { color: #e6edf3; background: #1c1f24; border-color: #383e46; }
      .group button:hover { background: #2a2f36; }
      .ghost { color: #e6edf3; background: #22262c; border-color: #383e46; }
      .hint, .status, .label, .meta, .meter { color: #8b949e; }
      .meta b { color: #e6edf3; }
      .prev { color: #a5aeb8; border-color: #383e46; }
    }
  `;
}

/** Kind buttons: inline SVG so the icons inherit colour and render the same
 *  everywhere. Labels name what each kind is *for*. */
function nodiaPanelKinds() {
  const icon = {
    // console: a terminal prompt — a place you jump to
    bookmark: '<path d="M2.5 3.5h11v9h-11z"/><path d="M5 6.6l1.8 1.6L5 9.8"/><path d="M8.6 10h3"/>',
    // archive: a box you file things into
    readlater: '<path d="M2 4.5h12v3H2z"/><path d="M3 7.5v6h10v-6"/><path d="M6.5 10h3"/>',
    // todo: a checkbox
    todo: '<rect x="2.2" y="2.2" width="11.6" height="11.6" rx="2"/><path d="M5 8.2l2.2 2.2L11 6.4"/>',
  };
  return [
    ["bookmark", "平台", "1", icon.bookmark],
    ["readlater", "档案", "2", icon.readlater],
    ["todo", "待办", "3", icon.todo],
  ];
}

function nodiaPanelSvg(path) {
  return `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"
    stroke-linecap="round" stroke-linejoin="round">${path}</svg>`;
}

/** Builds the shadow-root card and registers it as the live panel.
 *  Page-supplied text is never interpolated into this markup — callers set it
 *  with textContent, because a page title is written by the page. */
function nodiaPanelMount(bodyHTML) {
  const HOST_ID = "nodia-review-host";
  document.getElementById(HOST_ID)?.remove();

  const host = document.createElement("div");
  host.id = HOST_ID;
  host.style.cssText = `
    position: fixed !important; top: 16px !important; right: 16px !important;
    z-index: 2147483647 !important; all: initial;
  `;
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
    <style>${nodiaPanelStyles()}</style>
    <div class="card">
      <div class="body">${bodyHTML}</div>
      <div class="actions"></div>
    </div>
  `;
  document.documentElement.appendChild(host);
  window.__nodiaPanel = { host, root };
  return { host, root };
}

/** A button appended to the action bar. */
function nodiaPanelButton(root, { className, label, onClick }) {
  const b = document.createElement("button");
  b.className = className;
  b.textContent = label;
  b.addEventListener("click", onClick);
  root.querySelector(".actions").appendChild(b);
  return b;
}

/**
 * Stage 1 — show the page and ask which kind. Resolves with the kind, or null
 * if cancelled. Nothing has been read from the page or sent anywhere yet.
 */
function nodiaPanelChooseKind({ title, existsIn, defaultKind }) {
  const { host, root } = nodiaPanelMount(`
    <div class="title"></div>
    ${existsIn ? `<div class="dup"></div>` : ""}
    <div class="hint"><kbd>1/2/3</kbd> 选类型 · <kbd>⏎</kbd> 上次用的 · <kbd>esc</kbd> 取消</div>
  `);
  root.querySelector(".title").textContent = title || "(无标题)";
  if (existsIn) root.querySelector(".dup").textContent = `已存在于 ${existsIn}`;
  root.querySelector(".actions").innerHTML = `<div class="group"></div>`;

  return new Promise((resolve) => {
    let done = false;
    const finish = (kind) => {
      if (done) return;
      done = true;
      document.removeEventListener("keydown", onKey, true);
      if (kind === null) {
        host.remove();
        delete window.__nodiaPanel;
      }
      resolve(kind);
    };

    const group = root.querySelector(".group");
    for (const [kind, label, key, path] of nodiaPanelKinds()) {
      const b = document.createElement("button");
      b.innerHTML = `${nodiaPanelSvg(path)}<span>${label}</span><span class="dot"></span>`;
      b.title = `${label}（${key}）`;
      if (kind === defaultKind) b.classList.add("preferred");
      b.addEventListener("click", () => finish(kind));
      group.appendChild(b);
    }

    nodiaPanelButton(root, { className: "ghost", label: "取消", onClick: () => finish(null) });

    const onKey = (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); return finish(null); }
      if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); return finish(defaultKind); }
      const hit = nodiaPanelKinds().find(([, , key]) => key === e.key);
      if (hit) { e.preventDefault(); e.stopPropagation(); finish(hit[0]); }
    };
    document.addEventListener("keydown", onKey, true);
  });
}

/**
 * Stage 1, alternate — the link is already in the vault. Shows what it says
 * today and offers to describe it again, or to take it out.
 * Resolves "regenerate", "remove", or null.
 *
 * Two things make a stored summary go stale: it was saved before summarizing
 * existed at all, or the page has been rewritten since. Both are invisible
 * until you can see the old text next to the page it claims to describe.
 */
function nodiaPanelExisting({ title, existsIn, kindLabel, summary, keywords, summaryAt }) {
  const { host, root } = nodiaPanelMount(`
    <div class="title"></div>
    <div class="meta"></div>
    <div class="label"></div>
    <div class="prev"></div>
    <div class="hint"><kbd>⏎</kbd> 重新生成 · <kbd>esc</kbd> 关闭</div>
  `);
  root.querySelector(".title").textContent = title || "(无标题)";

  const meta = root.querySelector(".meta");
  meta.innerHTML = `已存在 · <b></b> · <span class="file"></span>`;
  meta.querySelector("b").textContent = kindLabel || "收藏";
  meta.querySelector(".file").textContent = existsIn || "收藏库";

  root.querySelector(".label").textContent = summaryAt
    ? `当前摘要（${summaryAt}）`
    : "当前摘要";

  const prev = root.querySelector(".prev");
  if (summary) {
    prev.textContent = summary;
  } else {
    prev.classList.add("empty");
    prev.textContent = "这条还没有摘要 — 存的时候还没有这个功能，或者当时跳过了。";
  }

  if (keywords && keywords.length) {
    const kwLabel = document.createElement("div");
    kwLabel.className = "label";
    kwLabel.textContent = "检索词";
    const kwBox = document.createElement("div");
    kwBox.className = "prev";
    kwBox.textContent = keywords.join("、");
    prev.after(kwLabel, kwBox);
  }

  return new Promise((resolve) => {
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      document.removeEventListener("keydown", onKey, true);
      if (result === null) {
        host.remove();
        delete window.__nodiaPanel;
      }
      resolve(result);
    };

    nodiaPanelButton(root, {
      className: "save",
      label: summary ? "重新生成摘要" : "生成摘要",
      onClick: () => finish("regenerate"),
    });
    // No keyboard shortcut, and not the default button. Removing is the only
    // thing here that destroys something, and the two actions sit side by side
    // — ⏎ has to keep meaning the harmless one.
    nodiaPanelButton(root, { className: "ghost", label: "移除", onClick: () => finish("remove") });
    nodiaPanelButton(root, { className: "ghost", label: "关闭", onClick: () => finish(null) });

    const onKey = (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); return finish(null); }
      if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); return finish("regenerate"); }
    };
    document.addEventListener("keydown", onKey, true);
  });
}

/**
 * Stage 2 of removing — the last thing between a click and a deleted block of
 * somebody's Markdown. Resolves true to go ahead, null to back out.
 *
 * It repeats what is about to go rather than asking "are you sure": the useful
 * question is not whether you meant to click, it's whether *this* is the entry
 * you had in mind. The title and the file answer that; "are you sure" doesn't.
 */
function nodiaPanelConfirmRemove({ title, existsIn, kindLabel, summary }) {
  const { host, root } = nodiaPanelMount(`
    <div class="title"></div>
    <div class="meta"></div>
    <div class="label">将从收藏库删除</div>
    <div class="prev"></div>
    <div class="hint">这一步没有撤销 · <kbd>esc</kbd> 取消</div>
  `);
  root.querySelector(".title").textContent = title || "(无标题)";

  const meta = root.querySelector(".meta");
  meta.innerHTML = `<b></b> · <span class="file"></span>`;
  meta.querySelector("b").textContent = kindLabel || "收藏";
  meta.querySelector(".file").textContent = existsIn || "收藏库";

  const prev = root.querySelector(".prev");
  if (summary) {
    prev.textContent = summary;
  } else {
    prev.classList.add("empty");
    prev.textContent = "这条没有摘要。";
  }

  return new Promise((resolve) => {
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      document.removeEventListener("keydown", onKey, true);
      if (!result) {
        host.remove();
        delete window.__nodiaPanel;
      }
      resolve(result);
    };

    nodiaPanelButton(root, { className: "save", label: "确认移除", onClick: () => finish(true) });
    nodiaPanelButton(root, { className: "ghost", label: "取消", onClick: () => finish(null) });

    // esc cancels; ⏎ deliberately does nothing. Reaching this panel means a
    // click, and the confirmation is worth nothing if the same key that
    // regenerated a summary one screen ago now deletes the entry.
    const onKey = (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); finish(null); }
    };
    document.addEventListener("keydown", onKey, true);
  });
}

/**
 * Between stages: the archive path is about to read the page and call a model.
 *
 * `detail` is the live byte count from the model. A spinner alone can't tell a
 * model that is thinking from a connection that died — and this wait runs tens
 * of seconds — so the numbers, not the animation, are what says it's alive.
 */
function nodiaPanelBusy(text, detail) {
  const panel = window.__nodiaPanel;
  if (!panel) return;
  const body = panel.root.querySelector(".body");
  const hint = body.querySelector(".hint");
  if (hint) hint.remove();
  let status = body.querySelector(".status");
  if (!status) {
    status = document.createElement("div");
    status.className = "status";
    status.innerHTML = `<span class="spin"></span><span class="msg"></span>`;
    body.appendChild(status);
  }
  status.querySelector(".msg").textContent = text;

  let meter = body.querySelector(".meter");
  if (detail) {
    if (!meter) {
      meter = document.createElement("div");
      meter.className = "meter";
      body.appendChild(meter);
    }
    meter.textContent = detail;
  } else if (meter) {
    meter.remove();
  }
  panel.root.querySelector(".actions").style.display = "none";
}

/**
 * Stage 2 — show what was captured and wait for approval.
 * Resolves {summary, keywords} or null.
 *
 * `previous` puts the stored summary above the new one, which is the whole
 * decision when replacing: whether this actually describes the page better.
 */
function nodiaPanelConfirm({ summary, keywords, reason, previous, saveLabel, allowEmpty }) {
  const panel = window.__nodiaPanel;
  if (!panel) return null;
  const root = panel.root;
  const body = root.querySelector(".body");
  // Rebuild everything under the heading: on the regenerate path this panel
  // is already showing the old summary, and it belongs under its own label now.
  for (const el of [...body.children]) {
    if (!el.classList.contains("title") && !el.classList.contains("meta")) el.remove();
  }

  const add = (className, text) => {
    const el = document.createElement("div");
    el.className = className;
    el.textContent = text;
    body.appendChild(el);
    return el;
  };

  if (previous) {
    add("label", "原摘要");
    add("prev", previous);
  }

  if (summary) {
    if (previous) add("label", "新摘要");
    const ta = document.createElement("textarea");
    ta.value = summary;
    ta.spellcheck = false;
    body.appendChild(ta);

    // Keywords are what make this findable later, so they're editable too —
    // you know better than the model which word you'll actually search for.
    const kw = document.createElement("input");
    kw.type = "text";
    kw.className = "kw";
    kw.value = (keywords || []).join(", ");
    kw.placeholder = "检索词，逗号分隔";
    kw.spellcheck = false;
    body.appendChild(kw);
  } else {
    // Say why there's no summary — a broken endpoint should be visible here,
    // not discovered later as empty fields in the vault.
    add("warn", `没有摘要：${reason || "未知原因"}`);
  }

  // Saving a link with no summary is legitimate — the link still gets filed.
  // Replacing a stored summary with nothing is not, so the regenerate path
  // leaves only one move when the model came back empty: keep what's there.
  const canSave = !!summary || !!allowEmpty;

  const hint = document.createElement("div");
  hint.className = "hint";
  hint.innerHTML = canSave
    ? "<kbd>⏎</kbd> 保存 · <kbd>esc</kbd> 取消"
    : "<kbd>esc</kbd> 关闭，保留原有内容";
  body.appendChild(hint);

  const actions = root.querySelector(".actions");
  actions.style.display = "";
  actions.innerHTML = "";

  return new Promise((resolve) => {
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      document.removeEventListener("keydown", onKey, true);
      panel.host.remove();
      delete window.__nodiaPanel;
      resolve(result);
    };
    const collect = () => ({
      summary: root.querySelector("textarea")?.value.trim() || "",
      keywords: (root.querySelector(".kw")?.value || "")
        .split(/[,，]/).map((s) => s.trim()).filter(Boolean),
    });

    if (canSave) {
      nodiaPanelButton(root, {
        className: "save",
        label: saveLabel || "存入档案",
        onClick: () => finish(collect()),
      });
    }
    nodiaPanelButton(root, {
      className: "ghost",
      label: canSave ? "取消" : "关闭",
      onClick: () => finish(null),
    });

    const onKey = (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); return finish(null); }
      // Enter saves, but not while you're editing the summary — a newline
      // there should stay a newline.
      const tag = root.activeElement?.tagName;
      if (e.key === "Enter" && canSave && tag !== "TEXTAREA") {
        e.preventDefault(); e.stopPropagation(); finish(collect());
      }
    };
    document.addEventListener("keydown", onKey, true);
  });
}

/** Tear the panel down without deciding anything (used on errors). */
function nodiaPanelClose() {
  window.__nodiaPanel?.host.remove();
  delete window.__nodiaPanel;
}
