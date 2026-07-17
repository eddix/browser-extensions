// hedra popup — 预设管理 + declarativeNetRequest 规则生成，全部逻辑都在这里。
//
// 数据模型（chrome.storage.local）：
//   masterEnabled: boolean
//   presets: [{ id, name, enabled,
//               domains: [{ host, enabled }]（空数组 = 所有网站；全部未勾选 = 整组不生效）,
//               rules: [{ side: "request"|"response", op: "set"|"remove", header, value }] }]
//
// 优先级语义：最具体的域名生效（DNR priority = 域名深度 × 1000 + 列表顺序兜底）。

"use strict";

// webtransport/webbundle 等新类型从略，避免旧内核上 updateDynamicRules 整体失败。
const RESOURCE_TYPES = [
  "main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
  "xmlhttprequest", "ping", "csp_report", "media", "websocket", "other",
];

let state = { masterEnabled: true, presets: [] };
let editing = null;     // 编辑中的 draft（新建或已有预设的深拷贝）
let expandedId = null;  // 展开冲突详情的预设 id

// ---------- 存储与 DNR ----------

async function persist() {
  await chrome.storage.local.set(state);
}

function activeCount() {
  return state.masterEnabled ? state.presets.filter((p) => p.enabled).length : 0;
}

function domainDepth(domain) {
  return domain.split(".").length;
}

function buildDnrRules() {
  const rules = [];
  if (!state.masterEnabled) return rules;
  const n = state.presets.length;
  state.presets.forEach((preset, idx) => {
    if (!preset.enabled || !preset.rules.length) return;
    const requestHeaders = preset.rules
      .filter((r) => r.side === "request")
      .map(toHeaderInfo);
    const responseHeaders = preset.rules
      .filter((r) => r.side === "response")
      .map(toHeaderInfo);
    // 同一预设按域名深度拆规则，深度进 priority 实现「最具体域名生效」。
    // 注意：有域名但全部未勾选 ≠ 所有网站，而是整组不生效。
    const hosts = preset.domains.filter((d) => d.enabled).map((d) => d.host);
    if (preset.domains.length && !hosts.length) return;
    const byDepth = new Map();
    if (!preset.domains.length) byDepth.set(0, null);
    for (const h of hosts) {
      const dep = domainDepth(h);
      if (!byDepth.has(dep)) byDepth.set(dep, []);
      byDepth.get(dep).push(h);
    }
    for (const [depth, domains] of byDepth) {
      const action = { type: "modifyHeaders" };
      if (requestHeaders.length) action.requestHeaders = requestHeaders;
      if (responseHeaders.length) action.responseHeaders = responseHeaders;
      const condition = { resourceTypes: RESOURCE_TYPES };
      if (domains) condition.requestDomains = domains;
      rules.push({
        id: rules.length + 1,
        priority: depth * 1000 + (n - idx),
        action,
        condition,
      });
    }
  });
  return rules;
}

function toHeaderInfo(rule) {
  return rule.op === "set"
    ? { header: rule.header, operation: "set", value: rule.value }
    : { header: rule.header, operation: "remove" };
}

async function applyRules() {
  try {
    const existing = await chrome.declarativeNetRequest.getDynamicRules();
    await chrome.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: existing.map((r) => r.id),
      addRules: buildDnrRules(),
    });
    const n = activeCount();
    chrome.action.setBadgeText({ text: n ? String(n) : "" });
    chrome.action.setBadgeBackgroundColor({ color: "#1f883d" });
  } catch (e) {
    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#cf222e" });
    toast("规则应用失败：" + e.message, true);
  }
}

// ---------- 冲突检测 ----------

// 两个域名（null = 所有网站）的关系："equal" | "a"（a 更具体）| "b" | null（不相交）
function domainRelation(a, b) {
  if (a === b) return "equal";
  if (a === null) return "b";
  if (b === null) return "a";
  if (a.endsWith("." + b)) return "a";
  if (b.endsWith("." + a)) return "b";
  return null;
}

function fmtDomain(d) {
  return d === null ? "所有网站" : d;
}

