//! HTTP surface for the OpenCode recipe.

use axum::body::to_bytes;
use axum::extract::{Path, Request, State};
use axum::http::{StatusCode, header::CONTENT_TYPE};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::json;

use crate::opencode_recipe::{
    self, OpenCodeRecipeStore, OpenCodeRunStore, OpenCodeSettings, blocking,
};
use crate::{
    AppState, SessionStatus, bind_is_loopback, checked_session_id, error_response, read_metadata,
};

pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/recipes/opencode", get(configuration).post(configure))
        .route("/v1/recipes/opencode/discover", post(discover))
        .route(
            "/v1/sessions/{id}/recipes/opencode",
            get(get_run).post(start),
        )
        .route("/v1/sessions/{id}/recipes/opencode/submit", post(submit))
}

type RequestError = (StatusCode, &'static str);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfigureRequest {
    settings: OpenCodeSettings,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DiscoverRequest {
    opencode_path: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SubmitRequest {
    revision: u64,
    session_id: String,
    confirm: bool,
}

async fn input<T: DeserializeOwned>(request: Request) -> Result<T, RequestError> {
    if !request
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|header| header.to_str().ok())
        .is_some_and(|header| {
            header
                .split(';')
                .next()
                .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("application/json"))
        })
    {
        return Err((
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "content type must be application/json",
        ));
    }
    let bytes = to_bytes(request.into_body(), 64 * 1024)
        .await
        .map_err(|_| (StatusCode::PAYLOAD_TOO_LARGE, "recipe request is too large"))?;
    if bytes.is_empty() {
        return serde_json::from_slice(b"{}")
            .map_err(|_| (StatusCode::BAD_REQUEST, "invalid recipe request"));
    }
    serde_json::from_slice(&bytes).map_err(|_| (StatusCode::BAD_REQUEST, "invalid recipe request"))
}

fn session(state: &AppState, id: &str, ready: bool) -> Result<String, RequestError> {
    let id = checked_session_id(id).ok_or((StatusCode::NOT_FOUND, "session not found"))?;
    let metadata = read_metadata(&state.config.data_dir, &id)
        .map_err(|_| (StatusCode::NOT_FOUND, "session not found"))?;
    if ready && metadata.status != SessionStatus::Ready {
        return Err((StatusCode::CONFLICT, "session is not ready"));
    }
    Ok(id)
}

async fn configuration(State(state): State<AppState>) -> Response {
    let management_enabled = bind_is_loopback(&state.config.bind);
    let store = OpenCodeRecipeStore::new(state.config.config_dir.clone());
    match blocking(move || store.info()).await {
        Ok(info) => {
            Json(json!({ "managementEnabled": management_enabled, "recipe": info })).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn configure(State(state): State<AppState>, request: Request) -> Response {
    if !bind_is_loopback(&state.config.bind) {
        return error_response(
            StatusCode::FORBIDDEN,
            "OpenCode recipe configuration requires a loopback bind",
        );
    }
    let input = match input::<ConfigureRequest>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    let store = OpenCodeRecipeStore::new(state.config.config_dir.clone());
    match blocking(move || store.configure(input.settings)).await {
        Ok(info) => Json(info).into_response(),
        Err(error) => error_response(StatusCode::BAD_REQUEST, error),
    }
}

async fn discover(State(state): State<AppState>, request: Request) -> Response {
    if !bind_is_loopback(&state.config.bind) {
        return error_response(
            StatusCode::FORBIDDEN,
            "OpenCode discovery requires a loopback bind",
        );
    }
    let input = match input::<DiscoverRequest>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    if let Some(path) = &input.opencode_path
        && let Err(error) = crate::opencode::validate_path(path)
    {
        return error_response(StatusCode::BAD_REQUEST, error);
    }
    let store = OpenCodeRecipeStore::new(state.config.config_dir.clone());
    let settings = match blocking(move || {
        store
            .info()?
            .settings
            .ok_or_else(|| "configure the OpenCode recipe first".to_owned())
    })
    .await
    {
        Ok(settings) => settings,
        Err(error) => return error_response(StatusCode::BAD_REQUEST, error),
    };
    let _permit = match state.run_slots.clone().acquire_owned().await {
        Ok(permit) => permit,
        Err(_) => {
            return error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                "the relay is shutting down",
            );
        }
    };
    match opencode_recipe::discover(&settings, input.opencode_path.as_deref()).await {
        Ok(discovery) => Json(json!({
            "opencode": { "version": discovery.version },
            "directory": discovery.directory,
            "sessions": discovery.sessions,
            "projects": discovery.projects,
        }))
        .into_response(),
        Err(error) if error.contains("directory") => error_response(StatusCode::BAD_REQUEST, error),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn get_run(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let id = match session(&state, &id, false) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    let store = OpenCodeRunStore::new(&state.config.data_dir);
    match blocking(move || store.read(&id)).await {
        Ok(run) => Json(json!({ "run": run })).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn start(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    if !bind_is_loopback(&state.config.bind) {
        return error_response(
            StatusCode::FORBIDDEN,
            "OpenCode recipe starts require a loopback bind",
        );
    }
    let id = match session(&state, &id, true) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    match opencode_recipe::start(state, id, false).await {
        Ok(Some(run)) => (StatusCode::ACCEPTED, Json(run)).into_response(),
        Ok(None) => error_response(StatusCode::CONFLICT, "recipe is disabled"),
        Err(error) => error_response(StatusCode::CONFLICT, error),
    }
}

async fn submit(
    State(state): State<AppState>,
    Path(id): Path<String>,
    request: Request,
) -> Response {
    if !bind_is_loopback(&state.config.bind) {
        return error_response(
            StatusCode::FORBIDDEN,
            "OpenCode submission requires a loopback bind",
        );
    }
    let id = match session(&state, &id, true) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    let input = match input::<SubmitRequest>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    if !input.confirm {
        return error_response(StatusCode::BAD_REQUEST, "confirm must be true");
    }
    let permit = match state.run_slots.clone().acquire_owned().await {
        Ok(permit) => permit,
        Err(_) => {
            return error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                "the relay is shutting down",
            );
        }
    };
    match opencode_recipe::submit(state, id, input.revision, input.session_id, permit).await {
        Ok(run) => (StatusCode::ACCEPTED, Json(run)).into_response(),
        Err(error) => error_response(StatusCode::CONFLICT, error),
    }
}
