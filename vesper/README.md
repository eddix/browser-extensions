# Vesper

浏览器 URL → Obsidian vault 的书签系统。本地 Rust 服务 + 配套 MV3 扩展，
内容以纯 Markdown 落在 vault 里，**不依赖任何特定浏览器**。

## 它要解决的问题

浏览器标签栏同时被当成三种东西用，而这三种东西的生命周期和召回方式完全不同，
混在一起就必然烂掉（实测数据：71 个 pinned tab 里 75% 超过 30 天没碰过，
最老的一个 549 天）：

| 用法 | 生命周期 | 召回方式 | 结束信号 |
|---|---|---|---|
| **书签** bookmark | 跟项目走，数月 | 随时按需搜索，要快 | 无 |
| **稍后读** readlater | 几天到几周 | 有空时被推送 | 读完或放弃 |
| **待办** todo | 到做完为止 | 在正确时间提醒 | 完成 |

Vesper 负责把三者都接住并分开存放，让「关掉这个 tab」不再有心理成本。

## 数据安全红线

抓取页面正文供 LLM 生成摘要，技术动作与「恶意扩展偷偷回传浏览内容」完全相同
（参见同仓库 [hedra](../hedra) 的由来）。区别只在下面三条，**任何一条破了这个
工具就变成了它要取代的东西**：

1. **只在用户显式点击保存时抓取当前页**，绝不后台自动抓取、绝不批量扫描历史。
2. 正文只发往用户自己配置的后端与 LLM；**内网域名走内网 LLM，公网域名走公网
   LLM**，两者不得混流。
3. endpoint、API key、内网地址一律只存在 `~/.vesper/config.toml`，
   **不进仓库**（本仓库是公开的）。

## 路线图

- [ ] 抓正文 + LLM 摘要（`Link` 目前没有 `summary` 字段，Markdown 里那行是
      硬编码的空值），按域名分流内网/公网模型
- [ ] 保存时区分 bookmark / readlater / todo，默认 readlater 一键直存；
      todo 写成 `- [ ]` 形式以便被 Obsidian Tasks 插件与日报聚合
- [ ] 与 [nodia](../nodia) 打通：一个入口同时搜 Arc 标签与 vault 里的书签

## 项目结构

```
vesper/
├── Cargo.toml
├── src/
│   ├── main.rs          # 入口
│   ├── config.rs        # 配置管理
│   ├── api.rs           # API 路由
│   ├── markdown.rs      # Markdown 文件操作
│   └── error.rs         # 错误类型
└── extension/           # 浏览器扩展
    ├── manifest.json
    ├── background.js
    ├── popup.html
    ├── popup.js
    ├── options.html
    ├── options.js
    └── icons/           # 需要添加图标文件
```

## 第一部分：Rust 后端

### 编译和运行

```bash
# 指定 vault 路径运行
cargo run -- --vault-path "/path/to/your/ObsidianVault"

# 或使用自定义端口
cargo run -- --vault-path "/path/to/vault" --port 3000
```

### API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/health` | GET | 健康检查 |
| `/api/links` | POST | 接收链接数据 |

### 请求示例

```json
POST /api/links
Content-Type: application/json

{
  "title": "Page Title",
  "url": "https://example.com",
  "created_at": "2026-02-27T03:00:00Z",
  "window_title": "Optional window title",
  "source": "chrome",
  "mode": "single",
  "tags": ["read-later", "project-foo"]
}
```

或发送数组：

```json
[
  {...},
  {...}
]
```

### Markdown 格式

文件会被写入到 `{{vault_root}}/Bookmark/01-Inbox/links-YYYY-MM-DD.md`

Frontmatter:
```markdown
---
date: 2026-02-27
type: browser-links
---
```

链接记录格式:
```markdown
- [ ] [Page Title](https://example.com) #read-later #from-browser
  - saved-at:: 2026-02-27T12:03:00+09:00
  - source:: chrome
  - mode:: single
```

## 第二部分：浏览器扩展

### 安装图标

在 `extension/icons/` 目录下添加以下图标文件：
- `icon16.png` (16x16)
- `icon48.png` (48x48)
- `icon128.png` (128x128)

或者使用任意图片，重命名为上述文件名。

### 加载扩展（Chrome / Arc）

1. 打开 Chrome/Arc，访问 `chrome://extensions/`
2. 开启右上角的 "Developer mode"（开发者模式）
3. 点击 "Load unpacked"（加载已解压的扩展程序）
4. 选择本项目的 `extension` 目录

### 配置扩展

1. 点击扩展图标，选择 "⚙️ Settings"
2. 配置后端 API URL（默认：`http://localhost:8787/api/links`）
3. 点击 "Test Connection" 测试连接
4. 点击 "Save Settings" 保存

### 使用

- 点击扩展图标 → "Send Current Tab"：发送当前标签页
- 点击扩展图标 → "Send All Tabs in Window"：发送当前窗口所有标签页
- 右键菜单 → "Send to Obsidian"：发送当前页面或选中的链接

## 配置文件

Vesper 会在 `~/.vesper/config.toml` 保存使用过的 vault 路径。
