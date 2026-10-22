//! Authenticated relay for Highlite capture bundles.
//!
//! The relay accepts a ZIP produced by the SDK (or an equivalent capture directory),
//! extracts it with strict path and size limits, and runs the canonical compiler.
//! It is intentionally small: the HTTP layer only routes and authenticates, while
//! all bundle work happens in blocking tasks.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Cursor, Read};
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::{Body, to_bytes};
use axum::extract::{Path as RoutePath, Request, State};
use axum::http::header::{
    ACCESS_CONTROL_ALLOW_HEADERS, ACCESS_CONTROL_ALLOW_METHODS, ACCESS_CONTROL_ALLOW_ORIGIN,
    ACCESS_CONTROL_EXPOSE_HEADERS, ACCESS_CONTROL_MAX_AGE, AUTHORIZATION, CACHE_CONTROL,
    CONTENT_DISPOSITION, CONTENT_TYPE, HOST, LOCATION, ORIGIN, VARY, WWW_AUTHENTICATE,
    X_CONTENT_TYPE_OPTIONS,
};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use bytes::Bytes;
use highlite_compiler::bundle::resolve_capture_path;
use highlite_compiler::{
    BundleOptions, CommandTranscriber, CompileInput, CompileOptions, HighliteManifest, Transcriber,
    TranscriptionRequest, compile_capture, shift_transcript, write_bundle,
};
use hmac::{Hmac, KeyInit, Mac};
use reqwest::redirect::Policy;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use subtle::ConstantTimeEq;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::Semaphore;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

const MANIFEST_SCHEMA_VERSION: &str = "0.1.0";
const MAX_PATH_COMPONENTS: usize = 16;
const MAX_RUN_OUTPUT_BYTES: usize = 64 * 1024;
const DEFAULT_PIPELINE_TIMEOUT_SECONDS: u64 = 300;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(1);

/// Runtime settings for the relay. Build it from CLI flags with `config_from_args`.
#[derive(Clone, Debug)]
pub struct RelayConfig {
    pub bind: String,
    pub data_dir: PathBuf,
    pub ingest_tokens: Vec<String>,
    pub read_tokens: Vec<String>,
    pub allowed_hosts: Vec<String>,
    pub allowed_origins: Vec<String>,
    pub max_upload_bytes: usize,
    pub max_uncompressed_bytes: u64,
    pub max_files: usize,
    pub concurrency: usize,
    pub transcriber_command: Option<String>,
    pub language: Option<String>,
    pub keep_uploads: bool,
    pub ui: bool,
    pub allow_pipelines: bool,
    pub pipelines_file: Option<PathBuf>,
    pub pipeline_concurrency: usize,
    pub compile: CompileOptions,
    pub bundle: BundleOptions,
    pub webhook: Option<WebhookConfig>,
}

#[derive(Clone, Debug)]
pub struct WebhookConfig {
    pub url: String,
    pub secret: String,
    pub timeout_ms: u64,
    pub max_attempts: u32,
}

impl RelayConfig {
    fn validate(&self) -> Result<(), String> {
        if self.ingest_tokens.is_empty() || self.ingest_tokens.iter().any(|token| token.is_empty())
        {
            return Err(
                "at least one non-empty HIGHLITE_RELAY_INGEST_TOKEN is required".to_owned(),
            );
        }
        if self.concurrency == 0 {
            return Err("HIGHLITE_RELAY_CONCURRENCY must be at least 1".to_owned());
        }
        if self.max_upload_bytes == 0 {
            return Err("HIGHLITE_RELAY_MAX_UPLOAD_MB must be at least 1".to_owned());
        }
        if self.max_uncompressed_bytes == 0 {
            return Err("HIGHLITE_RELAY_MAX_UNCOMPRESSED_MB must be at least 1".to_owned());
        }
        if self.max_files == 0 {
            return Err("HIGHLITE_RELAY_MAX_FILES must be at least 1".to_owned());
        }
        if self.pipeline_concurrency == 0 {
            return Err("HIGHLITE_RELAY_PIPELINE_CONCURRENCY must be at least 1".to_owned());
        }
        if self.allow_pipelines && !bind_is_loopback(&self.bind) {
            return Err(
                "HIGHLITE_RELAY_ALLOW_PIPELINES requires a loopback HIGHLITE_RELAY_BIND".to_owned(),
            );
        }
        if self.compile.max_keyframes == Some(0) {
            return Err("HIGHLITE_RELAY_MAX_KEYFRAMES must be at least 1".to_owned());
        }
        if let Some(padding) = self.compile.crop_padding_px
            && (!padding.is_finite() || padding < 0.0)
        {
            return Err("HIGHLITE_RELAY_CROP_PADDING_PX must be a non-negative number".to_owned());
        }
        if self.bundle.contact_sheet_width == 0 {
            return Err("HIGHLITE_RELAY_CONTACT_SHEET_WIDTH must be at least 1".to_owned());
        }
        if let Some(webhook) = &self.webhook {
            if webhook.secret.len() < 16 {
                return Err(
                    "HIGHLITE_RELAY_WEBHOOK_SECRET must be at least 16 characters".to_owned(),
                );
            }
            if webhook.timeout_ms == 0 {
                return Err("HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS must be at least 1".to_owned());
            }
            if webhook.max_attempts == 0 {
                return Err("HIGHLITE_RELAY_WEBHOOK_ATTEMPTS must be at least 1".to_owned());
            }
            let url = reqwest::Url::parse(&webhook.url)
                .map_err(|error| format!("invalid webhook URL: {error}"))?;
            match url.scheme() {
                "https" => {}
                "http" if is_loopback_host(url.host_str().unwrap_or_default()) => {}
                "http" => {
                    return Err(
                        "webhook URLs must use https unless they target localhost".to_owned()
                    );
                }
                scheme => return Err(format!("unsupported webhook URL scheme: {scheme}")),
            }
        }
        Ok(())
    }
}

#[derive(Clone)]
struct AppState {
    config: Arc<RelayConfig>,
    compile_slots: Arc<Semaphore>,
    run_slots: Arc<Semaphore>,
    pipelines: Arc<Vec<Pipeline>>,
    in_flight: Arc<Mutex<std::collections::HashSet<String>>>,
}

/// A trusted local command that can be run against a compiled session.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pipeline {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub command: String,
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    #[serde(default = "default_pipeline_timeout_seconds")]
    pub timeout_seconds: u64,
    #[serde(default)]
    pub env: HashMap<String, String>,
}

fn default_pipeline_timeout_seconds() -> u64 {
    DEFAULT_PIPELINE_TIMEOUT_SECONDS
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PipelinesFile {
    #[serde(default)]
    pipelines: Vec<Pipeline>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PipelineRunStatus {
    Queued,
    Running,
    Succeeded,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PipelineRun {
    pub run_id: String,
    pub session_id: String,
    pub pipeline: String,
    pub status: PipelineRunStatus,
    pub created_at_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stderr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMetadata {
    pub session_id: String,
    pub status: SessionStatus,
    pub received_at_ms: u64,
    pub bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub webhook: Option<WebhookDelivery>,
    pub status_url: String,
    pub bundle_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebhookDelivery {
    pub delivery_id: String,
    pub status: WebhookStatus,
    pub attempts: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivered_at_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WebhookStatus {
    Pending,
    Delivered,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Ready,
    Failed,
}

#[derive(Debug)]
enum UploadOutcome {
    Created(SessionMetadata),
    Existing(SessionMetadata),
    Failed {
        metadata: SessionMetadata,
        status: StatusCode,
        message: String,
    },
}

#[derive(Debug)]
struct UploadError {
    status: StatusCode,
    message: String,
}

impl UploadError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, message)
    }

    fn unprocessable(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNPROCESSABLE_ENTITY, message)
    }

    fn internal(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, message)
    }
}

struct InFlightGuard {
    set: Arc<Mutex<std::collections::HashSet<String>>>,
    id: String,
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        if let Ok(mut set) = self.set.lock() {
            set.remove(&self.id);
        }
    }
}

struct TempCapture {
    path: PathBuf,
}

impl Drop for TempCapture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// Build the HTTP application. The returned router is fully configured and stateless
/// apart from the shared in-flight set, compile semaphore, and pipeline runs.
pub fn build_app(config: RelayConfig) -> Result<Router, String> {
    config.validate()?;
    create_data_dirs(&config.data_dir)?;
    let pipelines = load_pipelines(&config)?;
    if config.allow_pipelines {
        eprintln!(
            "pipelines enabled with {} configured pipeline(s)",
            pipelines.len()
        );
    }
    let state = AppState {
        compile_slots: Arc::new(Semaphore::new(config.concurrency)),
        run_slots: Arc::new(Semaphore::new(config.pipeline_concurrency)),
        pipelines: Arc::new(pipelines),
        in_flight: Arc::new(Mutex::new(std::collections::HashSet::new())),
        config: Arc::new(config),
    };

    let api = Router::new()
        .route("/v1/sessions", get(list_sessions).post(ingest_session))
        .route("/v1/sessions/{id}", get(get_session))
        .route("/v1/sessions/{id}/bundle.zip", get(get_bundle))
        .route("/v1/sessions/{id}/runs", get(list_session_runs))
        .route("/v1/sessions/{id}/pipelines/{name}", post(start_pipeline))
        .route("/v1/pipelines", get(list_pipelines))
        .route("/v1/runs/{id}", get(get_run))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_api_token,
        ));

    let mut app = Router::new().route("/healthz", get(health));
    if state.config.ui {
        app = app.route("/", get(ui_index));
    }

    Ok(app
        .merge(api)
        .layer(middleware::from_fn_with_state(state.clone(), guard_request))
        .with_state(state))
}

fn create_data_dirs(root: &Path) -> Result<(), String> {
    for child in [
        "inbox",
        "sessions",
        "bundles",
        "downloads",
        "uploads",
        "runs",
    ] {
        fs::create_dir_all(root.join(child))
            .map_err(|error| format!("could not create {}: {error}", root.join(child).display()))?;
    }
    Ok(())
}

async fn ui_index() -> Html<&'static str> {
    Html(include_str!("ui.html"))
}

async fn health() -> impl IntoResponse {
    Json(json!({
        "status": "ok",
        "compiler": highlite_compiler::COMPILER_NAME,
        "version": highlite_compiler::COMPILER_VERSION,
    }))
}

