// hedra background — 唯一职责：浏览器启动/安装后恢复工具栏 badge。
// DNR 动态规则本身由引擎持久化，无需在这里重建。

function restoreBadge() {
  chrome.storage.local.get({ masterEnabled: true, presets: [] }, ({ masterEnabled, presets }) => {
    const n = masterEnabled ? presets.filter((p) => p.enabled).length : 0;
    chrome.action.setBadgeText({ text: n ? String(n) : "" });
    chrome.action.setBadgeBackgroundColor({ color: "#1f883d" });
  });
}

chrome.runtime.onStartup.addListener(restoreBadge);
chrome.runtime.onInstalled.addListener(restoreBadge);
