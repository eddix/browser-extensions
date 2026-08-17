use crate::error::{Result, VesperError};
use clap::{Parser, Subcommand};
use dirs::home_dir;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Parser)]
#[command(author, version, about = "Vesper - browser bookmarks to Obsidian")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Path to Obsidian vault
    #[arg(long = "vault-path", global = true)]
    pub vault_path: Option<PathBuf>,

    /// Port to listen on
    #[arg(long = "port", default_value = "8787", global = true)]
    pub port: u16,

    /// Host to bind to
    #[arg(long = "host", default_value = "127.0.0.1", global = true)]
    pub host: String,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Run the server in the foreground (default)
    Serve,
    /// Install as a launchd service (macOS)
    Install,
    /// Stop and uninstall the launchd service
    Uninstall,
    /// Show service status
    Status,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Config {
    pub vaults: Vec<VaultConfig>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct VaultConfig {
    pub path: PathBuf,
    pub name: Option<String>,
    pub last_used: Option<chrono::DateTime<chrono::Local>>,
}

impl Config {
    pub fn config_dir() -> Result<PathBuf> {
        let home = home_dir()
            .ok_or_else(|| VesperError::Config("Could not find home directory".into()))?;
        let dir = home.join(".vesper");
        if !dir.exists() {
            std::fs::create_dir_all(&dir)?;
        }
        Ok(dir)
    }

    fn config_file() -> Result<PathBuf> {
        Ok(Self::config_dir()?.join("config.toml"))
    }

    pub fn load() -> Result<Self> {
        let path = Self::config_file()?;
        if !path.exists() {
            return Ok(Config { vaults: Vec::new() });
        }
        let content = std::fs::read_to_string(&path)?;
        Ok(toml::from_str(&content)?)
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::config_file()?;
        let content = toml::to_string_pretty(self)?;
        std::fs::write(&path, content)?;
        Ok(())
    }

    pub fn add_vault(&mut self, path: &Path) {
        let path = path.to_path_buf();
        if let Some(existing) = self.vaults.iter_mut().find(|v| v.path == path) {
            existing.last_used = Some(chrono::Local::now());
        } else {
            self.vaults.push(VaultConfig {
                path,
                name: None,
                last_used: Some(chrono::Local::now()),
            });
        }
    }
}

pub fn select_vault(cli: &Cli) -> Result<PathBuf> {
    if let Some(path) = &cli.vault_path {
        if !path.exists() {
            return Err(VesperError::VaultNotFound(format!("{:?}", path)));
        }
        let mut config = Config::load()?;
        config.add_vault(path);
        config.save()?;
        return Ok(path.clone());
    }

    let config = Config::load()?;
    if config.vaults.is_empty() {
        return Err(VesperError::Config(
            "No vault specified and no saved vaults found. Use --vault-path to specify one.".into(),
        ));
    }

    if config.vaults.len() == 1 {
        let mut config = Config::load()?;
        config.vaults[0].last_used = Some(chrono::Local::now());
        let path = config.vaults[0].path.clone();
        config.save()?;
        return Ok(path);
    }

    println!("Multiple vaults found, please select one:");
    for (i, vault) in config.vaults.iter().enumerate() {
        let name = vault
            .name
            .as_deref()
            .unwrap_or_else(|| vault.path.to_str().unwrap_or("unknown"));
        println!("  [{}] {}", i + 1, name);
    }

    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    let selection: usize = input
        .trim()
        .parse()
        .map_err(|_| VesperError::Config("Invalid selection".into()))?;

    if selection < 1 || selection > config.vaults.len() {
        return Err(VesperError::Config("Invalid selection".into()));
    }

    let mut config = Config::load()?;
    config.vaults[selection - 1].last_used = Some(chrono::Local::now());
    let path = config.vaults[selection - 1].path.clone();
    config.save()?;

    Ok(path)
}
