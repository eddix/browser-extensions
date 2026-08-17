// nodia extension — sends the current page to the nodia app, which files it
// into the Obsidian vault.
//
// Two rules this file must keep (see ../README.md):
//   1. Page text is extracted ONLY when you explicitly save. There is no
//      background scraping, no history sweep, no crawling of open tabs.
//   2. Every request carries the pairing token. Without it the local port
//      would be readable by script on any page you visit.

const DEFAULT_API_BASE = 'http://127.0.0.1:8787';

/** Longest page extract we ship for summarizing. Enough for a summary, small
 *  enough to stay a single quick request. */
const MAX_CONTENT_CHARS = 8000;

async function getConfig() {
  const { apiBase, token } = await chrome.storage.local.get(['apiBase', 'token']);
  return { apiBase: apiBase || DEFAULT_API_BASE, token: token || '' };
}

async function api(path, { method = 'GET', body } = {}) {
  const { apiBase, token } = await getConfig();
  const response = await fetch(`${apiBase}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 401) {
    throw new Error('令牌无效 — 请在设置里粘贴 nodia 的配对令牌');
  }
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  return response.json();
}

// ---------- 图标状态 ----------

async function checkUrlExists(url) {
  if (!url || !url.startsWith('http')) return { exists: false, error: false };
  try {
    const data = await api(`/api/check-url?url=${encodeURIComponent(url)}`);
    return { exists: data.exists, error: false };
  } catch (e) {
    return { exists: false, error: true };
  }
}

async function updateIconForTab(tab) {
  if (!tab || !tab.url) return setIcon('neutral');
  const result = await checkUrlExists(tab.url);
  setIcon(result.error ? 'error' : result.exists ? 'saved' : 'unsaved');
}

function setIcon(state) {
  const suffix = state === 'saved' ? '-green' : state === 'error' ? '-red' : '';
  chrome.action.setIcon({
    path: {
      16: `icons/icon16${suffix}.png`,
      48: `icons/icon48${suffix}.png`,
      128: `icons/icon128${suffix}.png`,
    },
  });
}

// ---------- 正文抓取 ----------

/** Runs in the page. Prefers the semantic content container over the whole
 *  body so navigation and footers don't drown the actual text. */
function extractPageText(limit) {
  const pick = () => {
    for (const selector of ['article', 'main', '[role="main"]', '.markdown-body']) {
      const node = document.querySelector(selector);
      if (node && node.innerText && node.innerText.trim().length > 200) return node;
    }
    // Fall back to the densest block of text on the page.
    let best = document.body;
    let bestScore = 0;
    for (const node of document.querySelectorAll('div, section')) {
      const text = node.innerText || '';
      if (text.length < 200 || text.length > 100000) continue;
      const score = text.length / (1 + node.querySelectorAll('a, button, nav').length);
      if (score > bestScore) {
        bestScore = score;
        best = node;
      }
    }
    return best;
  };

  const text = (pick().innerText || '')
    .replace(/[​-‏⁠-⁤﻿]/g, '') // 文档平台标题/正文的零宽水印字符
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  return text.slice(0, limit);
}

async function grabContent(tabId) {
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId },
      func: extractPageText,
      args: [MAX_CONTENT_CHARS],
    });
    return result?.result || '';
  } catch (e) {
    // Restricted pages (chrome://, the web store) simply save without text.
    return '';
  }
}

// ---------- 保存 ----------

function isValidUrl(url) {
  return !!url && (url.startsWith('http://') || url.startsWith('https://'));
}

async function payloadFor(tab, kind, mode = 'single') {
  return {
    title: tab.title || '',
    url: tab.url,
    kind,
    created_at: new Date().toISOString(),
    source: 'arc',
    mode,
    content: mode === 'single' ? await grabContent(tab.id) : '',
  };
}

async function saveCurrentTab(kind) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !isValidUrl(tab.url)) return showError('这个页面不能保存');

  try {
    const result = await sendLinks(await payloadFor(tab, kind));
    showSaveResult(result, kind);
    setIcon('saved');
  } catch (error) {
    showError(error.message || '保存失败');
    setIcon('error');
  }
}

async function saveWindowTabs(kind) {
  const tabs = (await chrome.tabs.query({ currentWindow: true })).filter(t => isValidUrl(t.url));
  if (!tabs.length) return showError('没有可保存的标签页');

  // Bulk saves skip text extraction: injecting into every open tab is exactly
  // the kind of sweeping this extension refuses to do.
  const payload = await Promise.all(tabs.map(t => payloadFor(t, kind, 'window')));
  try {
    showSaveResult(await sendLinks(payload), kind);
    const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (active) updateIconForTab(active);
  } catch (error) {
    showError(error.message || '保存失败');
    setIcon('error');
  }
}

async function sendLinks(links) {
  return api('/api/links', { method: 'POST', body: links });
}

// ---------- 反馈 ----------

const KIND_LABEL = { bookmark: '书签', readlater: '稍后读', todo: '待办' };

function showSaveResult(result, kind) {
  const label = KIND_LABEL[kind] || '';
  let message = '';
  if (result.saved > 0) message += `已存为${label}（${result.saved} 条）`;
  if (result.duplicates?.length) {
    if (message) message += '\n';
    message += `${result.duplicates.length} 条已存在：`;
    for (const dup of result.duplicates) message += `\n  • ${dup.exists_in}`;
  }
  if (result.errors?.length) {
    if (message) message += '\n';
    message += `${result.errors.length} 条失败`;
  }

  if (result.errors?.length) showError(message || '没有保存任何内容');
  else if (result.duplicates?.length) showWarning(message);
  else if (result.saved > 0) showSuccess(message);
  else showError('没有保存任何内容');
}

function flashBadge(text, color) {
  chrome.action.setBadgeText({ text });
  chrome.action.setBadgeBackgroundColor({ color });
  setTimeout(() => chrome.action.setBadgeText({ text: '' }), 2000);
}

function showSuccess(message) { flashBadge('✓', '#a6da95'); showToast(message, 'success'); }
function showWarning(message) { flashBadge('!', '#eed49f'); showToast(message, 'warning'); }
function showError(message) { flashBadge('✗', '#e78284'); showToast(message, 'error'); }

async function showToast(message, type = 'success') {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: injectToast,
      args: [message, type],
    });
  } catch (e) {
    // Toast is best-effort; the badge already reported the outcome.
  }
}

function injectToast(message, type) {
  document.getElementById('nodia-toast')?.remove();

  const toast = document.createElement('div');
  toast.id = 'nodia-toast';

  let bgColor = '#a6da95';
  if (type === 'warning') bgColor = '#eed49f';
  else if (type === 'error') bgColor = '#e78284';

  toast.style.cssText = `
    position: fixed !important;
    top: 20px !important;
    right: 20px !important;
    background: ${bgColor} !important;
    color: #4c4f69 !important;
    padding: 14px 20px !important;
    border-radius: 12px !important;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif !important;
    font-size: 14px !important;
    font-weight: 500 !important;
    z-index: 2147483647 !important;
    box-shadow: 0 2px 8px rgba(0,0,0,0.08) !important;
    line-height: 1.5 !important;
    max-width: 400px !important;
    word-wrap: break-word !important;
    white-space: pre-line !important;
    border: 1px solid rgba(0,0,0,0.05) !important;
    animation: nodia-fade-in 0.3s ease-out !important;
  `;

  const style = document.createElement('style');
  style.textContent = `
    @keyframes nodia-fade-in {
      from { opacity: 0; transform: translateY(-10px); }
      to { opacity: 1; transform: translateY(0); }
    }
    @keyframes nodia-fade-out {
      from { opacity: 1; transform: translateY(0); }
      to { opacity: 0; transform: translateY(-10px); }
    }
  `;
  document.head.appendChild(style);
  toast.textContent = message;
  document.body.appendChild(toast);

  setTimeout(() => {
    toast.style.animation = 'nodia-fade-out 0.3s ease-out forwards';
    setTimeout(() => { toast.remove(); style.remove(); }, 300);
  }, 4000);
}

// ---------- 事件 ----------

// Clicking the icon stays a single keystroke-free action: save as readlater,
// the biggest and least committal bucket. The other two kinds are one
// right-click away — deliberately, so the common case never asks a question.
chrome.action.onClicked.addListener(() => saveCurrentTab('readlater'));

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  updateIconForTab(await chrome.tabs.get(tabId));
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!changeInfo.url && changeInfo.status !== 'complete') return;
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (active?.id === tabId) updateIconForTab(tab);
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (active) updateIconForTab(active);
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    const items = [
      ['save-readlater', '存为稍后读', ['page', 'link', 'selection']],
      ['save-bookmark', '存为书签', ['page', 'link', 'selection']],
      ['save-todo', '存为待办', ['page', 'link', 'selection']],
      ['save-window', '保存窗口内全部标签（稍后读）', ['action']],
      ['open-settings', '设置…', ['action']],
    ];
    for (const [id, title, contexts] of items) {
      chrome.contextMenus.create({ id, title, contexts });
    }
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const kindByMenu = {
    'save-readlater': 'readlater',
    'save-bookmark': 'bookmark',
    'save-todo': 'todo',
  };

  if (info.menuItemId === 'save-window') return saveWindowTabs('readlater');
  if (info.menuItemId === 'open-settings') return chrome.runtime.openOptionsPage();

  const kind = kindByMenu[info.menuItemId];
  if (!kind) return;

  // A right-click on a link saves that link, not the page it sits on.
  const url = info.linkUrl || info.pageUrl || tab?.url;
  if (!isValidUrl(url)) return showError('这个页面不能保存');

  const isCurrentPage = !info.linkUrl && tab && tab.url === url;
  try {
    const payload = isCurrentPage
      ? await payloadFor(tab, kind)
      : {
          title: info.linkText || tab?.title || '',
          url,
          kind,
          created_at: new Date().toISOString(),
          source: 'arc',
          mode: 'single',
          content: '',
        };
    showSaveResult(await sendLinks(payload), kind);
    if (isCurrentPage) setIcon('saved');
  } catch (error) {
    showError(error.message || '保存失败');
  }
});

chrome.runtime.onStartup.addListener(async () => {
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (active) updateIconForTab(active);
});