async fn guard_request(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let origin = request
        .headers()
        .get(ORIGIN)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let host = request
        .headers()
        .get(HOST)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .or_else(|| {
            request
                .uri()
                .authority()
                .map(|authority| authority.as_str().to_owned())
        });
    let origin_allowed = match origin.as_deref() {
        Some(origin) => {
            origin_is_allowed(origin, &state.config.allowed_origins)
                || (state.config.ui
                    && host
                        .as_deref()
                        .is_some_and(|host| origin_matches_host(origin, host)))
        }
        None => false,
    };

    if origin.is_some() && !origin_allowed {
        return error_response(StatusCode::FORBIDDEN, "origin is not allowed");
    }

    if !host_is_allowed(host.as_deref(), &state.config.allowed_hosts) {
        return error_response(StatusCode::MISDIRECTED_REQUEST, "host is not allowed");
    }

    if request.method() == Method::OPTIONS {
        let mut response = StatusCode::NO_CONTENT.into_response();
        apply_cors(response.headers_mut(), origin.as_deref(), origin_allowed);
        return response;
    }

    let mut response = next.run(request).await;
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
        .headers_mut()
        .insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    apply_cors(response.headers_mut(), origin.as_deref(), origin_allowed);
    response
}

fn origin_is_allowed(origin: &str, allowed: &[String]) -> bool {
    allowed
        .iter()
        .any(|candidate| candidate.trim_end_matches('/').eq_ignore_ascii_case(origin))
}

/// The bundled UI talks to the relay from the same origin. Browsers still send an
/// `Origin` header on its POSTs, so let the UI's own origin through without
/// requiring operators to allowlist their own local address.
fn origin_matches_host(origin: &str, host: &str) -> bool {
    origin
        .split_once("://")
        .is_some_and(|(_, authority)| authority.eq_ignore_ascii_case(host.trim()))
}

fn host_is_allowed(host: Option<&str>, allowed: &[String]) -> bool {
    if allowed.is_empty() {
        return true;
    }
    let Some(host) = host else {
        return false;
    };
    allowed
        .iter()
        .any(|candidate| candidate.trim().eq_ignore_ascii_case(host.trim()))
}

fn apply_cors(headers: &mut HeaderMap, origin: Option<&str>, allowed: bool) {
    let Some(origin) = origin.filter(|_| allowed) else {
        return;
    };
    if let Ok(value) = HeaderValue::from_str(origin) {
        headers.insert(ACCESS_CONTROL_ALLOW_ORIGIN, value);
    }
    headers.insert(VARY, HeaderValue::from_static("Origin"));
    headers.insert(
        ACCESS_CONTROL_ALLOW_METHODS,
        HeaderValue::from_static("GET, POST, OPTIONS"),
    );
    headers.insert(
        ACCESS_CONTROL_ALLOW_HEADERS,
        HeaderValue::from_static("Authorization, Content-Type"),
    );
    headers.insert(
        ACCESS_CONTROL_EXPOSE_HEADERS,
        HeaderValue::from_static("Content-Disposition, Location"),
    );
    headers.insert(ACCESS_CONTROL_MAX_AGE, HeaderValue::from_static("600"));
}

async fn require_api_token(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    let is_ingest = request.method() == Method::POST && request.uri().path() == "/v1/sessions";
    if is_ingest {
        return if bearer_is_valid(request.headers(), &state.config.ingest_tokens) {
            next.run(request).await
        } else {
            unauthorized()
        };
    }
    if state.config.read_tokens.is_empty() {
        return error_response(
            StatusCode::FORBIDDEN,
            "read access is not configured on this relay",
        );
    }
    if bearer_is_valid(request.headers(), &state.config.read_tokens) {
        next.run(request).await
    } else {
        unauthorized()
    }
}

fn bearer_is_valid(headers: &HeaderMap, tokens: &[String]) -> bool {
    let Some(value) = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
    else {
        return false;
    };
    let Some((scheme, token)) = value.split_once(' ') else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("Bearer") || token.is_empty() {
        return false;
    }
    tokens.iter().fold(false, |matched, candidate| {
        matched | bool::from(token.as_bytes().ct_eq(candidate.as_bytes()))
    })
}

fn unauthorized() -> Response {
    let mut response = error_response(StatusCode::UNAUTHORIZED, "a valid bearer token is required");
    response
        .headers_mut()
        .insert(WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
    response
}

fn error_response(status: StatusCode, message: impl Into<String>) -> Response {
    (status, Json(json!({ "error": message.into() }))).into_response()
}

async fn ingest_session(State(state): State<AppState>, request: Request) -> Response {
    let is_zip = request
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value
                .split(';')
                .next()
                .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("application/zip"))
        });
    if !is_zip {
        return error_response(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "content type must be application/zip",
        );
    }

    let body = match to_bytes(request.into_body(), state.config.max_upload_bytes).await {
        Ok(body) => body,
        Err(_) => {
            return error_response(
                StatusCode::PAYLOAD_TOO_LARGE,
                "the upload exceeds the configured size limit",
            );
        }
    };
    if body.len() < 4 || &body[..2] != b"PK" {
        return error_response(StatusCode::BAD_REQUEST, "the body is not a ZIP archive");
    }

    let Ok(_permit) = state.compile_slots.clone().acquire_owned().await else {
        return error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "the relay is shutting down",
        );
    };

    let task_state = state.clone();
    let result = tokio::task::spawn_blocking(move || process_upload(&task_state, body)).await;
    match result {
        Ok(Ok(UploadOutcome::Created(metadata))) => {
            eprintln!(
                "compiled session {} ({} bytes)",
                metadata.session_id, metadata.bytes
            );
            spawn_session_webhook(state.config.clone(), &metadata);
            let location = metadata.status_url.clone();
            let mut response = (StatusCode::CREATED, Json(metadata)).into_response();
            if let Ok(value) = HeaderValue::from_str(&location) {
                response.headers_mut().insert(LOCATION, value);
            }
            response
        }
        Ok(Ok(UploadOutcome::Existing(metadata))) => {
            eprintln!("session {} was already compiled", metadata.session_id);
            spawn_session_webhook(state.config.clone(), &metadata);
            (StatusCode::OK, Json(metadata)).into_response()
        }
        Ok(Ok(UploadOutcome::Failed {
            metadata,
            status,
            message,
        })) => {
            spawn_session_webhook(state.config.clone(), &metadata);
            eprintln!("upload rejected: {message} ({status})");
            error_response(status, message)
        }
        Ok(Err(error)) => {
            eprintln!("upload rejected: {} ({})", error.message, error.status);
            error_response(error.status, error.message)
        }
        Err(error) => {
            eprintln!("relay worker failed: {error}");
            error_response(StatusCode::INTERNAL_SERVER_ERROR, "the relay worker failed")
        }
    }
}

fn spawn_session_webhook(config: Arc<RelayConfig>, metadata: &SessionMetadata) {
    let Some(delivery) = metadata.webhook.as_ref() else {
        return;
    };
    if delivery.status != WebhookStatus::Pending || config.webhook.is_none() {
        return;
    }
    let event = match metadata.status {
        SessionStatus::Ready => "session.ready",
        SessionStatus::Failed => "session.failed",
    };
    let metadata = metadata.clone();
    tokio::spawn(async move {
        deliver_webhook(config, metadata, event).await;
    });
}

async fn list_sessions(State(state): State<AppState>) -> Response {
    let data_dir = state.config.data_dir.clone();
    match tokio::task::spawn_blocking(move || collect_sessions(&data_dir)).await {
        Ok(Ok(sessions)) => (StatusCode::OK, Json(json!({ "sessions": sessions }))).into_response(),
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(error) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not list sessions: {error}"),
        ),
    }
}

fn collect_sessions(data_dir: &Path) -> Result<Vec<SessionMetadata>, String> {
    let directory = data_dir.join("sessions");
    let entries = fs::read_dir(&directory)
        .map_err(|error| format!("could not read {}: {error}", directory.display()))?;
    let mut sessions = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| format!("could not read a session record: {error}"))?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json")
            || path
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|name| name.starts_with('.'))
        {
            continue;
        }
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("could not read {}: {error}", path.display());
                continue;
            }
        };
        let mut metadata: SessionMetadata = match serde_json::from_slice(&bytes) {
            Ok(metadata) => metadata,
            Err(error) => {
                eprintln!("could not parse {}: {error}", path.display());
                continue;
            }
        };
        fill_session_details(data_dir, &mut metadata);
        sessions.push(metadata);
    }
    sessions.sort_by_key(|session| std::cmp::Reverse(session.received_at_ms));
    Ok(sessions)
}

/// Older records predate the page and duration fields; recover them from the bundle.
fn fill_session_details(data_dir: &Path, metadata: &mut SessionMetadata) {
    if metadata.page_title.is_some()
        && metadata.page_url.is_some()
        && metadata.duration_ms.is_some()
    {
        return;
    }
    let path = data_dir
        .join("bundles")
        .join(&metadata.session_id)
        .join("manifest.json");
    let Ok(bytes) = fs::read(&path) else {
        return;
    };
    let Ok(manifest) = serde_json::from_slice::<Value>(&bytes) else {
        return;
    };
    if metadata.page_title.is_none() {
        metadata.page_title = manifest["page"]["title"].as_str().map(str::to_owned);
    }
    if metadata.page_url.is_none() {
        metadata.page_url = manifest["page"]["initialUrl"].as_str().map(str::to_owned);
    }
    if metadata.duration_ms.is_none() {
        metadata.duration_ms = manifest["durationMs"].as_u64();
    }
}

async fn get_session(State(state): State<AppState>, RoutePath(id): RoutePath<String>) -> Response {
    let Some(id) = checked_session_id(&id) else {
        return error_response(StatusCode::NOT_FOUND, "session not found");
    };
    match read_metadata(&state.config.data_dir, &id) {
        Ok(metadata) => (StatusCode::OK, Json(metadata)).into_response(),
        Err(_) => error_response(StatusCode::NOT_FOUND, "session not found"),
    }
}

async fn get_bundle(State(state): State<AppState>, RoutePath(id): RoutePath<String>) -> Response {
    let Some(id) = checked_session_id(&id) else {
        return error_response(StatusCode::NOT_FOUND, "session not found");
    };
    let path = state
        .config
        .data_dir
        .join("downloads")
        .join(format!("{id}.zip"));
    let bytes = match tokio::fs::read(&path).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::NOT_FOUND, "bundle not found"),
    };
    let mut response = Body::from(bytes).into_response();
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));
    if let Ok(value) = HeaderValue::from_str(&format!("attachment; filename=\"highlite-{id}.zip\""))
    {
        response.headers_mut().insert(CONTENT_DISPOSITION, value);
    }
    response
}

