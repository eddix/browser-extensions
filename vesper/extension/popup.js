function showStatus(message, isError = false) {
  const status = document.getElementById('status');
  status.textContent = message;
  status.className = isError ? 'error' : 'success';
  setTimeout(() => {
    status.className = '';
  }, 3000);
}

document.getElementById('sendCurrent').addEventListener('click', async () => {
  try {
    const [tab] = await chrome.tabs.query({
      active: true,
      currentWindow: true,
    });

    if (!tab) {
      showStatus('No active tab', true);
      return;
    }

    const apiUrl = await getApiUrl();
    const payload = createLinkPayload(tab, 'single');
    const result = await sendLinks(apiUrl, payload);

    if (result.success) {
      let msg = `Saved ${result.saved} link`;
      if (result.duplicates?.length) {
        msg += ` (${result.duplicates.length} duplicates)`;
      }
      showStatus(msg);
    } else {
      showStatus(result.error || 'Failed', true);
    }
  } catch (err) {
    showStatus('Failed to send: ' + err.message, true);
  }
});

document.getElementById('sendWindow').addEventListener('click', async () => {
  try {
    const tabs = await chrome.tabs.query({ currentWindow: true });
    const validTabs = tabs.filter(tab =>
      tab.url && (tab.url.startsWith('http://') || tab.url.startsWith('https://'))
    );

    if (validTabs.length === 0) {
      showStatus('No valid tabs to save', true);
      return;
    }

    const apiUrl = await getApiUrl();
    const payload = validTabs.map(tab => createLinkPayload(tab, 'window'));
    const result = await sendLinks(apiUrl, payload);

    if (result.success) {
      let msg = `Saved ${result.saved} links`;
      if (result.duplicates?.length) {
        msg += ` (${result.duplicates.length} duplicates)`;
      }
      showStatus(msg);
    } else {
      showStatus(result.error || 'Failed', true);
    }
  } catch (err) {
    showStatus('Failed to send: ' + err.message, true);
  }
});

document.getElementById('openOptions').addEventListener('click', (e) => {
  e.preventDefault();
  chrome.runtime.openOptionsPage();
});

async function getApiUrl() {
  const result = await chrome.storage.sync.get('apiUrl');
  return result.apiUrl || 'http://localhost:8787/api/links';
}

function createLinkPayload(tab, mode) {
  return {
    title: tab.title || '',
    url: tab.url,
    created_at: new Date().toISOString(),
    source: 'chrome',
    mode: mode,
    tags: [],
  };
}

async function sendLinks(apiUrl, links) {
  const response = await fetch(apiUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(links),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`HTTP ${response.status}: ${text}`);
  }

  return await response.json();
}