// 返回 Map<presetId, { level: "warning"|"info", items: string[] }>
function computeConflicts() {
  const marks = new Map();
  const add = (preset, level, text) => {
    let m = marks.get(preset.id);
    if (!m) { m = { level, items: [] }; marks.set(preset.id, m); }
    if (level === "warning") m.level = "warning";
    if (!m.items.includes(text)) m.items.push(text);
  };
  const enabled = state.presets.filter((p) => p.enabled);
  for (let i = 0; i < enabled.length; i++) {
    for (let j = i + 1; j < enabled.length; j++) {
      const a = enabled[i], b = enabled[j];
      for (const ra of a.rules) {
        for (const rb of b.rules) {
          if (ra.side !== rb.side) continue;
          if (ra.header.toLowerCase() !== rb.header.toLowerCase()) continue;
          if (ra.op === "remove" && rb.op === "remove") continue; // 结果相同，不算冲突
          const sideCn = ra.side === "request" ? "请求头" : "响应头";
          const domsA = a.domains.length
            ? a.domains.filter((d) => d.enabled).map((d) => d.host)
            : [null];
          const domsB = b.domains.length
            ? b.domains.filter((d) => d.enabled).map((d) => d.host)
            : [null];
          for (const da of domsA) {
            for (const db of domsB) {
              const rel = domainRelation(da, db);
              if (!rel) continue;
              if (rel === "equal") {
                const winner =
                  state.presets.indexOf(a) <= state.presets.indexOf(b) ? a : b;
                const text = (other) =>
                  `与「${other.name}」在 ${fmtDomain(da)} 的${sideCn} ${ra.header} 冲突，` +
                  `当前「${winner.name}」生效（列表靠上）`;
                add(a, "warning", text(b));
                add(b, "warning", text(a));
              } else {
                const winner = rel === "a" ? a : b;
                const loser = winner === a ? b : a;
                const scope = fmtDomain(rel === "a" ? da : db);
                add(winner, "info",
                  `在 ${scope} 覆盖「${loser.name}」的${sideCn} ${ra.header}（域名更具体）`);
                add(loser, "info",
                  `${sideCn} ${ra.header} 在 ${scope} 被「${winner.name}」覆盖（对方域名更具体）`);
              }
            }
          }
        }
      }
    }
  }
  return marks;
}

// 「完全对等」预设（域名集相同 + 改同一批 header）互斥成单选组，如多条 PPE 泳道。
// 对等判定用全部域名（忽略勾选状态）：临时勾掉几个域名不应破坏泳道单选。
function presetKey(p) {
  const doms = p.domains.map((d) => d.host).sort().join(",");
  const hdrs = [...new Set(p.rules.map((r) => r.side + ":" + r.header.toLowerCase()))]
    .sort()
    .join(",");
  return doms + "|" + hdrs;
}

// preset 刚被启用/保存后调用：停用与其完全对等的其他预设，返回被停用的名字。
function enforceExclusive(preset) {
  if (!preset.enabled || !preset.rules.length) return [];
  const key = presetKey(preset);
  const disabled = [];
  for (const q of state.presets) {
    if (q.id !== preset.id && q.enabled && q.rules.length && presetKey(q) === key) {
      q.enabled = false;
      disabled.push(q.name);
    }
  }
  return disabled;
}

// ---------- 渲染 ----------

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") node.className = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else if (v !== undefined) node[k] = v;
  }
  node.append(...children.filter((c) => c !== null && c !== undefined));
  return node;
}

function render() {
  const app = document.getElementById("app");
  app.textContent = "";
  document.getElementById("master").checked = state.masterEnabled;
  document.getElementById("footer").style.display = editing ? "none" : "";
  app.append(editing ? renderEditor() : renderList());
}

function renderList() {
  const box = el("div");
  if (!state.presets.length) {
    box.append(el("div", { class: "empty" }, "还没有预设。点「新建预设」开始。"));
    return box;
  }
  const marks = computeConflicts();
  for (const preset of state.presets) {
    const mark = marks.get(preset.id);
    let domText = "所有网站";
    if (preset.domains.length) {
      const on = preset.domains.filter((d) => d.enabled);
      domText = on.length ? on.map((d) => d.host).join(", ") : "域名全部未勾选";
      if (on.length < preset.domains.length) {
        domText += `（${on.length}/${preset.domains.length}）`;
      }
    }
    const sub = [domText, `${preset.rules.length} 条规则`].join(" · ");

    const row = el("div", { class: "preset" + (preset.enabled ? "" : " off") },
      el("input", {
        type: "checkbox",
        checked: preset.enabled,
        onchange: (e) => togglePreset(preset, e.target.checked),
      }),
      el("div", { class: "meta" },
        el("div", { class: "name" }, preset.name),
        el("div", { class: "sub", title: sub }, sub),
      ),
      mark
        ? el("button", {
            class: "mark " + mark.level,
            title: "查看冲突详情",
            onclick: () => {
              expandedId = expandedId === preset.id ? null : preset.id;
              render();
            },
          }, mark.level === "warning" ? "⚠ 冲突" : "ℹ 覆盖")
        : null,
      el("button", { class: "link", onclick: () => duplicatePreset(preset) }, "复制"),
      el("button", { class: "link", onclick: () => startEdit(preset) }, "编辑"),
    );
    box.append(row);
    if (mark && expandedId === preset.id) {
      box.append(el("div", { class: "details" },
        ...mark.items.map((t) => el("div", { class: mark.level }, t)),
      ));
    }
  }
  return box;
}

