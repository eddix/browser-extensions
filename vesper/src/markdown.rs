use crate::error::Result;
use chrono::{DateTime, Local, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use tracing::{info, warn};
use walkdir::WalkDir;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Link {
    pub title: String,
    pub url: String,
    pub created_at: Option<DateTime<Utc>>,
    pub window_title: Option<String>,
    pub source: Option<String>,
    pub mode: Option<String>,
    pub tags: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DuplicateInfo {
    pub url: String,
    pub exists_in: String,
}

pub struct MarkdownStore {
    vault_root: PathBuf,
    url_index: HashMap<String, PathBuf>,
}

impl MarkdownStore {
    pub fn new(vault_root: PathBuf) -> Result<Self> {
        let mut store = MarkdownStore {
            vault_root,
            url_index: HashMap::new(),
        };
        store.build_index()?;
        Ok(store)
    }

    pub fn rebuild_index(&mut self) -> Result<()> {
        self.url_index.clear();
        info!("Rebuilding index due to file changes...");
        self.build_index()
    }

    fn get_inbox_dir(&self) -> PathBuf {
        self.vault_root.join("Bookmark").join("01-Inbox")
    }

    fn get_daily_file_path(&self) -> PathBuf {
        let today = Local::now().format("%Y-%m-%d").to_string();
        self.get_inbox_dir().join(format!("links-{}.md", today))
    }

    fn build_index(&mut self) -> Result<()> {
        let bookmark_dir = self.vault_root.join("Bookmark");
        if !bookmark_dir.exists() {
            info!("Bookmark directory not found: {:?}", bookmark_dir);
            return Ok(());
        }

        // 匹配格式: url: https://...
        let url_re = Regex::new(r"url:\s*(https?://[^\s]+)").unwrap();
        let title_re = Regex::new(r"^\s*-\s+(.+)\s*$").unwrap();

        let mut file_count = 0;
        let mut link_count = 0;
        let mut duplicate_count = 0;

        for entry in WalkDir::new(&bookmark_dir)
            .follow_links(false)
            .into_iter()
            .filter_map(|e| e.ok())
        {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) == Some("md") {
                file_count += 1;
                let relative_path = path.strip_prefix(&self.vault_root).unwrap_or(path);
                info!("Loading file: {:?}", relative_path);

                if let Ok(content) = std::fs::read_to_string(path) {
                    let lines: Vec<&str> = content.lines().collect();
                    let mut current_title = None;

                    for line in lines.iter() {
                        if let Some(title_cap) = title_re.captures(line) {
                            current_title = Some(title_cap[1].trim().to_string());
                        }

                        if let Some(cap) = url_re.captures(line) {
                            let url = cap[1].to_string();
                            link_count += 1;

                            if let Some(existing_path) = self.url_index.get(&url) {
                                duplicate_count += 1;
                                warn!(
                                    "Duplicate URL found: {} (existing in {:?}, now in {:?})",
                                    url, existing_path, relative_path
                                );
                            } else {
                                if let Some(title) = &current_title {
                                    info!("Loaded URL: {} (title: {})", url, title);
                                } else {
                                    info!("Loaded URL: {}", url);
                                }
                                self.url_index.insert(url, relative_path.to_path_buf());
                            }
                        }
                    }
                }
            }
        }

        info!(
            "Index built: {} files, {} links, {} duplicates",
            file_count, link_count, duplicate_count
        );

        Ok(())
    }

    pub fn check_duplicate(&self, url: &str) -> Option<String> {
        self.url_index
            .get(url)
            .and_then(|p| p.to_str().map(|s| s.to_string()))
    }

    pub fn save_links(&mut self, links: Vec<Link>) -> Result<SaveResult> {
        let mut saved = 0;
        let mut duplicates = Vec::new();
        let mut errors = Vec::new();

        let file_path = self.get_daily_file_path();

        // 确保目录存在
        if let Some(parent) = file_path.parent() {
            if !parent.exists() {
                std::fs::create_dir_all(parent)?;
            }
        }

        // 检查文件是否存在
        let file_exists = file_path.exists();

        // 以追加模式打开文件
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&file_path)?;

        // 如果是新文件，写入 frontmatter
        if !file_exists {
            let today = Local::now().format("%Y-%m-%d").to_string();
            writeln!(file, "---")?;
            writeln!(file, "date: {}", today)?;
            writeln!(file, "type: browser-links")?;
            writeln!(file, "---")?;
            writeln!(file)?;
        }

        for link in links {
            // 检查重复
            if let Some(exists_in) = self.check_duplicate(&link.url) {
                duplicates.push(DuplicateInfo {
                    url: link.url.clone(),
                    exists_in,
                });
                continue;
            }

            // 写入 markdown
            match self.append_link(&mut file, &link) {
                Ok(_) => {
                    saved += 1;
                    // 更新索引
                    let relative_path = file_path.strip_prefix(&self.vault_root).unwrap_or(&file_path);
                    self.url_index.insert(link.url.clone(), relative_path.to_path_buf());
                }
                Err(e) => {
                    errors.push(SaveError {
                        url: link.url,
                        error: e.to_string(),
                    });
                }
            }
        }

        Ok(SaveResult {
            success: true,
            saved,
            duplicates,
            errors,
        })
    }

    fn append_link<W: Write>(&self, writer: &mut W, link: &Link) -> Result<()> {
        let saved_at = link.created_at.unwrap_or_else(Utc::now).with_timezone(&Local);
        let source = link.source.as_deref().unwrap_or("unknown");
        let mode = link.mode.as_deref().unwrap_or("single");

        // 第一行: 纯标题
        writeln!(writer, "- {}", escape_brackets(&link.title))?;

        // 字段
        writeln!(writer, "  - url: {}", link.url)?;
        writeln!(writer, "  - saved-at: {}", saved_at.to_rfc3339())?;
        writeln!(writer, "  - source: {}", source)?;
        writeln!(writer, "  - mode: {}", mode)?;
        if let Some(window_title) = &link.window_title {
            writeln!(writer, "  - window-title: {}", window_title)?;
        }
        writeln!(writer, "  - tag: #from-browser")?;
        writeln!(writer, "  - summary:")?;
        writeln!(writer)?;

        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct SaveResult {
    pub success: bool,
    pub saved: usize,
    pub duplicates: Vec<DuplicateInfo>,
    pub errors: Vec<SaveError>,
}

#[derive(Debug, Serialize)]
pub struct SaveError {
    pub url: String,
    pub error: String,
}

fn escape_brackets(s: &str) -> String {
    s.replace('[', "\\[").replace(']', "\\]")
}