async fn list_pipelines(State(state): State<AppState>) -> Response {
    let pipelines: Vec<Value> = state
        .pipelines
        .iter()
        .map(|pipeline| {
            json!({
                "name": pipeline.name,
                "description": pipeline.description,
                "timeoutSeconds": pipeline.timeout_seconds,
            })
        })
        .collect();
    Json(json!({
        "enabled": state.config.allow_pipelines,
        "pipelines": pipelines,
    }))
    .into_response()
}

async fn start_pipeline(
    State(state): State<AppState>,
    RoutePath((id, name)): RoutePath<(String, String)>,
) -> Response {
    let Some(session_id) = checked_session_id(&id) else {
        return error_response(StatusCode::NOT_FOUND, "session not found");
    };
    let metadata = match read_metadata(&state.config.data_dir, &session_id) {
        Ok(metadata) => metadata,
        Err(_) => return error_response(StatusCode::NOT_FOUND, "session not found"),
    };
    if metadata.status != SessionStatus::Ready {
        return error_response(StatusCode::CONFLICT, "session is not ready");
    }
    let Some(pipeline) = state
        .pipelines
        .iter()
        .find(|pipeline| pipeline.name == name)
        .cloned()
    else {
        return error_response(StatusCode::NOT_FOUND, "pipeline not found");
    };
    let bundle_dir = state.config.data_dir.join("bundles").join(&session_id);
    if !bundle_dir.is_dir() {
        return error_response(StatusCode::CONFLICT, "the session bundle is missing");
    }

    let run = PipelineRun {
        run_id: temp_name("run"),
        session_id: session_id.clone(),
        pipeline: pipeline.name.clone(),
        status: PipelineRunStatus::Queued,
        created_at_ms: now_ms(),
        finished_at_ms: None,
        exit_code: None,
        stdout: None,
        stderr: None,
        error: None,
    };
    if let Err(error) = write_run(&state.config.data_dir, &run) {
        return error_response(error.status, error.message);
    }

    let location = format!("/v1/runs/{}", run.run_id);
    let task_state = state.clone();
    let task_run = run.clone();
    tokio::spawn(async move {
        execute_run(task_state, task_run, pipeline).await;
    });

    let mut response = (StatusCode::ACCEPTED, Json(run)).into_response();
    if let Ok(value) = HeaderValue::from_str(&location) {
        response.headers_mut().insert(LOCATION, value);
    }
    response
}

async fn get_run(State(state): State<AppState>, RoutePath(id): RoutePath<String>) -> Response {
    let Some(id) = checked_session_id(&id) else {
        return error_response(StatusCode::NOT_FOUND, "run not found");
    };
    match read_run(&state.config.data_dir, &id) {
        Ok(run) => (StatusCode::OK, Json(run)).into_response(),
        Err(_) => error_response(StatusCode::NOT_FOUND, "run not found"),
    }
}

async fn list_session_runs(
    State(state): State<AppState>,
    RoutePath(id): RoutePath<String>,
) -> Response {
    let Some(session_id) = checked_session_id(&id) else {
        return error_response(StatusCode::NOT_FOUND, "session not found");
    };
    let data_dir = state.config.data_dir.clone();
    match tokio::task::spawn_blocking(move || collect_runs(&data_dir, Some(&session_id))).await {
        Ok(runs) => (StatusCode::OK, Json(json!({ "runs": runs }))).into_response(),
        Err(error) => error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not list runs: {error}"),
        ),
    }
}

async fn execute_run(state: AppState, mut run: PipelineRun, pipeline: Pipeline) {
    let Ok(_permit) = state.run_slots.clone().acquire_owned().await else {
        run.status = PipelineRunStatus::Failed;
        run.finished_at_ms = Some(now_ms());
        run.error = Some("the relay is shutting down".to_owned());
        persist_run(&state.config.data_dir, &run);
        return;
    };

    run.status = PipelineRunStatus::Running;
    persist_run(&state.config.data_dir, &run);

    let outcome = run_command(&state, &pipeline, &run).await;
    run.status = outcome.status;
    run.finished_at_ms = Some(now_ms());
    run.exit_code = outcome.exit_code;
    run.stdout = Some(outcome.stdout);
    run.stderr = Some(outcome.stderr);
    run.error = outcome.error;
    persist_run(&state.config.data_dir, &run);
}

fn persist_run(data_dir: &Path, run: &PipelineRun) {
    if let Err(error) = write_run(data_dir, run) {
        eprintln!("could not persist run {}: {}", run.run_id, error.message);
    }
}

struct CommandOutcome {
    status: PipelineRunStatus,
    exit_code: Option<i32>,
    stdout: String,
    stderr: String,
    error: Option<String>,
}

async fn run_command(state: &AppState, pipeline: &Pipeline, run: &PipelineRun) -> CommandOutcome {
    let data_dir = absolute_path(&state.config.data_dir);
    let bundle_dir = data_dir.join("bundles").join(&run.session_id);
    let cwd = pipeline
        .cwd
        .as_ref()
        .map(|cwd| absolute_path(cwd))
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));

    let mut command = shell_command(&pipeline.command);
    command
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("HIGHLITE_SESSION_ID", &run.session_id)
        .env("HIGHLITE_RUN_ID", &run.run_id)
        .env("HIGHLITE_BUNDLE_DIR", &bundle_dir)
        .env(
            "HIGHLITE_BUNDLE_ZIP",
            data_dir
                .join("downloads")
                .join(format!("{}.zip", run.session_id)),
        )
        .env("HIGHLITE_SUMMARY_PATH", bundle_dir.join("summary.md"))
        .env("HIGHLITE_MANIFEST_PATH", bundle_dir.join("manifest.json"))
        .env("HIGHLITE_BUNDLE_JSON", bundle_dir.join("bundle.json"))
        .env("HIGHLITE_SCRAWL_JSON", bundle_dir.join("scrawl.json"))
        .env("HIGHLITE_ANALYSIS_JSON", bundle_dir.join("analysis.json"));
    for (name, value) in &pipeline.env {
        command.env(name, value);
    }
    for name in [
        "HIGHLITE_RELAY_INGEST_TOKEN",
        "HIGHLITE_RELAY_READ_TOKEN",
        "HIGHLITE_RELAY_WEBHOOK_SECRET",
    ] {
        command.env_remove(name);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return CommandOutcome {
                status: PipelineRunStatus::Failed,
                exit_code: None,
                stdout: String::new(),
                stderr: String::new(),
                error: Some(format!("could not start the pipeline command: {error}")),
            };
        }
    };
    let stdout_task = tokio::spawn(read_stream(child.stdout.take()));
    let stderr_task = tokio::spawn(read_stream(child.stderr.take()));

    let mut error = None;
    let exit_status =
        match tokio::time::timeout(Duration::from_secs(pipeline.timeout_seconds), child.wait())
            .await
        {
            Ok(Ok(status)) => Some(status),
            Ok(Err(wait_error)) => {
                error = Some(format!(
                    "could not wait for the pipeline command: {wait_error}"
                ));
                None
            }
            Err(_) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                error = Some(format!(
                    "pipeline timed out after {} second(s)",
                    pipeline.timeout_seconds
                ));
                None
            }
        };

    let stdout = truncate_output(stdout_task.await.unwrap_or_default());
    let stderr = truncate_output(stderr_task.await.unwrap_or_default());
    let exit_code = exit_status.and_then(|status| status.code());
    let succeeded = error.is_none() && exit_status.is_some_and(|status| status.success());

    CommandOutcome {
        status: if succeeded {
            PipelineRunStatus::Succeeded
        } else {
            PipelineRunStatus::Failed
        },
        exit_code,
        stdout,
        stderr,
        error,
    }
}

async fn read_stream<R>(reader: Option<R>) -> Vec<u8>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut bytes = Vec::new();
    if let Some(mut reader) = reader {
        let _ = reader.read_to_end(&mut bytes).await;
    }
    bytes
}

fn truncate_output(bytes: Vec<u8>) -> String {
    if bytes.len() <= MAX_RUN_OUTPUT_BYTES {
        return String::from_utf8_lossy(&bytes).into_owned();
    }
    let mut output = String::from_utf8_lossy(&bytes[..MAX_RUN_OUTPUT_BYTES]).into_owned();
    output.push_str("\n… output truncated");
    output
}

fn shell_command(script: &str) -> Command {
    #[cfg(windows)]
    {
        let mut command = Command::new("cmd");
        command.arg("/C").arg(script);
        command
    }
    #[cfg(not(windows))]
    {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script);
        command
    }
}

fn absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        return path.to_owned();
    }
    std::env::current_dir()
        .map(|cwd| cwd.join(path))
        .unwrap_or_else(|_| path.to_owned())
}

fn write_run(data_dir: &Path, run: &PipelineRun) -> Result<(), UploadError> {
    let directory = data_dir.join("runs");
    let path = directory.join(format!("{}.json", run.run_id));
    let temporary = directory.join(format!(".{}.json.tmp", run.run_id));
    let json = serde_json::to_vec_pretty(run)
        .map_err(|error| UploadError::internal(format!("could not serialize the run: {error}")))?;
    fs::write(&temporary, json)
        .map_err(|error| UploadError::internal(format!("could not write the run: {error}")))?;
    fs::rename(&temporary, &path)
        .map_err(|error| UploadError::internal(format!("could not store the run: {error}")))?;
    Ok(())
}

fn read_run(data_dir: &Path, id: &str) -> Result<PipelineRun, UploadError> {
    let path = data_dir.join("runs").join(format!("{id}.json"));
    let bytes =
        fs::read(&path).map_err(|_| UploadError::new(StatusCode::NOT_FOUND, "run not found"))?;
    serde_json::from_slice(&bytes)
        .map_err(|error| UploadError::internal(format!("invalid stored run: {error}")))
}

fn collect_runs(data_dir: &Path, session_id: Option<&str>) -> Vec<PipelineRun> {
    let directory = data_dir.join("runs");
    let Ok(entries) = fs::read_dir(&directory) else {
        return Vec::new();
    };
    let mut runs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json")
            || path
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|name| name.starts_with('.'))
        {
            continue;
        }
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        let Ok(run) = serde_json::from_slice::<PipelineRun>(&bytes) else {
            continue;
        };
        if session_id.is_none_or(|id| run.session_id == id) {
            runs.push(run);
        }
    }
    runs.sort_by_key(|run| std::cmp::Reverse(run.created_at_ms));
    runs
}