function renderEditor() {
  const d = editing;
  const form = el("div", { class: "editor" });

  form.append(
    el("label", { class: "field" },
      el("b", {}, "名称"),
      el("input", {
        type: "text",
        value: d.name,
        placeholder: "例如：PPE 泳道 A",
        oninput: (e) => { d.name = e.target.value; },
      }),
    ),
  );

  const domainsBox = el("div", { class: "field" }, el("b", {}, "域名"));
  d.domains.forEach((dom, i) => domainsBox.append(renderDomainRow(dom, i)));
  domainsBox.append(
    el("button", {
      onclick: () => {
        d.domains.push({ host: "", enabled: true });
        render();
      },
    }, "＋ 添加域名"),
    el("div", { class: "hint" }, "自动含子域；勾选 = 生效，可临时勾掉几个；一个不留 = 所有网站"),
  );
  form.append(domainsBox);

  const rulesBox = el("div", { class: "field" }, el("b", {}, "Header 规则"));
  d.rules.forEach((rule, i) => rulesBox.append(renderRuleRow(rule, i)));
  rulesBox.append(el("button", {
    onclick: () => {
      d.rules.push({ side: "request", op: "set", header: "", value: "" });
      render();
    },
  }, "＋ 添加规则"));
  form.append(rulesBox);

  const actions = el("div", { class: "actions" },
    el("button", { class: "primary", onclick: saveDraft }, "保存"),
    el("button", { onclick: () => { editing = null; render(); } }, "取消"),
    el("span", { class: "spacer" }),
  );
  if (state.presets.some((p) => p.id === d.id)) {
    actions.append(el("button", {
      class: "danger",
      onclick: (e) => {
        if (!d._confirmDelete) {
          d._confirmDelete = true;
          e.target.textContent = "确认删除？";
          return;
        }
        state.presets = state.presets.filter((p) => p.id !== d.id);
        editing = null;
        persist(); applyRules(); render();
      },
    }, "删除预设"));
  }
  form.append(actions);
  return form;
}

function renderDomainRow(dom, index) {
  return el("div", { class: "domain-row" },
    el("input", {
      type: "checkbox",
      title: "是否生效",
      checked: dom.enabled,
      onchange: (e) => { dom.enabled = e.target.checked; },
    }),
    el("input", {
      type: "text",
      class: "dhost",
      value: dom.host,
      placeholder: "example.com",
      oninput: (e) => { dom.host = e.target.value; },
    }),
    el("button", {
      class: "rm",
      title: "删除这个域名",
      onclick: () => { editing.domains.splice(index, 1); render(); },
    }, "×"),
  );
}

function renderRuleRow(rule, index) {
  const sideSel = el("select", {
    class: "side",
    onchange: (e) => { rule.side = e.target.value; },
  },
    el("option", { value: "request" }, "请求头"),
    el("option", { value: "response" }, "响应头"),
  );
  sideSel.value = rule.side;

  const valueInput = el("input", {
    type: "text",
    class: "hvalue",
    value: rule.value,
    placeholder: "值",
    hidden: rule.op === "remove",
    oninput: (e) => { rule.value = e.target.value; },
  });

  const opSel = el("select", {
    class: "op",
    onchange: (e) => {
      rule.op = e.target.value;
      valueInput.hidden = rule.op === "remove";
    },
  },
    el("option", { value: "set" }, "set"),
    el("option", { value: "remove" }, "remove"),
  );
  opSel.value = rule.op;

  // valueInput 放行尾 + width:100%，flex-wrap 会把它折到第二行独占整行
  return el("div", { class: "rule-row" },
    sideSel,
    opSel,
    el("input", {
      type: "text",
      class: "hname",
      value: rule.header,
      placeholder: "Header 名",
      oninput: (e) => { rule.header = e.target.value; },
    }),
    el("button", {
      class: "rm",
      title: "删除这条规则",
      onclick: () => { editing.rules.splice(index, 1); render(); },
    }, "×"),
    valueInput,
  );
}

// ---------- 操作 ----------

function genId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}

function startEdit(preset) {
  editing = {
    id: preset.id,
    name: preset.name,
    enabled: preset.enabled,
    domains: preset.domains.map((d) => ({ ...d })),
    rules: preset.rules.map((r) => ({ ...r })),
  };
  render();
}

function startNew() {
  editing = {
    id: genId(),
    name: "",
    enabled: true,
    domains: [{ host: "", enabled: true }],
    rules: [{ side: "request", op: "set", header: "", value: "" }],
  };
  render();
}

// 复制预设 → 直接进入编辑。副本默认停用，避免一保存就触发互斥、把原组挤掉。
function duplicatePreset(preset) {
  editing = {
    id: genId(),
    name: preset.name + " 副本",
    enabled: false,
    domains: preset.domains.map((d) => ({ ...d })),
    rules: preset.rules.map((r) => ({ ...r })),
  };
  render();
}

