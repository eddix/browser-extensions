// Settings live in storage.local, not storage.sync: the pairing token guards a
// loopback port on this machine and has no business being uploaded to a Google
// account.

const DEFAULT_API_BASE = 'http://127.0.0.1:8787';

document.addEventListener('DOMContentLoaded', async () => {
  const apiBaseInput = document.getElementById('apiBase');
  const tokenInput = document.getElementById('token');
  const statusDiv = document.getElementById('status');

  const stored = await chrome.storage.local.get(['apiBase', 'token']);
  apiBaseInput.value = stored.apiBase || DEFAULT_API_BASE;
  tokenInput.value = stored.token || '';

  function showStatus(message, isError = false) {
    statusDiv.textContent = message;
    statusDiv.className = isError ? 'status error' : 'status success';
  }

  function currentBase() {
    return (apiBaseInput.value.trim() || DEFAULT_API_BASE).replace(/\/+$/, '');
  }

  document.getElementById('save').addEventListener('click', async () => {
    const token = tokenInput.value.trim();
    if (!token) return showStatus('请填写配对令牌，否则 nodia 会拒绝所有请求。', true);
    await chrome.storage.local.set({ apiBase: currentBase(), token });
    showStatus('已保存。');
  });

  document.getElementById('test').addEventListener('click', async () => {
    const token = tokenInput.value.trim();
    try {
      const response = await fetch(`${currentBase()}/api/health`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (response.status === 401) {
        return showStatus('连上了，但令牌不对。请到 nodia 设置里重新复制。', true);
      }
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      showStatus(`连接正常。\n收藏库：${data.vault || '未知'}`);
    } catch (err) {
      showStatus(`连不上：${err.message}\n请确认 nodia 正在运行。`, true);
    }
  });
});
