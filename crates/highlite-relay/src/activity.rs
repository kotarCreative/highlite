//! Read-only activity feed that unions the redacted metadata of both recipes.

use std::fs;
use std::io::Read;
use std::path::Path;

use axum::Json;
use axum::Router;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::AppState;

const DEFAULT_LIMIT: u32 = 25;
const MAX_LIMIT: u32 = 100;
const MAX_ERROR_CHARS: usize = 500;
const MAX_TITLE_CHARS: usize = 200;
const MAX_STATUS_CHARS: usize = 64;
const MAX_ISSUE_KEY_CHARS: usize = 128;
const MAX_URL_CHARS: usize = 2048;

pub(crate) fn routes() -> Router<AppState> {
    Router::new().route("/v1/activity", get(list_activity))
}

#[derive(Deserialize)]
struct ActivityQuery {
    limit: Option<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActivityItem {
    recipe: String,
    session_id: String,
    status: String,
    updated_at_ms: u64,
    title: Option<String>,
    issue_key: Option<String>,
    issue_url: Option<String>,
    opencode_session_id: Option<String>,
    opencode_title: Option<String>,
    error: Option<String>,
}

async fn list_activity(
    State(state): State<AppState>,
    Query(query): Query<ActivityQuery>,
) -> Response {
    let limit = query.limit.unwrap_or(DEFAULT_LIMIT);
    if !(1..=MAX_LIMIT).contains(&limit) {
        return crate::error_response(StatusCode::BAD_REQUEST, "limit must be between 1 and 100");
    }
    let data_dir = state.config.data_dir.clone();
    match tokio::task::spawn_blocking(move || collect(&data_dir, limit as usize)).await {
        Ok(Ok(items)) => Json(json!({ "items": items })).into_response(),
        Ok(Err(error)) => crate::error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
        Err(_) => {
            crate::error_response(StatusCode::INTERNAL_SERVER_ERROR, "could not read activity")
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct JiraActivityRecord {
    session_id: String,
    recipe: String,
    status: String,
    updated_at_ms: u64,
    #[serde(default)]
    issue_key: Option<String>,
    #[serde(default)]
    issue_url: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenCodeActivityRecord {
    session_id: String,
    recipe: String,
    status: String,
    updated_at_ms: u64,
    #[serde(default)]
    opencode_session_id: Option<String>,
    #[serde(default)]
    opencode_title: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

fn collect(data_dir: &Path, limit: usize) -> Result<Vec<ActivityItem>, String> {
    let root = data_dir.join("recipe-runs");
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err("could not inspect activity".to_owned()),
    };
    let mut items = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Some(name) = name.strip_suffix(".json") else {
            continue;
        };
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.file_type().is_file() || metadata.len() > 1024 * 1024 {
            continue;
        }
        let Ok(file) = fs::File::open(&path) else {
            continue;
        };
        let mut bytes = Vec::new();
        if file.take(1024 * 1024 + 1).read_to_end(&mut bytes).is_err() || bytes.len() > 1024 * 1024
        {
            continue;
        }
        if name.starts_with("jira-") {
            let Ok(Some(run)) = serde_json::from_slice::<Option<JiraActivityRecord>>(&bytes) else {
                continue;
            };
            if run.recipe != crate::recipes::ID
                || crate::checked_session_id(&run.session_id).is_none()
                || run.status.trim().is_empty()
            {
                continue;
            }
            items.push(ActivityItem {
                recipe: "jira-issue".to_owned(),
                title: None,
                session_id: run.session_id,
                status: truncate_display(&run.status, MAX_STATUS_CHARS),
                updated_at_ms: run.updated_at_ms,
                issue_key: run
                    .issue_key
                    .map(|key| truncate_display(&key, MAX_ISSUE_KEY_CHARS)),
                issue_url: run
                    .issue_url
                    .map(|url| truncate_display(&url, MAX_URL_CHARS)),
                opencode_session_id: None,
                opencode_title: None,
                error: run
                    .error
                    .map(|error| truncate_display(&error, MAX_ERROR_CHARS)),
            });
        } else if name.starts_with("opencode-") {
            let Ok(Some(run)) = serde_json::from_slice::<Option<OpenCodeActivityRecord>>(&bytes)
            else {
                continue;
            };
            if run.recipe != crate::opencode_recipe::ID
                || crate::checked_session_id(&run.session_id).is_none()
                || run.status.trim().is_empty()
            {
                continue;
            }
            items.push(ActivityItem {
                recipe: "opencode".to_owned(),
                title: None,
                session_id: run.session_id,
                status: truncate_display(&run.status, MAX_STATUS_CHARS),
                updated_at_ms: run.updated_at_ms,
                issue_key: None,
                issue_url: None,
                opencode_session_id: run.opencode_session_id.filter(|id| valid_external_id(id)),
                opencode_title: run
                    .opencode_title
                    .map(|title| truncate_display(&title, MAX_TITLE_CHARS)),
                error: run
                    .error
                    .map(|error| truncate_display(&error, MAX_ERROR_CHARS)),
            });
        }
    }
    items.sort_by_key(|item| std::cmp::Reverse(item.updated_at_ms));
    items.truncate(limit);
    // Metadata lookup is limited to the selected page, not every stored run.
    for item in &mut items {
        item.title = session_title(data_dir, &item.session_id);
    }
    Ok(items)
}

fn session_title(data_dir: &Path, session_id: &str) -> Option<String> {
    crate::read_metadata(data_dir, session_id)
        .ok()
        .and_then(|metadata| metadata.page_title)
        .map(|title| truncate_display(title.trim(), MAX_TITLE_CHARS))
        .filter(|title| !title.is_empty())
}

fn truncate_display(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_owned();
    }
    text.chars().take(max_chars).collect()
}

fn valid_external_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
}