fn process_upload(state: &AppState, bytes: Bytes) -> Result<UploadOutcome, UploadError> {
    let (capture, manifest) = extract_capture(&state.config, &bytes)?;
    let session_id = manifest.session_id.clone();

    if let Ok(existing) = read_metadata(&state.config.data_dir, &session_id)
        && existing.status == SessionStatus::Ready
    {
        return Ok(UploadOutcome::Existing(existing));
    }

    let _in_flight = match state.in_flight.lock() {
        Ok(mut set) => {
            if !set.insert(session_id.clone()) {
                return Err(UploadError::new(
                    StatusCode::CONFLICT,
                    "this session is already being processed",
                ));
            }
            InFlightGuard {
                set: state.in_flight.clone(),
                id: session_id.clone(),
            }
        }
        Err(_) => {
            return Err(UploadError::internal(
                "the relay could not track the upload",
            ));
        }
    };

    if state.config.keep_uploads {
        let raw_path = state
            .config
            .data_dir
            .join("uploads")
            .join(format!("{session_id}.zip"));
        fs::write(&raw_path, &bytes).map_err(|error| {
            UploadError::internal(format!("could not retain the uploaded archive: {error}"))
        })?;
    }

    let received_at_ms = now_ms();
    let bundle_dir = state.config.data_dir.join("bundles").join(&session_id);
    let download_path = state
        .config
        .data_dir
        .join("downloads")
        .join(format!("{session_id}.zip"));
    let _ = fs::remove_dir_all(&bundle_dir);
    let _ = fs::remove_file(&download_path);

    match compile_upload(state, &manifest, &capture.path, &bundle_dir, &download_path) {
        Ok(summary) => {
            let metadata = SessionMetadata {
                session_id: session_id.clone(),
                status: SessionStatus::Ready,
                received_at_ms,
                bytes: bytes.len() as u64,
                page_title: Some(manifest.page.title.clone()),
                page_url: Some(manifest.page.initial_url.clone()),
                duration_ms: Some(manifest.duration_ms),
                summary: Some(summary),
                error: None,
                webhook: new_webhook_delivery(&state.config),
                status_url: format!("/v1/sessions/{session_id}"),
                bundle_url: format!("/v1/sessions/{session_id}/bundle.zip"),
            };
            write_metadata(&state.config.data_dir, &metadata)?;
            Ok(UploadOutcome::Created(metadata))
        }
        Err(error) => {
            let _ = fs::remove_dir_all(&bundle_dir);
            let _ = fs::remove_file(&download_path);
            let metadata = SessionMetadata {
                session_id: session_id.clone(),
                status: SessionStatus::Failed,
                received_at_ms,
                bytes: bytes.len() as u64,
                page_title: Some(manifest.page.title.clone()),
                page_url: Some(manifest.page.initial_url.clone()),
                duration_ms: Some(manifest.duration_ms),
                summary: None,
                error: Some(error.message.clone()),
                webhook: new_webhook_delivery(&state.config),
                status_url: format!("/v1/sessions/{session_id}"),
                bundle_url: format!("/v1/sessions/{session_id}/bundle.zip"),
            };
            let _ = write_metadata(&state.config.data_dir, &metadata);
            Ok(UploadOutcome::Failed {
                metadata,
                status: error.status,
                message: error.message,
            })
        }
    }
}

fn new_webhook_delivery(config: &RelayConfig) -> Option<WebhookDelivery> {
    config.webhook.as_ref().map(|_| WebhookDelivery {
        delivery_id: temp_name("webhook"),
        status: WebhookStatus::Pending,
        attempts: 0,
        last_error: None,
        delivered_at_ms: None,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WebhookPayload<'a> {
    event: &'a str,
    delivery_id: &'a str,
    occurred_at_ms: u64,
    session_id: &'a str,
    session: &'a SessionMetadata,
}

async fn deliver_webhook(config: Arc<RelayConfig>, metadata: SessionMetadata, event: &'static str) {
    let Some(webhook) = config.webhook.as_ref() else {
        return;
    };
    let Some(mut delivery) = metadata.webhook.clone() else {
        return;
    };
    if delivery.status != WebhookStatus::Pending {
        return;
    }
    let mut session = metadata.clone();
    session.webhook = None;
    let payload = WebhookPayload {
        event,
        delivery_id: &delivery.delivery_id,
        occurred_at_ms: now_ms(),
        session_id: &metadata.session_id,
        session: &session,
    };
    let body = match serde_json::to_vec(&payload) {
        Ok(body) => body,
        Err(error) => {
            eprintln!(
                "webhook payload for {} failed: {error}",
                metadata.session_id
            );
            return;
        }
    };
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_millis(webhook.timeout_ms))
        .redirect(Policy::none())
        .user_agent(format!("highlite-relay/{}", env!("CARGO_PKG_VERSION")))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            eprintln!("webhook client for {} failed: {error}", metadata.session_id);
            return;
        }
    };

    let mut metadata = metadata;
    if delivery.attempts >= webhook.max_attempts {
        delivery.status = WebhookStatus::Failed;
        delivery.last_error = Some("webhook delivery attempts exhausted".to_owned());
        persist_webhook(&config.data_dir, &mut metadata, &delivery);
        return;
    }

    loop {
        let timestamp = (now_ms() / 1000).to_string();
        let signature = webhook_signature(&webhook.secret, &timestamp, &body);
        delivery.attempts += 1;
        persist_webhook(&config.data_dir, &mut metadata, &delivery);

        let retryable = match client
            .post(&webhook.url)
            .header(CONTENT_TYPE, "application/json")
            .header("X-Highlite-Event", event)
            .header("X-Highlite-Delivery", &delivery.delivery_id)
            .header("X-Highlite-Timestamp", &timestamp)
            .header("X-Highlite-Signature", format!("sha256={signature}"))
            .body(body.clone())
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => {
                delivery.status = WebhookStatus::Delivered;
                delivery.delivered_at_ms = Some(now_ms());
                delivery.last_error = None;
                persist_webhook(&config.data_dir, &mut metadata, &delivery);
                eprintln!(
                    "webhook for {} delivered on attempt {}",
                    metadata.session_id, delivery.attempts
                );
                return;
            }
            Ok(response) => {
                let status = response.status();
                delivery.last_error = Some(format!("webhook returned HTTP {status}"));
                status == StatusCode::REQUEST_TIMEOUT
                    || status == StatusCode::TOO_MANY_REQUESTS
                    || status.is_server_error()
            }
            Err(error) => {
                delivery.last_error = Some(error.to_string());
                true
            }
        };

        if !retryable || delivery.attempts >= webhook.max_attempts {
            delivery.status = WebhookStatus::Failed;
            persist_webhook(&config.data_dir, &mut metadata, &delivery);
            eprintln!(
                "webhook for {} failed after {} attempt(s): {}",
                metadata.session_id,
                delivery.attempts,
                delivery.last_error.as_deref().unwrap_or("unknown error")
            );
            return;
        }

        persist_webhook(&config.data_dir, &mut metadata, &delivery);
        tokio::time::sleep(retry_delay(delivery.attempts)).await;
    }
}

fn persist_webhook(data_dir: &Path, metadata: &mut SessionMetadata, delivery: &WebhookDelivery) {
    metadata.webhook = Some(delivery.clone());
    if let Err(error) = write_metadata(data_dir, metadata) {
        eprintln!(
            "could not persist webhook state for {}: {}",
            metadata.session_id, error.message
        );
    }
}

fn retry_delay(attempt: u32) -> Duration {
    let factor = 1u64 << attempt.saturating_sub(1).min(4);
    Duration::from_millis(500 * factor)
}

fn webhook_signature(secret: &str, timestamp: &str, body: &[u8]) -> String {
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts keys of any length");
    mac.update(timestamp.as_bytes());
    mac.update(b".");
    mac.update(body);
    hex_lower(&mac.finalize().into_bytes())
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

/// Retry webhook deliveries that were still pending when the relay stopped.
pub async fn resume_pending_webhooks(config: RelayConfig) -> Result<usize, String> {
    if config.webhook.is_none() {
        return Ok(0);
    }
    let directory = config.data_dir.join("sessions");
    let entries = fs::read_dir(&directory)
        .map_err(|error| format!("could not read {}: {error}", directory.display()))?;
    let config = Arc::new(config);
    let mut resumed = 0usize;
    for entry in entries {
        let entry = entry.map_err(|error| format!("could not read a session record: {error}"))?;
        if entry.path().extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let bytes = match fs::read(entry.path()) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!(
                    "could not read pending webhook metadata {}: {error}",
                    entry.path().display()
                );
                continue;
            }
        };
        let metadata: SessionMetadata = match serde_json::from_slice(&bytes) {
            Ok(metadata) => metadata,
            Err(error) => {
                eprintln!(
                    "could not parse pending webhook metadata {}: {error}",
                    entry.path().display()
                );
                continue;
            }
        };
        if !metadata
            .webhook
            .as_ref()
            .is_some_and(|delivery| delivery.status == WebhookStatus::Pending)
        {
            continue;
        }
        let event = match metadata.status {
            SessionStatus::Ready => "session.ready",
            SessionStatus::Failed => "session.failed",
        };
        let config = config.clone();
        tokio::spawn(async move {
            deliver_webhook(config, metadata, event).await;
        });
        resumed += 1;
    }
    Ok(resumed)
}

fn compile_upload(
    state: &AppState,
    manifest: &HighliteManifest,
    capture_dir: &Path,
    bundle_dir: &Path,
    download_path: &Path,
) -> Result<String, UploadError> {
    let mut manifest = manifest.clone();
    if manifest.transcript.is_empty()
        && let Some(audio) = manifest.artifacts.audio.as_deref()
    {
        let audio_path = resolve_capture_path(capture_dir, audio)
            .map_err(|error| UploadError::unprocessable(error.to_string()))?;
        match state.config.transcriber_command.as_deref() {
            Some(command) => {
                let transcriber = CommandTranscriber::new(command)
                    .map_err(|error| UploadError::unprocessable(error.to_string()))?;
                let segments = transcriber
                    .transcribe(&TranscriptionRequest {
                        audio_path: &audio_path,
                        language: state.config.language.as_deref(),
                    })
                    .map_err(|error| UploadError::unprocessable(error.to_string()))?;
                manifest.transcript = shift_transcript(
                    segments,
                    manifest.audio_offset_ms.unwrap_or(0),
                    manifest.duration_ms,
                );
            }
            None => push_unique_warning(
                &mut manifest.capture_warnings,
                "Narration was not transcribed by the relay.",
            ),
        }
    }

    let input = CompileInput {
        manifest,
        frames: None,
        viewport: None,
        options: Some(state.config.compile.clone()),
    };
    let mut compiled = compile_capture(&input);
    let written = write_bundle(&mut compiled, capture_dir, bundle_dir, &state.config.bundle)
        .map_err(|error| UploadError::unprocessable(error.to_string()))?;
    zip_directory(bundle_dir, download_path).map_err(|error| {
        UploadError::internal(format!("could not package the compiled bundle: {error}"))
    })?;
    Ok(written.summary)
}

