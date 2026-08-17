mod api;
mod config;
mod daemon;
mod error;
mod markdown;

use crate::api::create_router;
use crate::config::{select_vault, Cli, Command};
use crate::error::{Result, VesperError};
use crate::markdown::MarkdownStore;
use clap::Parser;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower_http::cors::{Any, CorsLayer};

async fn watch_files(vault_path: PathBuf, store: Arc<Mutex<MarkdownStore>>) -> notify::Result<()> {
    let (tx, mut rx) = tokio::sync::mpsc::channel(100);
    let bookmark_dir = vault_path.join("Bookmark");

    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| {
            let _ = tx.blocking_send(res);
        },
        notify::Config::default(),
    )?;

    if bookmark_dir.exists() {
        tracing::info!("Watching directory: {:?}", bookmark_dir);
        watcher.watch(&bookmark_dir, RecursiveMode::Recursive)?;
    } else {
        tracing::warn!(
            "Bookmark directory not found, watching vault root: {:?}",
            vault_path
        );
        watcher.watch(&vault_path, RecursiveMode::Recursive)?;
    }

    let mut needs_rebuild = false;
    let mut debounce_interval =
        tokio::time::interval(std::time::Duration::from_millis(500));
    debounce_interval.tick().await;

    loop {
        tokio::select! {
            Some(res) = rx.recv() => {
                match res {
                    Ok(event) => {
                        if matches!(event.kind,
                            EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
                        ) {
                            tracing::debug!("File change detected: {:?}", event.paths);
                            needs_rebuild = true;
                        }
                    }
                    Err(e) => tracing::error!("Watch error: {}", e),
                }
            }
            _ = debounce_interval.tick() => {
                if needs_rebuild {
                    needs_rebuild = false;
                    let mut store = store.lock().await;
                    if let Err(e) = store.rebuild_index() {
                        tracing::error!("Failed to rebuild index: {}", e);
                    }
                }
            }
        }
    }
}

async fn serve(cli: &Cli) -> Result<()> {
    let vault_path = select_vault(cli)?;
    tracing::info!("Using vault: {:?}", vault_path);

    let store = Arc::new(Mutex::new(MarkdownStore::new(vault_path.clone())?));

    let cors = CorsLayer::new()
        .allow_methods(Any)
        .allow_headers(Any)
        .allow_origin(Any);

    let app = create_router(Arc::clone(&store)).layer(cors);

    let store_clone = Arc::clone(&store);
    let vault_path_clone = vault_path.clone();
    tokio::spawn(async move {
        if let Err(e) = watch_files(vault_path_clone, store_clone).await {
            tracing::error!("File watcher failed: {}", e);
        }
    });

    let addr = format!("{}:{}", cli.host, cli.port).parse()?;
    tracing::info!("Listening on {}", addr);

    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .map_err(|e| VesperError::Hyper(e.to_string()))?;

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "vesper=info,tower_http=info".into()),
        )
        .init();

    let cli = Cli::parse();

    match &cli.command {
        None | Some(Command::Serve) => {
            serve(&cli).await?;
        }
        Some(Command::Install) => {
            let vault_path = select_vault(&cli)?;
            daemon::install(&cli, &vault_path)?;
        }
        Some(Command::Uninstall) => {
            daemon::uninstall()?;
        }
        Some(Command::Status) => {
            daemon::status()?;
        }
    }

    Ok(())
}
