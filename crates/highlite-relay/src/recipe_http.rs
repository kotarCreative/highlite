use axum::body::to_bytes;
use axum::extract::{Path, Request, State};
use axum::http::{StatusCode, header::CONTENT_TYPE};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::json;

use crate::jira::IssueDraft;
use crate::recipes::{self, ConfigureRecipe, PublishTrigger, RecipeStore, RunStore, blocking};
use crate::{
    AppState, SessionStatus, bind_is_loopback, checked_session_id, error_response, read_metadata,
};

pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/recipes/jira-issue", get(configuration).post(configure))
        .route(
            "/v1/recipes/jira-issue/connection",
            axum::routing::post(test_connection),
        )
        .route(
            "/v1/recipes/jira-issue/issue-types",
            axum::routing::post(issue_types),
        )
        .route(
            "/v1/sessions/{id}/recipes/jira-issue",
            get(get_run).post(start),
        )
        .route(
            "/v1/sessions/{id}/recipes/jira-issue/draft",
            axum::routing::post(edit),
        )
        .route(
            "/v1/sessions/{id}/recipes/jira-issue/publish",
            axum::routing::post(publish),
        )
}

type RequestError = (StatusCode, &'static str);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConnectionRequest {
    site_url: String,
    email: String,
    api_token: Option<String>,
    project_key: Option<String>,
}

async fn discovery(state: AppState, request: Request, types: bool) -> Response {
    if !bind_is_loopback(&state.config.bind) {
        return error_response(
            StatusCode::FORBIDDEN,
            "Jira connection discovery requires a loopback bind",
        );
    }
    let input = match input::<ConnectionRequest>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    let target = crate::jira::JiraTarget {
        site_url: input.site_url.trim().trim_end_matches('/').to_owned(),
        email: input.email.trim().to_owned(),
        project_key: input.project_key.unwrap_or_default(),
        issue_type_id: String::new(),
        extra_fields: Default::default(),
    };
    if let Err(error) = target.validate_connection() {
        return error_response(StatusCode::BAD_REQUEST, error);
    }
    if types && !crate::jira::valid_project_key(&target.project_key) {
        return error_response(
            StatusCode::BAD_REQUEST,
            "Choose a valid Jira project first.",
        );
    }
    let token = match input.api_token {
        Some(token)
            if !token.trim().is_empty()
                && token.len() <= 16 * 1024
                && !token.chars().any(char::is_control) =>
        {
            token
        }
        Some(_) => return error_response(StatusCode::BAD_REQUEST, "Enter a valid Jira API token."),
        None => {
            let store = RecipeStore::new(state.config.config_dir.clone());
            let account = target.clone();
            match blocking(move || store.connection_token(&account)).await {
                Ok(token) => token,
                Err(error) => return error_response(StatusCode::BAD_REQUEST, error),
            }
        }
    };
    let result = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        if types {
            crate::jira::issue_types(&target, &token)
                .await
                .map(|choices| json!({"issueTypes": choices}))
        } else {
            crate::jira::test_connection(&target, &token)
                .await
                .map(|info| json!(info))
        }
    })
    .await;
    match result {
        Ok(Ok(info)) => Json(info).into_response(),
        Ok(Err(error)) => error_response(StatusCode::BAD_GATEWAY, error),
        Err(_) => error_response(
            StatusCode::GATEWAY_TIMEOUT,
            "Jira took too long to respond. Try again.",
        ),
    }
}

async fn test_connection(State(state): State<AppState>, request: Request) -> Response {
    discovery(state, request, false).await
}

async fn issue_types(State(state): State<AppState>, request: Request) -> Response {
    discovery(state, request, true).await
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
    let store = RecipeStore::new(state.config.config_dir.clone());
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
            "recipe configuration requires a loopback bind",
        );
    }
    let input = match input::<ConfigureRecipe>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    let root = state.config.config_dir.clone();
    match blocking(move || {
        if input.settings.enabled {
            crate::providers::ProviderStore::new(root.clone()).resolve_default()?;
        }
        RecipeStore::new(root).configure(input)
    })
    .await
    {
        Ok(info) => Json(info).into_response(),
        Err(error) => error_response(StatusCode::BAD_REQUEST, error),
    }
}

async fn get_run(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let id = match session(&state, &id, false) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    let store = RunStore::new(&state.config.data_dir);
    match blocking(move || store.read(&id)).await {
        Ok(run) => Json(json!({"run": run})).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn start(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let id = match session(&state, &id, true) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    match recipes::start(state, id, false).await {
        Ok(Some(run)) => (StatusCode::ACCEPTED, Json(run)).into_response(),
        Ok(None) => error_response(StatusCode::CONFLICT, "recipe is disabled"),
        Err(error) => error_response(StatusCode::CONFLICT, error),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EditDraft {
    draft: IssueDraft,
    revision: u64,
}

async fn edit(State(state): State<AppState>, Path(id): Path<String>, request: Request) -> Response {
    let id = match session(&state, &id, true) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    let input = match input::<EditDraft>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    let store = RunStore::new(&state.config.data_dir);
    match blocking(move || store.edit(&id, input.draft, input.revision)).await {
        Ok(run) => Json(run).into_response(),
        Err(error) => error_response(StatusCode::CONFLICT, error),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Approval {
    revision: u64,
}

async fn publish(
    State(state): State<AppState>,
    Path(id): Path<String>,
    request: Request,
) -> Response {
    let id = match session(&state, &id, true) {
        Ok(id) => id,
        Err((status, message)) => return error_response(status, message),
    };
    let input = match input::<Approval>(request).await {
        Ok(input) => input,
        Err((status, message)) => return error_response(status, message),
    };
    match recipes::publish(state, id, input.revision, PublishTrigger::Manual).await {
        Ok(run) => (StatusCode::ACCEPTED, Json(run)).into_response(),
        Err(error) => error_response(StatusCode::CONFLICT, error),
    }
}
