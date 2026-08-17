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
    .card {
      width: 380px;
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
    textarea { width: 100%; min-height: 76px; resize: vertical; font: inherit;
               padding: 8px 10px; color: #1f2328; background: #f6f8fa;
               border: 1px solid #d0d7de; border-radius: 8px; }
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
      .hint, .status { color: #8b949e; }
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

/**
 * Stage 1 — show the page and ask which kind. Resolves with the kind, or null
 * if cancelled. Nothing has been read from the page or sent anywhere yet.
 */
function nodiaPanelChooseKind({ title, existsIn, defaultKind }) {
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
      <div class="body">
        <div class="title"></div>
        ${existsIn ? `<div class="dup">已存在于 ${existsIn}</div>` : ""}
        <div class="hint"><kbd>1/2/3</kbd> 选类型 · <kbd>⏎</kbd> 上次用的 · <kbd>esc</kbd> 取消</div>
      </div>
      <div class="actions"><div class="group"></div></div>
    </div>
  `;
  root.querySelector(".title").textContent = title || "(无标题)";
  document.documentElement.appendChild(host);
  window.__nodiaPanel = { host, root };

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

    const cancel = document.createElement("button");
    cancel.className = "ghost";
    cancel.textContent = "取消";
    cancel.addEventListener("click", () => finish(null));
    root.querySelector(".actions").appendChild(cancel);

    const onKey = (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); return finish(null); }
      if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); return finish(defaultKind); }
      const hit = nodiaPanelKinds().find(([, , key]) => key === e.key);
      if (hit) { e.preventDefault(); e.stopPropagation(); finish(hit[0]); }
    };
    document.addEventListener("keydown", onKey, true);
  });
}

/** Between stages: the archive path is about to read the page and call a model. */
function nodiaPanelBusy(text) {
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
  panel.root.querySelector(".actions").style.display = "none";
}

/**
 * Stage 2 — show what was captured and wait for approval.
 * Resolves {summary, keywords} or null.
 */
function nodiaPanelConfirm({ summary, keywords, reason }) {
  const panel = window.__nodiaPanel;
  if (!panel) return null;
  const root = panel.root;
  const body = root.querySelector(".body");
  body.querySelector(".status")?.remove();

  if (summary) {
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
    const warn = document.createElement("div");
    warn.className = "warn";
    // Say why there's no summary — a broken endpoint should be visible here,
    // not discovered later as empty fields in the vault.
    warn.textContent = `没有摘要：${reason || "未知原因"}`;
    body.appendChild(warn);
  }

  const hint = document.createElement("div");
  hint.className = "hint";
  hint.innerHTML = "<kbd>⏎</kbd> 保存 · <kbd>esc</kbd> 取消";
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

    const save = document.createElement("button");
    save.className = "save";
    save.textContent = "存入档案";
    save.addEventListener("click", () => finish(collect()));
    actions.appendChild(save);

    const cancel = document.createElement("button");
    cancel.className = "ghost";
    cancel.textContent = "取消";
    cancel.addEventListener("click", () => finish(null));
    actions.appendChild(cancel);

    const onKey = (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); return finish(null); }
      // Enter saves, but not while you're editing the summary — a newline
      // there should stay a newline.
      const tag = root.activeElement?.tagName;
      if (e.key === "Enter" && tag !== "TEXTAREA") {
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
