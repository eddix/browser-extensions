const DEFAULT_API_URL = 'http://localhost:8787/api/links';

document.addEventListener('DOMContentLoaded', async () => {
  const apiUrlInput = document.getElementById('apiUrl');
  const saveBtn = document.getElementById('save');
  const testBtn = document.getElementById('test');
  const statusDiv = document.getElementById('status');

  async function loadSettings() {
    const result = await chrome.storage.sync.get('apiUrl');
    apiUrlInput.value = result.apiUrl || DEFAULT_API_URL;
  }

  function showStatus(message, isError = false) {
    statusDiv.textContent = message;
    statusDiv.className = isError ? 'status error' : 'status success';
    setTimeout(() => {
      statusDiv.className = 'status';
    }, 4000);
  }

  async function getHealthUrl(apiUrl) {
    try {
      const url = new URL(apiUrl);
      url.pathname = '/api/health';
      return url.toString();
    } catch {
      const base = apiUrl.replace(/\/api\/links\/?$/, '');
      return base + '/api/health';
    }
  }

  async function testConnection() {
    const apiUrl = apiUrlInput.value.trim();
    if (!apiUrl) {
      showStatus('Please enter an API URL', true);
      return;
    }

    try {
      const healthUrl = await getHealthUrl(apiUrl);
      const response = await fetch(healthUrl);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      const data = await response.json();
      if (data.status === 'ok') {
        showStatus('✓ Connection successful!');
      } else {
        showStatus('Unexpected response from server', true);
      }
    } catch (err) {
      showStatus('Connection failed: ' + err.message, true);
    }
  }

  saveBtn.addEventListener('click', async () => {
    const apiUrl = apiUrlInput.value.trim();
    if (!apiUrl) {
      showStatus('Please enter an API URL', true);
      return;
    }

    try {
      await chrome.storage.sync.set({ apiUrl });
      showStatus('✓ Settings saved!');
    } catch (err) {
      showStatus('Failed to save settings: ' + err.message, true);
    }
  });

  testBtn.addEventListener('click', testConnection);

  await loadSettings();
});
