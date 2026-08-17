use crate::error::VesperError;
use crate::markdown::{Link, MarkdownStore, SaveResult};
use axum::{
    extract::{State, Query},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::info;

pub type AppState = Arc<Mutex<MarkdownStore>>;

pub fn create_router(state: Arc<Mutex<MarkdownStore>>) -> Router {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/links", post(post_links))
        .route("/api/check-url", get(check_url))
        .with_state(state)
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
}

async fn health() -> Json<HealthResponse> {
    info!("GET /api/health");
    Json(HealthResponse { status: "ok" })
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum LinksPayload {
    Single(Link),
    Multiple(Vec<Link>),
}

async fn post_links(
    State(state): State<AppState>,
    Json(payload): Json<LinksPayload>,
) -> Result<Json<SaveResult>, AppError> {
    let links = match payload {
        LinksPayload::Single(link) => {
            info!("POST /api/links - 1 link: {}", link.url);
            vec![link]
        }
        LinksPayload::Multiple(links) => {
            info!("POST /api/links - {} links", links.len());
            links
        }
    };

    let mut store = state.lock().await;
    let result = store.save_links(links)?;
    Ok(Json(result))
}

#[derive(Debug, Deserialize)]
struct CheckUrlQuery {
    url: String,
}

#[derive(Debug, Serialize)]
struct CheckUrlResponse {
    exists: bool,
    exists_in: Option<String>,
}

async fn check_url(
    State(state): State<AppState>,
    Query(query): Query<CheckUrlQuery>,
) -> Json<CheckUrlResponse> {
    let store = state.lock().await;
    let exists_in = store.check_duplicate(&query.url);
    info!("GET /api/check-url - exists={} - {}", exists_in.is_some(), query.url);
    Json(CheckUrlResponse {
        exists: exists_in.is_some(),
        exists_in,
    })
}

struct AppError(VesperError);

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        let (status, error_message) = match self.0 {
            VesperError::Io(_) => (StatusCode::INTERNAL_SERVER_ERROR, "IO error".to_string()),
            VesperError::Json(_) => (StatusCode::BAD_REQUEST, "Invalid JSON".to_string()),
            VesperError::Config(msg) => (StatusCode::BAD_REQUEST, msg),
            VesperError::VaultNotFound(msg) => (StatusCode::BAD_REQUEST, msg),
            VesperError::Toml(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Config error".to_string()),
            VesperError::TomlSer(_) => (StatusCode::INTERNAL_SERVER_ERROR, "Config error".to_string()),
            VesperError::AddrParse(_) => (StatusCode::BAD_REQUEST, "Invalid address".to_string()),
            VesperError::Hyper(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
        };

        let body = Json(serde_json::json!({
            "success": false,
            "error": error_message,
        }));

        (status, body).into_response()
    }
}

impl From<VesperError> for AppError {
    fn from(err: VesperError) -> Self {
        AppError(err)
    }
}