fn push_unique_warning(warnings: &mut Vec<String>, message: &str) {
    if !warnings.iter().any(|warning| warning == message) {
        warnings.push(message.to_owned());
    }
}

fn extract_capture(
    config: &RelayConfig,
    bytes: &[u8],
) -> Result<(TempCapture, HighliteManifest), UploadError> {
    let path = config.data_dir.join("inbox").join(temp_name("capture"));
    fs::create_dir_all(&path)
        .map_err(|error| UploadError::internal(format!("could not create inbox: {error}")))?;
    let capture = TempCapture { path };

    let mut archive = ZipArchive::new(Cursor::new(bytes))
        .map_err(|error| UploadError::bad_request(format!("invalid ZIP archive: {error}")))?;
    if archive.len() > config.max_files.saturating_mul(2).saturating_add(1024) {
        return Err(UploadError::bad_request("the archive has too many entries"));
    }
    let mut files = 0usize;
    let mut extracted = 0u64;
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| UploadError::bad_request(format!("invalid ZIP entry: {error}")))?;
        if entry.is_dir() {
            continue;
        }
        files += 1;
        if files > config.max_files {
            return Err(UploadError::bad_request("the archive has too many files"));
        }
        let Some(relative) = entry.enclosed_name() else {
            return Err(UploadError::bad_request(
                "the archive contains an unsafe file path",
            ));
        };
        if !safe_relative_path(&relative) {
            return Err(UploadError::bad_request(
                "the archive contains an unsafe file path",
            ));
        }
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err(UploadError::bad_request(
                "the archive contains a symbolic link",
            ));
        }
        let remaining = config.max_uncompressed_bytes.saturating_sub(extracted);
        if remaining == 0 {
            return Err(UploadError::bad_request(
                "the archive exceeds the uncompressed size limit",
            ));
        }

        let destination = capture.path.join(&relative);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                UploadError::internal(format!("could not create extraction directory: {error}"))
            })?;
        }
        let mut output = fs::File::create(&destination).map_err(|error| {
            UploadError::internal(format!("could not write an extracted file: {error}"))
        })?;
        let copied = io::copy(
            &mut (&mut entry).take(remaining.saturating_add(1)),
            &mut output,
        )
        .map_err(|error| {
            UploadError::internal(format!("could not extract an archive entry: {error}"))
        })?;
        if copied > remaining {
            return Err(UploadError::bad_request(
                "the archive exceeds the uncompressed size limit",
            ));
        }
        extracted = extracted.saturating_add(copied);
    }

    let manifest_path = capture.path.join("manifest.json");
    let manifest_bytes = fs::read(&manifest_path).map_err(|_| {
        UploadError::bad_request("the archive must contain a manifest.json at its root")
    })?;
    let manifest: HighliteManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|error| UploadError::bad_request(format!("invalid manifest.json: {error}")))?;
    if manifest.schema_version != MANIFEST_SCHEMA_VERSION {
        return Err(UploadError::unprocessable(format!(
            "unsupported manifest schema version {}",
            manifest.schema_version
        )));
    }
    checked_session_id(&manifest.session_id)
        .ok_or_else(|| UploadError::bad_request("manifest.json has an invalid sessionId"))?;
    Ok((capture, manifest))
}

fn safe_relative_path(path: &Path) -> bool {
    let mut components = 0usize;
    for component in path.components() {
        components += 1;
        if components > MAX_PATH_COMPONENTS || !matches!(component, Component::Normal(_)) {
            return false;
        }
    }
    components > 0
}

fn checked_session_id(id: &str) -> Option<String> {
    let mut chars = id.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphanumeric() || id.len() > 128 {
        return None;
    }
    if id
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.'))
        && !id.contains("..")
    {
        Some(id.to_owned())
    } else {
        None
    }
}

fn temp_name(prefix: &str) -> String {
    let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}-{}-{}-{counter}", std::process::id(), now_ms())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn write_metadata(data_dir: &Path, metadata: &SessionMetadata) -> Result<(), UploadError> {
    let directory = data_dir.join("sessions");
    let path = directory.join(format!("{}.json", metadata.session_id));
    let temporary = directory.join(format!(".{}.json.tmp", metadata.session_id));
    let json = serde_json::to_vec_pretty(metadata)
        .map_err(|error| UploadError::internal(format!("could not serialize metadata: {error}")))?;
    fs::write(&temporary, json)
        .map_err(|error| UploadError::internal(format!("could not write metadata: {error}")))?;
    fs::rename(&temporary, &path)
        .map_err(|error| UploadError::internal(format!("could not store metadata: {error}")))?;
    Ok(())
}

fn read_metadata(data_dir: &Path, id: &str) -> Result<SessionMetadata, UploadError> {
    let path = data_dir.join("sessions").join(format!("{id}.json"));
    let bytes = fs::read(&path)
        .map_err(|_| UploadError::new(StatusCode::NOT_FOUND, "session not found"))?;
    serde_json::from_slice(&bytes)
        .map_err(|error| UploadError::internal(format!("invalid stored metadata: {error}")))
}

fn zip_directory(directory: &Path, destination: &Path) -> io::Result<()> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = fs::File::create(destination)?;
    let mut writer = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    add_directory(&mut writer, directory, directory, options)?;
    writer.finish()?;
    Ok(())
}

fn add_directory(
    writer: &mut ZipWriter<fs::File>,
    root: &Path,
    directory: &Path,
    options: SimpleFileOptions,
) -> io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            add_directory(writer, root, &path, options)?;
        } else if file_type.is_file() {
            let relative = path
                .strip_prefix(root)
                .map_err(|_| io::Error::other("bundle file escaped its directory"))?;
            let name = relative.to_string_lossy().replace('\\', "/");
            writer.start_file(name, options)?;
            let mut source = fs::File::open(&path)?;
            io::copy(&mut source, writer)?;
        }
    }
    Ok(())
}

fn load_pipelines(config: &RelayConfig) -> Result<Vec<Pipeline>, String> {
    if !config.allow_pipelines {
        return Ok(Vec::new());
    }
    let path = config
        .pipelines_file
        .clone()
        .unwrap_or_else(|| config.data_dir.join("pipelines.json"));
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            eprintln!(
                "note: pipelines are enabled but {} does not exist; no pipelines are available.",
                path.display()
            );
            return Ok(Vec::new());
        }
        Err(error) => {
            return Err(format!("could not read {}: {error}", path.display()));
        }
    };
    let file: PipelinesFile = serde_json::from_slice(&bytes)
        .map_err(|error| format!("invalid pipelines file {}: {error}", path.display()))?;
    let mut seen = std::collections::HashSet::new();
    for pipeline in &file.pipelines {
        validate_pipeline(pipeline)?;
        if !seen.insert(pipeline.name.as_str()) {
            return Err(format!(
                "duplicate pipeline name {:?} in {}",
                pipeline.name,
                path.display()
            ));
        }
    }
    Ok(file.pipelines)
}

fn validate_pipeline(pipeline: &Pipeline) -> Result<(), String> {
    let name = pipeline.name.as_str();
    if name.is_empty()
        || name.len() > 64
        || !name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        return Err(
            "pipeline names must be 1-64 characters using letters, digits, '-' or '_'".to_owned(),
        );
    }
    if pipeline.command.trim().is_empty() {
        return Err(format!("pipeline {:?} has an empty command", pipeline.name));
    }
    if pipeline.timeout_seconds == 0 {
        return Err(format!(
            "pipeline {:?} must use a timeout of at least 1 second",
            pipeline.name
        ));
    }
    Ok(())
}

fn bind_is_loopback(bind: &str) -> bool {
    let host = if let Some(rest) = bind.strip_prefix('[') {
        rest.split(']').next().unwrap_or_default()
    } else {
        bind.rsplit_once(':').map(|(host, _)| host).unwrap_or(bind)
    };
    host.eq_ignore_ascii_case("localhost") || host == "::1" || host.starts_with("127.")
}

/// Parse relay CLI arguments into a validated configuration.
pub fn config_from_args(args: &[String]) -> Result<RelayConfig, String> {
    let mut env_files: Vec<PathBuf> = Vec::new();
    let mut bind_override: Option<String> = None;
    let mut data_dir_override: Option<PathBuf> = None;
    let mut ui_override: Option<bool> = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--env-file" => {
                index += 1;
                let path = args
                    .get(index)
                    .ok_or_else(|| "--env-file needs a value".to_owned())?;
                env_files.push(PathBuf::from(path));
            }
            "--bind" => {
                index += 1;
                bind_override = Some(
                    args.get(index)
                        .cloned()
                        .ok_or_else(|| "--bind needs a value".to_owned())?,
                );
            }
            "--data-dir" => {
                index += 1;
                data_dir_override = Some(PathBuf::from(
                    args.get(index)
                        .cloned()
                        .ok_or_else(|| "--data-dir needs a value".to_owned())?,
                ));
            }
            "--ui" => ui_override = Some(true),
            flag if flag.starts_with('-') => {
                return Err(format!(
                    "unknown option: {flag}; put relay settings in an env file and pass --env-file"
                ));
            }
            argument => return Err(format!("unexpected argument: {argument}")),
        }
        index += 1;
    }

    if env_files.is_empty()
        && let Ok(path) = std::env::var("HIGHLITE_RELAY_ENV_FILE")
        && !path.trim().is_empty()
    {
        env_files.push(PathBuf::from(path));
    }
    let mut values = load_env_files(&env_files)?;
    for (name, value) in std::env::vars() {
        if name.starts_with("HIGHLITE_RELAY_") || name == "HIGHLITE_ASR_COMMAND" {
            values.insert(name, value);
        }
    }
    config_from_values(values, bind_override, data_dir_override, ui_override)
}

