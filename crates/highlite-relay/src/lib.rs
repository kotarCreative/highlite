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
use axum::response::{IntoResponse, Response};
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
use serde_json::json;
use sha2::Sha256;
use subtle::ConstantTimeEq;
use tokio::sync::Semaphore;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

const MANIFEST_SCHEMA_VERSION: &str = "0.1.0";
const MAX_PATH_COMPONENTS: usize = 16;

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
    in_flight: Arc<Mutex<std::collections::HashSet<String>>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMetadata {
    pub session_id: String,
    pub status: SessionStatus,
    pub received_at_ms: u64,
    pub bytes: u64,
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
/// apart from the shared in-flight set and compile semaphore.
pub fn build_app(config: RelayConfig) -> Result<Router, String> {
    config.validate()?;
    create_data_dirs(&config.data_dir)?;
    let state = AppState {
        compile_slots: Arc::new(Semaphore::new(config.concurrency)),
        in_flight: Arc::new(Mutex::new(std::collections::HashSet::new())),
        config: Arc::new(config),
    };

    let ingest = Router::new()
        .route("/v1/sessions", post(ingest_session))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_ingest_token,
        ));
    let read = Router::new()
        .route("/v1/sessions/{id}", get(get_session))
        .route("/v1/sessions/{id}/bundle.zip", get(get_bundle))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_read_token,
        ));

    Ok(Router::new()
        .route("/healthz", get(health))
        .merge(ingest)
        .merge(read)
        .layer(middleware::from_fn_with_state(state.clone(), guard_request))
        .with_state(state))
}

fn create_data_dirs(root: &Path) -> Result<(), String> {
    for child in ["inbox", "sessions", "bundles", "downloads", "uploads"] {
        fs::create_dir_all(root.join(child))
            .map_err(|error| format!("could not create {}: {error}", root.join(child).display()))?;
    }
    Ok(())
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
    let origin_allowed = match origin.as_deref() {
        Some(origin) => origin_is_allowed(origin, &state.config.allowed_origins),
        None => false,
    };

    if origin.is_some() && !origin_allowed {
        return error_response(StatusCode::FORBIDDEN, "origin is not allowed");
    }

    if !host_is_allowed(
        request
            .headers()
            .get(HOST)
            .and_then(|value| value.to_str().ok())
            .or_else(|| {
                request
                    .uri()
                    .authority()
                    .map(|authority| authority.as_str())
            }),
        &state.config.allowed_hosts,
    ) {
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

async fn require_ingest_token(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    if bearer_is_valid(request.headers(), &state.config.ingest_tokens) {
        next.run(request).await
    } else {
        unauthorized()
    }
}

async fn require_read_token(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
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

/// Parse relay CLI arguments into a validated configuration.
pub fn config_from_args(args: &[String]) -> Result<RelayConfig, String> {
    let mut env_files: Vec<PathBuf> = Vec::new();
    let mut bind_override: Option<String> = None;
    let mut data_dir_override: Option<PathBuf> = None;
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
    config_from_values(values, bind_override, data_dir_override)
}

fn config_from_values(
    values: HashMap<String, String>,
    bind_override: Option<String>,
    data_dir_override: Option<PathBuf>,
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
        let config = config_from_values(values, None, None).expect("config should parse");
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