function normalizeDomain(s) {
  let d = s.trim().toLowerCase();
  d = d.replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  d = d.replace(/^\*\./, "").replace(/^\./, "").replace(/:\d+$/, "");
  if (!d || !/^[a-z0-9.-]+$/.test(d)) return "";
  return d;
}

function dedupeDomains(list) {
  const seen = new Set();
  return list.filter((d) => !seen.has(d.host) && seen.add(d.host));
}

function saveDraft() {
  const d = editing;
  const preset = {
    id: d.id,
    name: d.name.trim() || "未命名",
    enabled: d.enabled,
    domains: dedupeDomains(
      d.domains
        .map((x) => ({ host: normalizeDomain(x.host), enabled: x.enabled }))
        .filter((x) => x.host),
    ),
    rules: d.rules
      .map((r) => ({ ...r, header: r.header.trim() }))
      .filter((r) => r.header),
  };
  const i = state.presets.findIndex((p) => p.id === preset.id);
  if (i >= 0) state.presets[i] = preset;
  else state.presets.push(preset);

  const disabled = enforceExclusive(preset);
  editing = null;
  persist(); applyRules(); render();
  if (disabled.length) toast("已自动停用：" + disabled.join("、"));
}

function togglePreset(preset, checked) {
  preset.enabled = checked;
  const disabled = checked ? enforceExclusive(preset) : [];
  persist(); applyRules(); render();
  if (disabled.length) toast("已自动停用：" + disabled.join("、"));
}

// ---------- 导入 / 导出 ----------

function exportPresets() {
  const blob = new Blob(
    [JSON.stringify({ presets: state.presets }, null, 2)],
    { type: "application/json" },
  );
  const url = URL.createObjectURL(blob);
  const a = el("a", { href: url, download: "hedra-presets.json" });
  a.click();
  URL.revokeObjectURL(url);
}

function sanitizeImported(raw) {
  if (!raw || typeof raw !== "object") return null;
  const rules = Array.isArray(raw.rules)
    ? raw.rules
        .map((r) => ({
          side: r && r.side === "response" ? "response" : "request",
          op: r && r.op === "remove" ? "remove" : "set",
          header: String((r && r.header) || "").trim(),
          value: String((r && r.value) ?? ""),
        }))
        .filter((r) => r.header)
    : [];
  // 兼容两种形态：旧版字符串数组、新版 { host, enabled } 数组
  const domains = Array.isArray(raw.domains)
    ? dedupeDomains(
        raw.domains
          .map((x) =>
            typeof x === "string"
              ? { host: normalizeDomain(x), enabled: true }
              : {
                  host: normalizeDomain(String((x && x.host) || "")),
                  enabled: !x || x.enabled !== false,
                },
          )
          .filter((x) => x.host),
      )
    : [];
  // 导入的预设一律先停用，避免一导入就改流量。
  return { id: genId(), name: String(raw.name || "未命名"), domains, rules, enabled: false };
}

async function importPresets(file) {
  try {
    const data = JSON.parse(await file.text());
    const list = Array.isArray(data) ? data : data.presets;
    if (!Array.isArray(list)) throw new Error("文件里找不到 presets 数组");
    const imported = list.map(sanitizeImported).filter(Boolean);
    state.presets.push(...imported);
    await persist(); await applyRules(); render();
    toast(`已导入 ${imported.length} 组预设（默认停用）`);
  } catch (e) {
    toast("导入失败：" + e.message, true);
  }
}

// ---------- 杂项 ----------

let toastTimer = null;
function toast(text, isError = false) {
  const node = document.getElementById("toast");
  node.textContent = text;
  node.className = isError ? "error" : "";
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, isError ? 4000 : 2500);
}

async function init() {
  const data = await chrome.storage.local.get({ masterEnabled: true, presets: [] });
  state = data;

  // 旧版 domains 是字符串数组，迁移为 { host, enabled }
  let migrated = false;
  for (const p of state.presets) {
    p.domains = (p.domains || []).map((d) => {
      if (typeof d === "string") {
        migrated = true;
        return { host: d, enabled: true };
      }
      return d;
    });
  }
  if (migrated) await persist();

  document.getElementById("master").addEventListener("change", (e) => {
    state.masterEnabled = e.target.checked;
    persist(); applyRules(); render();
  });
  document.getElementById("btn-new").addEventListener("click", startNew);
  document.getElementById("btn-export").addEventListener("click", exportPresets);
  document.getElementById("btn-import").addEventListener("click", () => {
    document.getElementById("file").click();
  });
  document.getElementById("file").addEventListener("change", (e) => {
    if (e.target.files[0]) importPresets(e.target.files[0]);
    e.target.value = "";
  });

  render();
  await applyRules(); // 每次打开都全量重建，storage 与 DNR/badge 保持一致
}

init();
