function getDomain(url) {
  try {
    const u = new URL(url);
    if (u.protocol === 'chrome:' || u.protocol === 'chrome-extension:') return '浏览器页面';
    if (u.protocol === 'about:' || u.protocol === 'arc:') return '新标签页';
    return u.hostname.replace(/^www\./, '') || '其他';
  } catch {
    return '其他';
  }
}

function groupByDomain(tabs) {
  const groups = new Map();
  for (const tab of tabs) {
    const domain = getDomain(tab.url || tab.pendingUrl || '');
    if (!groups.has(domain)) groups.set(domain, []);
    groups.get(domain).push(tab);
  }
  for (const [, list] of groups) {
    list.sort((a, b) =>
      (a.title || '').localeCompare(b.title || '', 'zh', { sensitivity: 'base' })
    );
  }
  return groups;
}

function sortedDomains(groups) {
  return [...groups.keys()].sort((a, b) => a.localeCompare(b, 'zh'));
}

async function fetchAllTabs() {
  // 全 Arc Space（所有 window）的全部 tab
  const tabs = await chrome.tabs.query({});
  const windows = await chrome.windows.getAll();
  const winIndex = new Map();
  windows.forEach((w, i) => winIndex.set(w.id, i + 1));
  return { tabs, winIndex, currentWindowId: (await chrome.windows.getCurrent()).id };
}

function matches(tab, q) {
  if (!q) return true;
  const hay = (
    (tab.title || '') + ' ' +
    (tab.url || '') + ' ' +
    getDomain(tab.url || '')
  ).toLowerCase();
  return hay.includes(q);
}

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2).toLowerCase(), v);
    else node.setAttribute(k, v);
  }
  for (const c of children) if (c) node.appendChild(c);
  return node;
}

function render({ tabs, winIndex, currentWindowId }) {
  const list = document.getElementById('list');
  const meta = document.getElementById('meta');
  const q = document.getElementById('search').value.trim().toLowerCase();

  const filtered = tabs.filter(t => matches(t, q));
  const groups = groupByDomain(filtered);
  const domains = sortedDomains(groups);

  meta.textContent = `${filtered.length} 标签 · ${groups.size} 域名 · ${winIndex.size} Space`;

  list.replaceChildren();

  if (filtered.length === 0) {
    list.appendChild(el('div', { class: 'empty', text: q ? '无匹配。' : '没有标签。' }));
    return;
  }

  const showWindowBadge = winIndex.size > 1;

  for (const domain of domains) {
    const inGroup = groups.get(domain);
    const header = el('div', { class: 'group-header' });
    header.appendChild(document.createTextNode(domain));
    header.appendChild(el('span', { class: 'count', text: ` · ${inGroup.length}` }));
    list.appendChild(header);

    for (const tab of inGroup) {
      const row = el('button', {
        class: 'tab-row' + (tab.active && tab.windowId === currentWindowId ? ' active' : ''),
        type: 'button',
        title: tab.url || '',
        onclick: () => activateTab(tab),
      });

      // favicon
      if (tab.favIconUrl) {
        const img = el('img', { class: 'favicon', src: tab.favIconUrl, alt: '' });
        img.addEventListener('error', () => {
          img.replaceWith(el('span', { class: 'favicon-fallback' }));
        });
        row.appendChild(img);
      } else {
        row.appendChild(el('span', { class: 'favicon-fallback' }));
      }

      const textWrap = el('div', { class: 'tab-text' });
      textWrap.appendChild(el('div', { class: 'tab-title', text: tab.title || '(无标题)' }));
      const metaLine = (() => {
        try {
          const u = new URL(tab.url || '');
          return u.pathname && u.pathname !== '/' ? u.hostname + u.pathname : u.hostname;
        } catch { return tab.url || ''; }
      })();
      textWrap.appendChild(el('div', { class: 'tab-meta', text: metaLine }));
      row.appendChild(textWrap);

      if (tab.pinned) row.appendChild(el('span', { class: 'pin', text: '📌' }));
      if (showWindowBadge) {
        row.appendChild(el('span', { class: 'badge', text: 'S' + winIndex.get(tab.windowId) }));
      }

      list.appendChild(row);
    }
  }
}

async function activateTab(tab) {
  try {
    await chrome.windows.update(tab.windowId, { focused: true });
    await chrome.tabs.update(tab.id, { active: true });
    window.close();
  } catch (err) {
    console.error('切换失败', err);
    showError('切换失败：' + (err && err.message ? err.message : String(err)));
  }
}

function showError(msg) {
  const list = document.getElementById('list');
  list.replaceChildren(el('div', { class: 'err', text: msg }));
}

let state = null;

async function refresh() {
  try {
    state = await fetchAllTabs();
    render(state);
  } catch (err) {
    console.error(err);
    showError('加载失败：' + (err && err.message ? err.message : String(err)));
  }
}

document.addEventListener('DOMContentLoaded', () => {
  const search = document.getElementById('search');
  search.addEventListener('input', () => {
    if (state) render(state);
  });
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      // 回车切到当前过滤结果的第一行
      const first = document.querySelector('.tab-row');
      if (first) first.click();
    } else if (e.key === 'Escape') {
      if (search.value) {
        search.value = '';
        if (state) render(state);
      } else {
        window.close();
      }
    }
  });
  refresh();
});