fn config_from_values(
    values: HashMap<String, String>,
    bind_override: Option<String>,
    data_dir_override: Option<PathBuf>,
    ui_override: Option<bool>,
) -> Result<RelayConfig, String> {
    let lookup = |name: &str| values.get(name).cloned();
    let bind = bind_override
        .or_else(|| lookup("HIGHLITE_RELAY_BIND"))
        .unwrap_or_else(|| "127.0.0.1:8787".to_owned());
    let data_dir = data_dir_override.unwrap_or_else(|| {
        PathBuf::from(
            lookup("HIGHLITE_RELAY_DATA_DIR").unwrap_or_else(|| "./highlite-relay-data".to_owned()),
        )
    });
    let max_upload_mb = env_number(
        lookup("HIGHLITE_RELAY_MAX_UPLOAD_MB"),
        "HIGHLITE_RELAY_MAX_UPLOAD_MB",
        64,
    )?;
    let max_uncompressed_mb = env_number(
        lookup("HIGHLITE_RELAY_MAX_UNCOMPRESSED_MB"),
        "HIGHLITE_RELAY_MAX_UNCOMPRESSED_MB",
        256,
    )?;
    let max_files = env_number(
        lookup("HIGHLITE_RELAY_MAX_FILES"),
        "HIGHLITE_RELAY_MAX_FILES",
        2_000,
    )?;
    let concurrency = env_number(
        lookup("HIGHLITE_RELAY_CONCURRENCY"),
        "HIGHLITE_RELAY_CONCURRENCY",
        2,
    )?;
    let webhook_timeout_seconds = env_number(
        lookup("HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS"),
        "HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS",
        5,
    )?;
    let webhook_attempts = env_number(
        lookup("HIGHLITE_RELAY_WEBHOOK_ATTEMPTS"),
        "HIGHLITE_RELAY_WEBHOOK_ATTEMPTS",
        3,
    )?;
    let keep_uploads = env_bool(
        lookup("HIGHLITE_RELAY_KEEP_UPLOADS"),
        "HIGHLITE_RELAY_KEEP_UPLOADS",
        false,
    )?;
    let ui = match ui_override {
        Some(value) => value,
        None => env_bool(lookup("HIGHLITE_RELAY_UI"), "HIGHLITE_RELAY_UI", false)?,
    };
    let allow_pipelines = env_bool(
        lookup("HIGHLITE_RELAY_ALLOW_PIPELINES"),
        "HIGHLITE_RELAY_ALLOW_PIPELINES",
        false,
    )?;
    let pipelines_file = lookup("HIGHLITE_RELAY_PIPELINES_FILE")
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from);
    let pipeline_concurrency = env_number(
        lookup("HIGHLITE_RELAY_PIPELINE_CONCURRENCY"),
        "HIGHLITE_RELAY_PIPELINE_CONCURRENCY",
        2,
    )?;
    let transcriber_command =
        lookup("HIGHLITE_RELAY_TRANSCRIBER_COMMAND").or_else(|| lookup("HIGHLITE_ASR_COMMAND"));
    let compile = CompileOptions {
        max_keyframes: env_optional_u32(
            lookup("HIGHLITE_RELAY_MAX_KEYFRAMES"),
            "HIGHLITE_RELAY_MAX_KEYFRAMES",
        )?,
        min_gap_ms: env_optional_number(
            lookup("HIGHLITE_RELAY_MIN_GAP_MS"),
            "HIGHLITE_RELAY_MIN_GAP_MS",
        )?,
        clause_gap_ms: env_optional_number(
            lookup("HIGHLITE_RELAY_CLAUSE_GAP_MS"),
            "HIGHLITE_RELAY_CLAUSE_GAP_MS",
        )?,
        crop_padding_px: env_optional_float(
            lookup("HIGHLITE_RELAY_CROP_PADDING_PX"),
            "HIGHLITE_RELAY_CROP_PADDING_PX",
        )?,
        crop: env_optional_bool(lookup("HIGHLITE_RELAY_CROP"), "HIGHLITE_RELAY_CROP")?,
        coverage: env_optional_bool(lookup("HIGHLITE_RELAY_COVERAGE"), "HIGHLITE_RELAY_COVERAGE")?,
        speech_cues: env_optional_bool(
            lookup("HIGHLITE_RELAY_SPEECH_CUES"),
            "HIGHLITE_RELAY_SPEECH_CUES",
        )?,
        cue_window_ms: env_optional_number(
            lookup("HIGHLITE_RELAY_CUE_WINDOW_MS"),
            "HIGHLITE_RELAY_CUE_WINDOW_MS",
        )?,
        compiled_at: None,
    };
    let bundle = BundleOptions {
        annotations: env_bool(
            lookup("HIGHLITE_RELAY_BURN_ANNOTATIONS"),
            "HIGHLITE_RELAY_BURN_ANNOTATIONS",
            true,
        )?,
        contact_sheet: env_bool(
            lookup("HIGHLITE_RELAY_CONTACT_SHEET"),
            "HIGHLITE_RELAY_CONTACT_SHEET",
            true,
        )?,
        contact_sheet_width: env_u32(
            lookup("HIGHLITE_RELAY_CONTACT_SHEET_WIDTH"),
            "HIGHLITE_RELAY_CONTACT_SHEET_WIDTH",
            1600,
        )?,
    };

    let mut config = RelayConfig {
        bind,
        data_dir,
        ingest_tokens: split_list(lookup("HIGHLITE_RELAY_INGEST_TOKEN")),
        read_tokens: split_list(lookup("HIGHLITE_RELAY_READ_TOKEN")),
        allowed_hosts: split_list(lookup("HIGHLITE_RELAY_ALLOWED_HOSTS")),
        allowed_origins: split_list(lookup("HIGHLITE_RELAY_ALLOWED_ORIGINS")),
        max_upload_bytes: usize::try_from(max_upload_mb)
            .unwrap_or(usize::MAX)
            .saturating_mul(1024 * 1024),
        max_uncompressed_bytes: max_uncompressed_mb.saturating_mul(1024 * 1024),
        max_files: usize::try_from(max_files).unwrap_or(usize::MAX),
        concurrency: usize::try_from(concurrency).unwrap_or(usize::MAX),
        transcriber_command,
        language: lookup("HIGHLITE_RELAY_LANGUAGE"),
        keep_uploads,
        ui,
        allow_pipelines,
        pipelines_file,
        pipeline_concurrency: usize::try_from(pipeline_concurrency).unwrap_or(usize::MAX),
        compile,
        bundle,
        webhook: None,
    };
    config.allowed_hosts = normalize_list(config.allowed_hosts);
    config.allowed_origins = normalize_list(config.allowed_origins);
    if config.allowed_hosts.is_empty() {
        config.allowed_hosts = default_hosts_from_bind(&config.bind);
    }
    config.webhook = build_webhook_config(
        lookup("HIGHLITE_RELAY_WEBHOOK_URL"),
        lookup("HIGHLITE_RELAY_WEBHOOK_SECRET"),
        webhook_timeout_seconds,
        u32::try_from(webhook_attempts).unwrap_or(u32::MAX),
    )?;
    config.validate()?;
    Ok(config)
}

fn load_env_files(paths: &[PathBuf]) -> Result<HashMap<String, String>, String> {
    let mut values = HashMap::new();
    for path in paths {
        let entries = dotenvy::from_path_iter(path)
            .map_err(|error| format!("could not read env file {}: {error}", path.display()))?;
        for entry in entries {
            let (name, value) =
                entry.map_err(|error| format!("invalid env file {}: {error}", path.display()))?;
            values.insert(name, value);
        }
    }
    Ok(values)
}

fn split_list(value: Option<String>) -> Vec<String> {
    value
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn env_number(value: Option<String>, name: &str, default: u64) -> Result<u64, String> {
    match value {
        Some(value) => value
            .trim()
            .parse()
            .map_err(|_| format!("{name} must be a number")),
        None => Ok(default),
    }
}

fn env_bool(value: Option<String>, name: &str, default: bool) -> Result<bool, String> {
    let Some(value) = value else {
        return Ok(default);
    };
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Ok(true),
        "0" | "false" | "no" | "off" => Ok(false),
        _ => Err(format!("{name} must be true or false")),
    }
}

fn env_optional_bool(value: Option<String>, name: &str) -> Result<Option<bool>, String> {
    match value {
        Some(value) if !value.trim().is_empty() => env_bool(Some(value), name, false).map(Some),
        _ => Ok(None),
    }
}

fn env_optional_number(value: Option<String>, name: &str) -> Result<Option<u64>, String> {
    match value {
        Some(value) if !value.trim().is_empty() => value
            .trim()
            .parse()
            .map(Some)
            .map_err(|_| format!("{name} must be a number")),
        _ => Ok(None),
    }
}

fn env_optional_float(value: Option<String>, name: &str) -> Result<Option<f64>, String> {
    match value {
        Some(value) if !value.trim().is_empty() => {
            let parsed: f64 = value
                .trim()
                .parse()
                .map_err(|_| format!("{name} must be a number"))?;
            if !parsed.is_finite() {
                return Err(format!("{name} must be a finite number"));
            }
            Ok(Some(parsed))
        }
        _ => Ok(None),
    }
}

fn env_optional_u32(value: Option<String>, name: &str) -> Result<Option<u32>, String> {
    env_optional_number(value, name)?
        .map(|value| {
            u32::try_from(value)
                .map_err(|_| format!("{name} must fit in an unsigned 32-bit integer"))
        })
        .transpose()
}

fn env_u32(value: Option<String>, name: &str, default: u32) -> Result<u32, String> {
    env_optional_u32(value, name)?.map_or(Ok(default), Ok)
}

