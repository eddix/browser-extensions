# Arc Tab Sorter

跨 Arc Space 的标签导航器：按域名分组、搜索、点击即切。

## 为什么改方向

最初想做的是「点一下按 domain 排序 Arc sidebar」。但实测发现 **Arc 的左侧 sidebar 维护它自己的 displayOrder，独立于底层 Chromium 的 tab.index**：

- `chrome.tabs.move` 改的是 Chromium tab strip（Arc 隐藏掉的那个）
- Arc sidebar 完全不监听这个变化
- The Browser Company 没有暴露任何能改 sidebar 顺序的 API
- Arc Boost 是 CSS/JS 注入，碰不到原生 sidebar 控件

所以"在 Arc 里通过扩展给 sidebar 排序"这条路走不通。改用 **popup 内做一个排好序的导航视图**：sidebar 维持原状不动，你不再用 sidebar 找 tab，用 popup 找。

## 现在的行为

- 拉所有 Arc Space（= 所有 chrome window）的所有 tab
- 按域名分组、字母排序（zh locale），组内按 title 排序
- 顶部搜索框：title / URL / 域名 任一匹配
- 点一行 → 自动切到对应 Space + 激活那个 tab + 关闭 popup
- 多 Space 时每行右侧 `S1`/`S2`/… 小标识在哪个 Space
- Pinned tab 加 📌 前缀
- 键盘：搜索框聚焦时 `Enter` 跳到第一条匹配；`Esc` 清搜索/关 popup

## 不做的事

- 不动 sidebar 顺序（做不到）
- 不去重、不关空白页
- 不会修改任何 tab 的 URL / 标题 / pinned 状态

## 文件

```
arc-tab-sorter/
├── manifest.json   # MV3, 仅 tabs 权限
├── popup.html      # 搜索框 + 滚动列表
├── popup.js        # 读 tab → 分组排序 → 渲染 → 点击切换
└── README.md
```

## 在 Arc 里加载

1. Arc 地址栏 `arc://extensions`（等价 `chrome://extensions`）
2. 右上角打开「Developer mode / 开发者模式」
3. 「Load unpacked」选 `browser-extensions/arc-tab-sorter/`
4. 在工具栏 pin 出图标，点开即用

升级旧版本：在扩展页面点 reload 即可，无需重新选目录。

## 后续可加（按需）

- 命令快捷键（`commands` API：⌘⇧K 一键开 popup + 搜索框聚焦）
- 关闭按钮（每行 hover 出 ×）
- 按最近访问时间排（`tab.lastAccessed`，MV3 暂未在 Arc 验证）
- 跨 Space 去重（同 URL 在多个 Space 时高亮）
