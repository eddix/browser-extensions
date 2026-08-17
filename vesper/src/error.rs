use thiserror::Error;

#[derive(Error, Debug)]
pub enum VesperError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON serialization error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("Vault path not found: {0}")]
    VaultNotFound(String),

    #[error("Toml error: {0}")]
    Toml(#[from] toml::de::Error),

    #[error("Toml ser error: {0}")]
    TomlSer(#[from] toml::ser::Error),

    #[error("Address parse error: {0}")]
    AddrParse(#[from] std::net::AddrParseError),

    #[error("Server error: {0}")]
    Hyper(String),
}

pub type Result<T> = std::result::Result<T, VesperError>;
