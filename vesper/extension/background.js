const DEFAULT_API_URL = 'http://localhost:8787/api/links';

let currentTabId = null;

async function getApiUrl() {
  const result = await chrome.storage.sync.get('apiUrl');
  return result.apiUrl || DEFAULT_API_URL;
}

async function getCheckUrl() {
  const apiUrl = await getApiUrl();
  try {
    const url = new URL(apiUrl);
    url.pathname = '/api/check-url';
    return url.toString();
  } catch {
    const base = apiUrl.replace(/\/api\/links\/?$/, '');
    return base + '/api/check-url';
  }
}

async function checkUrlExists(url) {
  if (!url || !url.startsWith('http')) {
    return { exists: false, error: false };
  }

  try {
    const checkUrl = await getCheckUrl();
    const response = await fetch(`${checkUrl}?url=${encodeURIComponent(url)}`);
    const data = await response.json();
    return { exists: data.exists, error: false };
  } catch (e) {
    console.error('Failed to check URL:', e);
    return { exists: false, error: true };
  }
}

async function updateIconForTab(tab) {
  if (!tab || !tab.url) {
    setIcon('neutral');
    return;
  }

  const result = await checkUrlExists(tab.url);
  if (result.error) {
    setIcon('error');
  } else {
    setIcon(result.exists ? 'saved' : 'unsaved');
  }
}

function setIcon(state) {
  let suffix = '';
  if (state === 'saved') {
    suffix = '-green';
  } else if (state === 'error') {
    suffix = '-red';
  }

  chrome.action.setIcon({
    path: {
      16: `icons/icon16${suffix}.png`,
      48: `icons/icon48${suffix}.png`,
      128: `icons/icon128${suffix}.png`
    }
  });
}

function setIconNeutral() {
  setIcon('neutral');
}

async function sendLinks(links) {
  const apiUrl = await getApiUrl();

  try {
    const response = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(links),
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    return await response.json();
  } catch (error) {
    console.error('Failed to send links:', error);
    throw error;
  }
}

function isValidUrl(url) {
  if (!url) return false;
  return url.startsWith('http://') || url.startsWith('https://');
}

function createLinkPayload(tab, mode = 'single') {
  return {
    title: tab.title || '',
    url: tab.url,
    created_at: new Date().toISOString(),
    source: 'chrome',
    mode: mode,
    tags: [],
  };
}

async function showToast(message, type = 'success') {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.id) {
    return;
  }

  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: injectToast,
      args: [message, type],
    });
  } catch (e) {
    console.error('Failed to inject toast:', e);
  }
}

function injectToast(message, type) {
  const existing = document.getElementById('vesper-toast');
  if (existing) {
    existing.remove();
  }

  const toast = document.createElement('div');
  toast.id = 'vesper-toast';

  // Catppuccin Latte colors
  let bgColor = '#a6da95';
  let textColor = '#4c4f69';
  if (type === 'warning') {
    bgColor = '#eed49f';
    textColor = '#4c4f69';
  } else if (type === 'error') {
    bgColor = '#e78284';
    textColor = '#4c4f69';
  }

  toast.style.cssText = `
    position: fixed !important;
    top: 20px !important;
    right: 20px !important;
    background: ${bgColor} !important;
    color: ${textColor} !important;
    padding: 14px 20px !important;
    border-radius: 12px !important;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif !important;
    font-size: 14px !important;
    font-weight: 500 !important;
    z-index: 2147483647 !important;
    box-shadow: 0 2px 8px rgba(0,0,0,0.08) !important;
    animation: vesper-fade-in 0.3s ease-out !important;
    line-height: 1.5 !important;
    max-width: 400px !important;
    word-wrap: break-word !important;
    white-space: pre-line !important;
    border: 1px solid rgba(0,0,0,0.05) !important;
  `;

  const style = document.createElement('style');
  style.textContent = `
    @keyframes vesper-fade-in {
      from { opacity: 0; transform: translateY(-10px); }
      to { opacity: 1; transform: translateY(0); }
    }
    @keyframes vesper-fade-out {
      from { opacity: 1; transform: translateY(0); }
      to { opacity: 0; transform: translateY(-10px); }
    }
  `;
  document.head.appendChild(style);

  toast.textContent = message;
  document.body.appendChild(toast);

  setTimeout(() => {
    toast.style.animation = 'vesper-fade-out 0.3s ease-out forwards';
    setTimeout(() => {
      toast.remove();
      style.remove();
    }, 300);
  }, 4000);
}