fn build_webhook_config(
    url: Option<String>,
    secret: Option<String>,
    timeout_seconds: u64,
    attempts: u32,
) -> Result<Option<WebhookConfig>, String> {
    let (url, secret) = match (url, secret) {
        (None, None) => return Ok(None),
        (Some(_), None) => {
            return Err(
                "HIGHLITE_RELAY_WEBHOOK_URL requires HIGHLITE_RELAY_WEBHOOK_SECRET".to_owned(),
            );
        }
        (None, Some(_)) => {
            return Err(
                "HIGHLITE_RELAY_WEBHOOK_SECRET requires HIGHLITE_RELAY_WEBHOOK_URL".to_owned(),
            );
        }
        (Some(url), Some(secret)) => (url, secret),
    };
    if secret.len() < 16 {
        return Err("HIGHLITE_RELAY_WEBHOOK_SECRET must be at least 16 characters".to_owned());
    }
    if timeout_seconds == 0 {
        return Err("HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS must be at least 1".to_owned());
    }
    if attempts == 0 {
        return Err("HIGHLITE_RELAY_WEBHOOK_ATTEMPTS must be at least 1".to_owned());
    }
    let parsed =
        reqwest::Url::parse(&url).map_err(|error| format!("invalid webhook URL: {error}"))?;
    match parsed.scheme() {
        "https" => {}
        "http" if is_loopback_host(parsed.host_str().unwrap_or_default()) => {}
        "http" => {
            return Err("webhook URLs must use https unless they target localhost".to_owned());
        }
        scheme => return Err(format!("unsupported webhook URL scheme: {scheme}")),
    }
    Ok(Some(WebhookConfig {
        url,
        secret,
        timeout_ms: timeout_seconds.saturating_mul(1000),
        max_attempts: attempts,
    }))
}

fn is_loopback_host(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost") || host == "127.0.0.1" || host == "::1"
}

fn normalize_list(values: Vec<String>) -> Vec<String> {
    values
        .into_iter()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .collect()
}

