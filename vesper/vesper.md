你现在是一个资深 Rust 全栈工程师 + 浏览器扩展开发者，帮我从零实现一套「浏览器 URL → 本地 Obsidian vault」的书签系统。技术栈和目标如下，请严格按要求设计与实现，并分阶段给出代码与说明。

## 整体目标

- 我在 Chrome / Arc 里按一个按钮或快捷键，就能把：
  - 当前 tab，或者
  - 当前窗口所有 tab
- 发送给一个本地或自托管的 Rust 后端服务。
- 后端负责把这些链接写入到 Obsidian vault 里的 Markdown 文件中，作为统一的书签/链接收集系统。
- Obsidian vault 路径在运行时通过命令行参数指定，不写死在代码里。

请把整个方案拆成「Rust 后端 + 浏览器扩展」两部分来设计和实现。

***

## 一、Rust 后端服务（核心）

### 功能要求

1. 提供一个 HTTP API，用来接收浏览器扩展发来的链接数据：
   - 典型 payload：
     ```json
     {
       "title": "Page Title",
       "url": "https://example.com",
       "created_at": "2026-02-27T03:00:00Z",
       "window_title": "Optional window title",
       "source": "chrome|arc",
       "mode": "single|window",
       "tags": ["read-later", "project-foo"]
     }
     ```
   - 支持一次发送多条链接（比如当前窗口所有 tab），也就是接受数组形式。
2. 根据当前日期，写入到 Obsidian vault 下某个目录里的 Markdown 文件中，例如：
   - `{{vault_root}}/Bookmark/01-Inbox/links-2026-02-27.md`
3. 如果对应日期的文件不存在，就创建文件并带上简单的 frontmatter，例如：
   ```markdown
   ---
   date: 2026-02-27
   type: browser-links
   ---

   ```
4. 每次收到链接，向文件末尾 append 一条记录，格式统一，便于 Obsidian 后续使用 Dataview / Tasks 查询。例如：
   ```markdown
   - [ ] [Page Title](https://example.com) #read-later #from-browser
     - saved-at:: 2026-02-27T12:03:00+09:00
     - source:: chrome
     - mode:: single
   ```
   - 如果 `tags` 里有项目名（如 `project-foo`），一起变成 Markdown 标签。
5. 要求对同一 URL 做简单去重策略 (必须)：
   - 在启动时递归加载 `{{value_root}}/Bookmark` 下所有 md 里面的 URL，发现有重复 URL 不再重复保存，而是返回插件告知 URL 已经存在于哪个 markdown 里面。

### 技术要求

- 用 Rust 2021 或 2024 edition。
- 后端框架你自由选择（如 `axum` / `actix-web` / `warp` 等），请选择生态好的。
- 配置方式：
  - Obsidian vault 根路径从命令行参数读取（例如 `--vault-path /path/to/vault`）。
  - 用到过的 vault 配置到 ~/.vesper/config.tom 里面，支持在配置里存储多个 vault，在启动时如果没有指定 value path，则从配置里读取出来让我选择。
- 路径拼接与文件操作：
  - 注意跨平台路径处理（使用 `std::path::Path` / `PathBuf`）。
  - 对文件并发写入要安全：建议用文件级锁或简单的串行写入方式，保证不会写乱。
- 错误处理：
  - 使用 `thiserror` 或 `anyhow` 统一错误类型，清晰区分 I/O 错误、序列化错误、无效 payload 等。

### 请你输出

1. API 设计说明（端点路径、HTTP 方法、请求/响应格式）。
2. Rust 后端的完整代码结构：
   - `Cargo.toml`
   - `src/main.rs`
   - 必要的模块文件（例如 `src/config.rs`, `src/routes.rs`, `src/markdown.rs` 等）。
3. 简要说明如何编译和运行：
   - `cargo run -- --vault-path "/path/to/ObsidianVault"`

***

## 二、浏览器扩展（Chrome / Arc 兼容）

### 目标

- 一个 Manifest V3 的扩展，支持在 Chrome / Arc 上使用。
- 功能：
  - 在工具栏图标点击时：
    - 发送「当前 tab」到后端。
  - 在 popup 中提供一个按钮：
    - 发送「当前窗口所有 tab」到后端。
  - 可选：为右键菜单添加一个「发送此链接到 Obsidian」的项（对选中链接/页面）。

### 具体要求

1. Manifest:
   - 使用 Manifest V3。
   - 需要的权限：
     - `tabs`
     - `activeTab`
     - `scripting`（如需要）
     - `storage`（用来保存后端 URL 等配置）
     - `contextMenus`（如果实现右键功能）。
2. 配置：
   - 在扩展的 Options 页面里，允许我配置：
     - Rust 后端的 base URL，例如：`http://localhost:8787/api/links`
   - 配置存储在 `chrome.storage.sync` 或 `local` 中。
3. 发送逻辑：
   - 发送当前 tab：
     - 提取 `title`, `url`。
     - 添加当前时间 `created_at`（ISO 字符串）以及 `source: "chrome"`、`mode: "single"`。
     - POST 到后端。
   - 发送当前窗口所有 tab：
     - 用 `chrome.tabs.query({currentWindow: true})` 获取所有 tab。
     - 过滤掉 `chrome://` 等无效 URL。
     - 组装一个数组 payload 一起 POST。
4. 代码结构：
   - `manifest.json`
   - `background.js` 或 `service_worker.js`（根据 MV3 要求）
   - `popup.html` + `popup.js`
   - `options.html` + `options.js`

### 请你输出

1. 完整的 `manifest.json`。
2. `background/service worker` 的核心代码（获取 tab+发送到后端）。
3. popup 和 options 页面的最小可用 HTML+JS 代码。
4. 简要说明如何在开发者模式下加载扩展，并与本地 Rust 后端联调。

***

## 三、开发和结构化输出要求

1. 请一步一步来，每一大部分先给：
   - 架构/设计说明；
   - 然后再给完整代码（可以分文件但都贴出来）。
2. 对所有命令行参数和配置选项，给出使用示例。
3. 在 Markdown 写入格式上，请再强调一次：
   - 前面有统一的 frontmatter。
   - 每条链接是一个 `- [ ]` 任务条。
   - 带上 `saved-at::`、`source::`、`mode::` 等字段，方便 Obsidian Dataview 使用。
4. 所有 Rust 代码必须编译通过（假设使用最新稳定版本），需要的 crate 请完整列出并在 `Cargo.toml` 中声明。

如果你有更好的结构建议，也可以在设计说明里提出并实现，但请保证最终使用体验简单清晰。