async function sendCurrentTab() {
  const [tab] = await chrome.tabs.query({
    active: true,
    currentWindow: true,
  });

  if (!tab || !isValidUrl(tab.url)) {
    showError('Cannot save this URL');
    return;
  }

  try {
    const result = await sendLinks(createLinkPayload(tab, 'single'));
    showSaveResult(result);
    setIcon('saved');
  } catch (error) {
    showError('Failed to send to Vesper');
    setIcon('error');
  }
}

async function sendWindowTabs() {
  const tabs = await chrome.tabs.query({
    currentWindow: true,
  });

  const validTabs = tabs.filter(tab => isValidUrl(tab.url));

  if (validTabs.length === 0) {
    showError('No valid tabs to save');
    return;
  }

  const payload = validTabs.map(tab => createLinkPayload(tab, 'window'));

  try {
    const result = await sendLinks(payload);
    showSaveResult(result);
    const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (activeTab) {
      updateIconForTab(activeTab);
    }
  } catch (error) {
    showError('Failed to send to Vesper');
    setIcon('error');
  }
}

function showSaveResult(result) {
  let message = '';
  if (result.saved > 0) {
    message += `Saved ${result.saved} link(s)`;
  }
  if (result.duplicates && result.duplicates.length > 0) {
    if (message) message += '\n';
    message += `${result.duplicates.length} duplicate(s):`;
    for (const dup of result.duplicates) {
      message += `\n  • ${dup.exists_in}`;
    }
  }
  if (result.errors && result.errors.length > 0) {
    if (message) message += '\n';
    message += `${result.errors.length} error(s)`;
  }

  const hasDuplicates = result.duplicates && result.duplicates.length > 0;
  const hasErrors = result.errors && result.errors.length > 0;

  if (hasErrors) {
    showError(message || 'No links saved');
  } else if (hasDuplicates) {
    showWarning(message || 'No links saved');
  } else if (result.saved > 0) {
    showSuccess(message || 'No links saved');
  } else {
    showError('No links saved');
  }
}

function showSuccess(message) {
  chrome.action.setBadgeText({ text: '✓' });
  chrome.action.setBadgeBackgroundColor({ color: '#a6da95' });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' });
  }, 2000);

  showToast(message, 'success');
}

function showWarning(message) {
  chrome.action.setBadgeText({ text: '!' });
  chrome.action.setBadgeBackgroundColor({ color: '#eed49f' });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' });
  }, 2000);

  showToast(message, 'warning');
}

function showError(message) {
  chrome.action.setBadgeText({ text: '✗' });
  chrome.action.setBadgeBackgroundColor({ color: '#e78284' });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' });
  }, 2000);

  showToast(message, 'error');
}

chrome.action.onClicked.addListener(async (tab) => {
  await sendCurrentTab();
});

chrome.tabs.onActivated.addListener(async (activeInfo) => {
  currentTabId = activeInfo.tabId;
  const tab = await chrome.tabs.get(activeInfo.tabId);
  updateIconForTab(tab);
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.url || changeInfo.status === 'complete') {
    const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (activeTab && activeTab.id === tabId) {
      updateIconForTab(tab);
    }
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (activeTab) {
    updateIconForTab(activeTab);
  }
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: 'send-link-to-obsidian',
    title: 'Send to Obsidian',
    contexts: ['page', 'link', 'selection'],
  });

  chrome.contextMenus.create({
    id: 'send-window-tabs',
    title: 'Send all tabs in window',
    contexts: ['action'],
  });

  chrome.contextMenus.create({
    id: 'open-settings',
    title: 'Settings',
    contexts: ['action'],
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === 'send-link-to-obsidian') {
    const url = info.linkUrl || info.pageUrl || tab.url;
    const title = info.linkText || tab.title;

    if (!isValidUrl(url)) {
      showError('Cannot save this URL');
      return;
    }

    try {
      const payload = {
        title: title || '',
        url: url,
        created_at: new Date().toISOString(),
        source: 'chrome',
        mode: 'single',
        tags: [],
      };
      const result = await sendLinks(payload);
      showSaveResult(result);
      if (tab && tab.url === url) {
        setIcon('saved');
      }
    } catch (error) {
      showError('Failed to send to Vesper');
    }
  } else if (info.menuItemId === 'send-window-tabs') {
    await sendWindowTabs();
  } else if (info.menuItemId === 'open-settings') {
    chrome.runtime.openOptionsPage();
  }
});

chrome.runtime.onStartup.addListener(async () => {
  const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (activeTab) {
    updateIconForTab(activeTab);
  }
});