fn default_hosts_from_bind(bind: &str) -> Vec<String> {
    if !bind.starts_with("0.0.0.0") && !bind.starts_with("[::]") {
        return vec![bind.to_owned()];
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, header};
    use http_body_util::BodyExt;
    use std::io::Write;
    use tempfile::TempDir;
    use tower::ServiceExt;

    fn minimal_manifest(session_id: &str) -> HighliteManifest {
        serde_json::from_value(json!({
            "schemaVersion": "0.1.0",
            "sessionId": session_id,
            "createdAt": "2026-10-22T00:00:00Z",
            "page": { "initialUrl": "https://example.com/", "title": "Example" },
            "viewport": { "x": 0, "y": 0, "width": 1280, "height": 800 },
            "durationMs": 4000,
            "timeline": [],
            "targets": [],
            "annotations": [],
            "transcript": [],
            "keyframes": [],
            "artifacts": {},
            "captureWarnings": []
        }))
        .expect("test manifest should deserialize")
    }

    fn capture_zip(session_id: &str) -> Vec<u8> {
        let manifest = minimal_manifest(session_id);
        let mut bytes = Cursor::new(Vec::new());
        {
            let mut writer = ZipWriter::new(&mut bytes);
            writer
                .start_file(
                    "manifest.json",
                    SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
                )
                .unwrap();
            writer
                .write_all(serde_json::to_string(&manifest).unwrap().as_bytes())
                .unwrap();
            writer.finish().unwrap();
        }
        bytes.into_inner()
    }

    fn test_config(temp: &TempDir) -> RelayConfig {
        RelayConfig {
            bind: "127.0.0.1:0".to_owned(),
            data_dir: temp.path().to_path_buf(),
            ingest_tokens: vec!["ingest-secret".to_owned()],
            read_tokens: vec!["read-secret".to_owned()],
            allowed_hosts: vec!["relay.test".to_owned()],
            allowed_origins: vec!["https://app.test".to_owned()],
            max_upload_bytes: 1024 * 1024,
            max_uncompressed_bytes: 4 * 1024 * 1024,
            max_files: 100,
            concurrency: 1,
            transcriber_command: None,
            language: None,
            keep_uploads: false,
            ui: false,
            allow_pipelines: false,
            pipelines_file: None,
            pipeline_concurrency: 1,
            compile: CompileOptions::default(),
            bundle: BundleOptions::default(),
            webhook: None,
        }
    }

    fn test_app(temp: &TempDir) -> (Router, RelayConfig) {
        let config = test_config(temp);
        let app = build_app(config.clone()).expect("app should build");
        (app, config)
    }

    fn request(method: Method, uri: &str, body: Body) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header(HOST, "relay.test")
            .header(ORIGIN, "https://app.test")
            .body(body)
            .unwrap()
    }

    #[tokio::test]
    async fn requires_ingest_token() {
        let temp = TempDir::new().unwrap();
        let (app, _) = test_app(&temp);
        let response = app
            .oneshot(request(Method::POST, "/v1/sessions", Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn rejects_unknown_origin_and_host() {
        let temp = TempDir::new().unwrap();
        let (app, _) = test_app(&temp);

        let mut bad_origin = request(Method::POST, "/v1/sessions", Body::empty());
        bad_origin
            .headers_mut()
            .insert(ORIGIN, HeaderValue::from_static("https://evil.test"));
        let response = app.clone().oneshot(bad_origin).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);

        let mut bad_host = request(Method::POST, "/v1/sessions", Body::empty());
        bad_host
            .headers_mut()
            .insert(HOST, HeaderValue::from_static("evil.test"));
        let response = app.oneshot(bad_host).await.unwrap();
        assert_eq!(response.status(), StatusCode::MISDIRECTED_REQUEST);
    }

    #[tokio::test]
    async fn accepts_and_compiles_a_minimal_capture() {
        let temp = TempDir::new().unwrap();
        let (app, config) = test_app(&temp);
        let mut upload = request(
            Method::POST,
            "/v1/sessions",
            Body::from(capture_zip("session-1")),
        );
        upload.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer ingest-secret"),
        );
        upload
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));

        let response = app.clone().oneshot(upload).await.unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let metadata: SessionMetadata = serde_json::from_slice(&body).unwrap();
        assert_eq!(metadata.session_id, "session-1");
        assert_eq!(metadata.status, SessionStatus::Ready);
        assert!(metadata.summary.is_some());
        assert!(
            config
                .data_dir
                .join("downloads")
                .join("session-1.zip")
                .is_file()
        );

        let mut status = request(Method::GET, "/v1/sessions/session-1", Body::empty());
        status.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer read-secret"),
        );
        let response = app.clone().oneshot(status).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let mut bundle = request(
            Method::GET,
            "/v1/sessions/session-1/bundle.zip",
            Body::empty(),
        );
        bundle.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer read-secret"),
        );
        let response = app.oneshot(bundle).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "application/zip"
        );
    }

    #[tokio::test]
    async fn lists_ingested_sessions() {
        let temp = TempDir::new().unwrap();
        let (app, _) = test_app(&temp);
        let mut upload = request(
            Method::POST,
            "/v1/sessions",
            Body::from(capture_zip("session-list")),
        );
        upload.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer ingest-secret"),
        );
        upload
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));
        assert_eq!(
            app.clone().oneshot(upload).await.unwrap().status(),
            StatusCode::CREATED
        );

        let mut list = request(Method::GET, "/v1/sessions", Body::empty());
        list.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer read-secret"),
        );
        let response = app.oneshot(list).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let payload: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let sessions = payload["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"], "session-list");
        assert_eq!(sessions[0]["pageTitle"], "Example");
        assert_eq!(sessions[0]["pageUrl"], "https://example.com/");
        assert_eq!(sessions[0]["durationMs"], 4000);
    }

    #[tokio::test]
    async fn runs_a_configured_pipeline() {
        let temp = TempDir::new().unwrap();
        let pipelines = json!({
            "pipelines": [{
                "name": "echo-session",
                "description": "Prints the session id",
                "command": "printf '%s' \"$HIGHLITE_SESSION_ID\"",
                "timeoutSeconds": 10
            }]
        });
        fs::write(
            temp.path().join("pipelines.json"),
            serde_json::to_vec(&pipelines).unwrap(),
        )
        .unwrap();

        let mut config = test_config(&temp);
        config.allow_pipelines = true;
        let app = build_app(config.clone()).expect("app should build");

        let mut upload = request(
            Method::POST,
            "/v1/sessions",
            Body::from(capture_zip("session-pipeline")),
        );
        upload.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer ingest-secret"),
        );
        upload
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));
        assert_eq!(
            app.clone().oneshot(upload).await.unwrap().status(),
            StatusCode::CREATED
        );

        let mut start = request(
            Method::POST,
            "/v1/sessions/session-pipeline/pipelines/echo-session",
            Body::empty(),
        );
        start.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer read-secret"),
        );
        let response = app.oneshot(start).await.unwrap();
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let run: PipelineRun = serde_json::from_slice(&body).unwrap();
        assert_eq!(run.status, PipelineRunStatus::Queued);

        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let stored = read_run(&config.data_dir, &run.run_id).expect("run should persist");
            if matches!(
                stored.status,
                PipelineRunStatus::Succeeded | PipelineRunStatus::Failed
            ) {
                assert_eq!(
                    stored.status,
                    PipelineRunStatus::Succeeded,
                    "{:?}",
                    stored.error
                );
                assert_eq!(stored.stdout.as_deref(), Some("session-pipeline"));
                assert_eq!(stored.exit_code, Some(0));
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "run did not finish");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[tokio::test]
    async fn serves_the_sessions_ui_when_enabled() {
        let temp = TempDir::new().unwrap();
        let mut config = test_config(&temp);
        config.ui = true;
        let app = build_app(config).expect("app should build");
        let response = app
            .oneshot(request(Method::GET, "/", Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(html.contains("Highlite sessions"));
    }

    #[tokio::test]
    async fn allows_same_origin_requests_from_the_ui() {
        let temp = TempDir::new().unwrap();
        let mut config = test_config(&temp);
        config.ui = true;
        config.allowed_hosts = vec!["relay.test".to_owned()];
        config.allowed_origins = Vec::new();
        let app = build_app(config).expect("app should build");

        let mut upload = Request::builder()
            .method(Method::POST)
            .uri("/v1/sessions")
            .header(HOST, "relay.test")
            .header(ORIGIN, "http://relay.test")
            .body(Body::from(capture_zip("session-ui")))
            .unwrap();
        upload.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer ingest-secret"),
        );
        upload
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));
        let response = app.oneshot(upload).await.unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
    }

    #[test]
    fn pipelines_require_a_loopback_bind() {
        let temp = TempDir::new().unwrap();
        let mut config = test_config(&temp);
        config.allow_pipelines = true;
        config.bind = "0.0.0.0:8787".to_owned();
        let Err(error) = build_app(config) else {
            panic!("a non-loopback bind should reject pipelines");
        };
        assert!(error.contains("loopback"));
    }

    #[test]
    fn rejects_invalid_pipeline_definitions() {
        let mut pipeline = Pipeline {
            name: "ok".to_owned(),
            description: None,
            command: "true".to_owned(),
            cwd: None,
            timeout_seconds: 10,
            env: HashMap::new(),
        };
        assert!(validate_pipeline(&pipeline).is_ok());

        pipeline.name = "bad name".to_owned();
        assert!(validate_pipeline(&pipeline).is_err());
        pipeline.name = "ok".to_owned();
        pipeline.command = "  ".to_owned();
        assert!(validate_pipeline(&pipeline).is_err());
        pipeline.command = "true".to_owned();
        pipeline.timeout_seconds = 0;
        assert!(validate_pipeline(&pipeline).is_err());
    }

    #[tokio::test]
    async fn delivers_a_signed_webhook() {
        let temp = TempDir::new().unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
        let hook = Router::new().route(
            "/hook",
            post(move |headers: HeaderMap, body: Bytes| {
                let sender = sender.clone();
                async move {
                    let _ = sender.send((headers, body)).await;
                    StatusCode::NO_CONTENT
                }
            }),
        );
        tokio::spawn(async move {
            let _ = axum::serve(listener, hook).await;
        });

        let secret = "test-webhook-secret";
        let mut config = test_config(&temp);
        config.webhook = Some(WebhookConfig {
            url: format!("http://127.0.0.1:{}/hook", address.port()),
            secret: secret.to_owned(),
            timeout_ms: 1_000,
            max_attempts: 1,
        });
        let app = build_app(config.clone()).expect("app should build");
        let mut upload = request(
            Method::POST,
            "/v1/sessions",
            Body::from(capture_zip("session-webhook")),
        );
        upload.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_static("Bearer ingest-secret"),
        );
        upload
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/zip"));

        let response = app.oneshot(upload).await.unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);

        let (headers, body) = tokio::time::timeout(Duration::from_secs(5), receiver.recv())
            .await
            .expect("webhook should arrive")
            .expect("webhook body should be captured");
        assert_eq!(headers.get("x-highlite-event").unwrap(), "session.ready");
        let timestamp = headers
            .get("x-highlite-timestamp")
            .unwrap()
            .to_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            headers
                .get("x-highlite-signature")
                .unwrap()
                .to_str()
                .unwrap(),
            format!("sha256={}", webhook_signature(secret, &timestamp, &body))
        );
        let payload: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(payload["event"], "session.ready");
        assert_eq!(payload["sessionId"], "session-webhook");
        assert!(payload["session"]["webhook"].is_null());

        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            let metadata = read_metadata(&config.data_dir, "session-webhook").unwrap();
            if metadata.webhook.unwrap().status == WebhookStatus::Delivered {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[test]
    fn builds_configuration_from_values() {
        let values = HashMap::from([
            ("HIGHLITE_RELAY_BIND".to_owned(), "0.0.0.0:9999".to_owned()),
            (
                "HIGHLITE_RELAY_DATA_DIR".to_owned(),
                "/tmp/relay".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_INGEST_TOKEN".to_owned(),
                "ingest-a, ingest-b".to_owned(),
            ),
            ("HIGHLITE_RELAY_READ_TOKEN".to_owned(), "read-a".to_owned()),
            (
                "HIGHLITE_RELAY_ALLOWED_HOSTS".to_owned(),
                "relay.test, example.test:8443".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_ALLOWED_ORIGINS".to_owned(),
                "https://app.test".to_owned(),
            ),
            ("HIGHLITE_RELAY_MAX_UPLOAD_MB".to_owned(), "12".to_owned()),
            (
                "HIGHLITE_RELAY_MAX_UNCOMPRESSED_MB".to_owned(),
                "34".to_owned(),
            ),
            ("HIGHLITE_RELAY_MAX_FILES".to_owned(), "55".to_owned()),
            ("HIGHLITE_RELAY_CONCURRENCY".to_owned(), "3".to_owned()),
            ("HIGHLITE_RELAY_KEEP_UPLOADS".to_owned(), "yes".to_owned()),
            ("HIGHLITE_RELAY_UI".to_owned(), "true".to_owned()),
            (
                "HIGHLITE_RELAY_PIPELINES_FILE".to_owned(),
                "/tmp/pipelines.json".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_PIPELINE_CONCURRENCY".to_owned(),
                "4".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_TRANSCRIBER_COMMAND".to_owned(),
                "python3 asr.py".to_owned(),
            ),
            ("HIGHLITE_RELAY_LANGUAGE".to_owned(), "en".to_owned()),
            (
                "HIGHLITE_RELAY_WEBHOOK_URL".to_owned(),
                "https://hooks.test/highlite".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_WEBHOOK_SECRET".to_owned(),
                "0123456789abcdef0123456789abcdef".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS".to_owned(),
                "7".to_owned(),
            ),
            ("HIGHLITE_RELAY_WEBHOOK_ATTEMPTS".to_owned(), "4".to_owned()),
            ("HIGHLITE_RELAY_MAX_KEYFRAMES".to_owned(), "8".to_owned()),
            ("HIGHLITE_RELAY_MIN_GAP_MS".to_owned(), "100".to_owned()),
            ("HIGHLITE_RELAY_CLAUSE_GAP_MS".to_owned(), "200".to_owned()),
            (
                "HIGHLITE_RELAY_CROP_PADDING_PX".to_owned(),
                "24.5".to_owned(),
            ),
            ("HIGHLITE_RELAY_CROP".to_owned(), "false".to_owned()),
            ("HIGHLITE_RELAY_COVERAGE".to_owned(), "false".to_owned()),
            ("HIGHLITE_RELAY_SPEECH_CUES".to_owned(), "false".to_owned()),
            ("HIGHLITE_RELAY_CUE_WINDOW_MS".to_owned(), "1500".to_owned()),
            (
                "HIGHLITE_RELAY_BURN_ANNOTATIONS".to_owned(),
                "false".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_CONTACT_SHEET".to_owned(),
                "false".to_owned(),
            ),
            (
                "HIGHLITE_RELAY_CONTACT_SHEET_WIDTH".to_owned(),
                "1200".to_owned(),
            ),
        ]);
        let config = config_from_values(values, None, None, None).expect("config should parse");
        assert_eq!(config.bind, "0.0.0.0:9999");
        assert_eq!(config.data_dir, PathBuf::from("/tmp/relay"));
        assert_eq!(
            config.ingest_tokens,
            vec!["ingest-a".to_owned(), "ingest-b".to_owned()]
        );
        assert_eq!(config.read_tokens, vec!["read-a".to_owned()]);
        assert_eq!(
            config.allowed_hosts,
            vec!["relay.test".to_owned(), "example.test:8443".to_owned()]
        );
        assert_eq!(config.allowed_origins, vec!["https://app.test".to_owned()]);
        assert_eq!(config.max_upload_bytes, 12 * 1024 * 1024);
        assert_eq!(config.max_uncompressed_bytes, 34 * 1024 * 1024);
        assert_eq!(config.max_files, 55);
        assert_eq!(config.concurrency, 3);
        assert!(config.keep_uploads);
        assert!(config.ui);
        assert!(!config.allow_pipelines);
        assert_eq!(
            config.pipelines_file,
            Some(PathBuf::from("/tmp/pipelines.json"))
        );
        assert_eq!(config.pipeline_concurrency, 4);
        assert_eq!(
            config.transcriber_command.as_deref(),
            Some("python3 asr.py")
        );
        assert_eq!(config.language.as_deref(), Some("en"));
        let webhook = config.webhook.expect("webhook should be configured");
        assert_eq!(webhook.url, "https://hooks.test/highlite");
        assert_eq!(webhook.timeout_ms, 7_000);
        assert_eq!(webhook.max_attempts, 4);
        assert_eq!(config.compile.max_keyframes, Some(8));
        assert_eq!(config.compile.min_gap_ms, Some(100));
        assert_eq!(config.compile.clause_gap_ms, Some(200));
        assert_eq!(config.compile.crop_padding_px, Some(24.5));
        assert_eq!(config.compile.crop, Some(false));
        assert_eq!(config.compile.coverage, Some(false));
        assert_eq!(config.compile.speech_cues, Some(false));
        assert_eq!(config.compile.cue_window_ms, Some(1_500));
        assert!(!config.bundle.annotations);
        assert!(!config.bundle.contact_sheet);
        assert_eq!(config.bundle.contact_sheet_width, 1200);
    }

    #[test]
    fn env_files_are_loaded_in_order() {
        let temp = TempDir::new().unwrap();
        let base = temp.path().join("base.env");
        let production = temp.path().join("production.env");
        fs::write(
            &base,
            "# base settings\nHIGHLITE_RELAY_INGEST_TOKEN=base-token\nHIGHLITE_RELAY_BIND=127.0.0.1:1000\n",
        )
        .unwrap();
        fs::write(
            &production,
            "HIGHLITE_RELAY_INGEST_TOKEN=production-token\nHIGHLITE_RELAY_KEEP_UPLOADS=true\n",
        )
        .unwrap();
        let values = load_env_files(&[base, production]).unwrap();
        assert_eq!(
            values
                .get("HIGHLITE_RELAY_INGEST_TOKEN")
                .map(String::as_str),
            Some("production-token")
        );
        assert_eq!(
            values.get("HIGHLITE_RELAY_BIND").map(String::as_str),
            Some("127.0.0.1:1000")
        );
        assert_eq!(
            values
                .get("HIGHLITE_RELAY_KEEP_UPLOADS")
                .map(String::as_str),
            Some("true")
        );
    }

    #[test]
    fn cli_flags_are_limited_to_env_file_and_overrides() {
        let error =
            config_from_args(&["--webhook-url".to_owned(), "https://hooks.test".to_owned()])
                .unwrap_err();
        assert!(error.contains("env file"));
    }

    #[test]
    fn rejects_unsafe_session_ids() {
        assert!(checked_session_id("session-1").is_some());
        assert!(checked_session_id("../escape").is_none());
        assert!(checked_session_id(".hidden").is_none());
        assert!(checked_session_id("a/b").is_none());
        assert!(checked_session_id("a".repeat(129).as_str()).is_none());
    }

    #[test]
    fn rejects_unsafe_zip_paths() {
        assert!(safe_relative_path(Path::new("frames/0001.png")));
        assert!(!safe_relative_path(Path::new("../manifest.json")));
        assert!(!safe_relative_path(Path::new("/absolute.png")));
        assert!(!safe_relative_path(Path::new("./manifest.json")));
    }
}
