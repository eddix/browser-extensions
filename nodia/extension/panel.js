// The review panel, injected into the page on save.
//
// Everything here runs in the page via chrome.scripting.executeScript, so it
// is written as self-contained functions with no imports and no shared state
// beyond `window.__nodiaPanel`.
//
// Markup lives in a shadow root: page CSS cannot reach in and restyle it, and
// nothing here leaks out onto the page.

/** Creates (or reuses) the panel and shows a progress line. */
function nodiaPanelOpen(statusText) {
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
    <style>
      :host { all: initial; }
      * { box-sizing: border-box; }
      .card {
        width: 380px;
        font: 13px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        color: #1f2328; background: #ffffff;
        border: 1px solid #d0d7de; border-radius: 12px;
        box-shadow: 0 8px 28px rgba(0,0,0,.16);
        overflow: hidden;
        animation: in .18s ease-out;
      }
      @keyframes in { from { opacity: 0; transform: translateY(-6px); } }
      @media (prefers-color-scheme: dark) {
        .card { color: #e6edf3; background: #1c1f24; border-color: #383e46; }
        .title { color: #e6edf3 !important; }
        textarea { color: #e6edf3 !important; background: #22262c !important;
                   border-color: #383e46 !important; }
        button { color: #e6edf3; background: #22262c; border-color: #383e46; }
        .hint, .status { color: #8b949e !important; }
      }
      .body { padding: 12px 14px 10px; }
      .title { font-weight: 600; margin-bottom: 8px; line-height: 1.4;
               display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
               overflow: hidden; }
      .status { color: #656d76; font-size: 12px; display: flex; align-items: center; gap: 6px; }
      .spin { width: 11px; height: 11px; border: 2px solid currentColor;
              border-right-color: transparent; border-radius: 50%;
              animation: sp .7s linear infinite; }
      @keyframes sp { to { transform: rotate(360deg); } }
      textarea {
        width: 100%; min-height: 76px; resize: vertical; font: inherit;
        padding: 8px 10px; color: #1f2328; background: #f6f8fa;
        border: 1px solid #d0d7de; border-radius: 8px;
      }
      textarea:focus { outline: none; border-color: #0969da; }
      .warn { color: #9a6700; background: #fff8c5; border: 1px solid #eac54f;
              border-radius: 8px; padding: 8px 10px; font-size: 12px; }
      .dup { color: #0969da; font-size: 12px; margin-top: 8px; }
      .hint { color: #656d76; font-size: 11px; margin-top: 8px; }
      .actions { display: flex; gap: 6px; padding: 10px 14px;
                 border-top: 1px solid #d0d7de; background: rgba(127,127,127,.06); }
      @media (prefers-color-scheme: dark) { .actions { border-color: #383e46; } }
      button { flex: 1; font: inherit; font-weight: 500; padding: 7px 4px;
               border: 1px solid #d0d7de; border-radius: 7px;
               background: #f6f8fa; color: #1f2328; cursor: pointer; }
      button:hover { border-color: #868f99; }
      button.primary { background: #1f883d; border-color: #1f883d; color: #fff; }
      button.ghost { flex: 0 0 auto; padding: 7px 12px; }
      kbd { font: inherit; font-size: 10px; opacity: .65; }
    </style>
    <div class="card">
      <div class="body">
        <div class="title"></div>
        <div class="status"><span class="spin"></span><span class="msg"></span></div>
      </div>
    </div>
  `;

  root.querySelector(".msg").textContent = statusText || "正在处理…";
  document.documentElement.appendChild(host);

  window.__nodiaPanel = {
    host,
    root,
    setStatus(text) {
      const msg = root.querySelector(".msg");
      if (msg) msg.textContent = text;
    },
  };
}

/** Updates the status line of an open panel. */
function nodiaPanelStatus(text) {
  window.__nodiaPanel?.setStatus(text);
}

/**
 * Renders the result and resolves with the user's decision.
 * Returns {action:'save', kind, summary} or {action:'cancel'}.
 */
function nodiaPanelDecide(payload) {
  const panel = window.__nodiaPanel;
  if (!panel) return { action: "cancel" };
  const { title, summary, reason, existsIn, defaultKind } = payload;
  const root = panel.root;

  const KINDS = [
    ["bookmark", "书签", "1"],
    ["readlater", "稍后读", "2"],
    ["todo", "待办", "3"],
  ];

  const body = root.querySelector(".body");
  body.querySelector(".title").textContent = title || "(无标题)";
  body.querySelector(".status").remove();

  if (summary) {
    const ta = document.createElement("textarea");
    ta.value = summary;
    ta.spellcheck = false;
    body.appendChild(ta);
  } else {
    const warn = document.createElement("div");
    warn.className = "warn";
    // Say why there's no summary — a broken endpoint should be visible here,
    // not discovered later by finding empty summaries in the vault.
    warn.textContent = `没有摘要：${reason || "未知原因"}`;
    body.appendChild(warn);
  }

  if (existsIn) {
    const dup = document.createElement("div");
    dup.className = "dup";
    dup.textContent = `已存在于 ${existsIn}，保存会被视为重复`;
    body.appendChild(dup);
  }

  const hint = document.createElement("div");
  hint.className = "hint";
  hint.innerHTML =
    "<kbd>1/2/3</kbd> 选类型 · <kbd>⏎</kbd> 存为高亮项 · <kbd>esc</kbd> 取消";
  body.appendChild(hint);

  const actions = document.createElement("div");
  actions.className = "actions";
  root.querySelector(".card").appendChild(actions);

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

    const currentSummary = () => root.querySelector("textarea")?.value.trim() || "";

    for (const [kind, label, key] of KINDS) {
      const b = document.createElement("button");
      b.textContent = label;
      // The last-used kind is pre-selected, so a repeat save is one keystroke.
      if (kind === defaultKind) b.className = "primary";
      b.addEventListener("click", () =>
        finish({ action: "save", kind, summary: currentSummary() }),
      );
      actions.appendChild(b);
    }

    const cancel = document.createElement("button");
    cancel.className = "ghost";
    cancel.textContent = "取消";
    cancel.addEventListener("click", () => finish({ action: "cancel" }));
    actions.appendChild(cancel);

    const onKey = (e) => {
      // Capture phase, and don't act while the user is editing the summary —
      // typing "1" in the textarea must not save.
      const editing = root.activeElement?.tagName === "TEXTAREA";
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        return finish({ action: "cancel" });
      }
      if (editing && e.key !== "Enter") return;
      if (e.key === "Enter") {
        e.preventDefault();
        e.stopPropagation();
        return finish({
          action: "save",
          kind: defaultKind,
          summary: currentSummary(),
        });
      }
      const hit = KINDS.find(([, , key]) => key === e.key);
      if (hit) {
        e.preventDefault();
        e.stopPropagation();
        finish({ action: "save", kind: hit[0], summary: currentSummary() });
      }
    };
    document.addEventListener("keydown", onKey, true);
  });
}
