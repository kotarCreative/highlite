#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::{Body, to_bytes};
use axum::extract::State;
use axum::http::{
    Method, StatusCode,
    header::{AUTHORIZATION, CONTENT_TYPE},
};
use axum::response::{IntoResponse, Response};
use axum::{Json, Router};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tower::ServiceExt;

use crate::opencode::{CliFailure, OpenCodeCli, PromptOutcome};
use crate::opencode_recipe::{OpenCodeRun, OpenCodeRunStatus, OpenCodeSettings};
use crate::providers::{ConnectProvider, ProviderKind, ProviderStore};
use crate::tests::{capture_zip, request, test_config};

const SCRIPT: &str = r#"#!/bin/sh
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$1 $2" in
  "api server.info") cat "$dir/server.json" ;;
  "api project.list") cat "$dir/projects.json" ;;
  "api session.list") cat "$dir/sessions.json" ;;
  "api session.get")
    printf '%s\n' "$4" >> "$dir/session.calls"
    if [ -f "$dir/session.sleep" ]; then sleep "$(cat "$dir/session.sleep")"; fi
    cat "$dir/session.json"
    ;;
  "api session.prompt")
    printf '%s\n' "$4" >> "$dir/prompt.calls"
    printf '%s' "$6" > "$dir/prompt.data"
    if [ -f "$dir/prompt.fail" ]; then
      if [ -f "$dir/prompt.stdout" ]; then cat "$dir/prompt.stdout"; fi
      cat "$dir/prompt.stderr" >&2
      exit 1
    fi
    if [ -f "$dir/prompt.sleep" ]; then sleep "$(cat "$dir/prompt.sleep")"; fi
    cat "$dir/prompt.json"
    ;;
  *) exit 1 ;;
esac
"#;

struct FakeCli {
    root: PathBuf,
    script: PathBuf,
}

impl FakeCli {
    fn new(temp: &TempDir) -> Self {
        let root = temp.path().join("fake-opencode");
        fs::create_dir_all(&root).unwrap();
        let script = root.join("opencode");
        fs::write(&script, SCRIPT).unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let cli = Self { root, script };
        cli.write(
            "server.json",
            json!({"version": "2.0.32", "pid": 1, "urls": [], "paths": {"tmp": "/tmp"}}),
        );
        cli.write("projects.json", json!([]));
        cli.write("sessions.json", json!({"data": []}));
        cli.write("session.json", json!({}));
        cli.write(
            "prompt.json",
            json!({"data": {"id": "msg_default", "sessionID": "ses_target"}}),
        );
        cli
    }

    fn path(&self) -> String {
        self.script.to_string_lossy().into_owned()
    }

    fn write(&self, name: &str, value: Value) {
        fs::write(self.root.join(name), serde_json::to_vec(&value).unwrap()).unwrap();
    }

    fn set_sessions(&self, sessions: Vec<Value>) {
        self.write("sessions.json", json!({"data": sessions}));
    }

    fn set_project_list(&self, projects: Value) {
        self.write("projects.json", projects);
    }

    fn set_session(&self, session: Value) {
        self.write("session.json", session);
    }

    fn delay_session_get(&self, seconds: &str) {
        fs::write(self.root.join("session.sleep"), seconds).unwrap();
    }

    fn clear_session_delay(&self) {
        let _ = fs::remove_file(self.root.join("session.sleep"));
    }

    fn set_prompt_success(&self, message_id: &str) {
        self.set_prompt_response(message_id, "ses_target");
    }

    fn set_prompt_response(&self, message_id: &str, session_id: &str) {
        let _ = fs::remove_file(self.root.join("prompt.fail"));
        let _ = fs::remove_file(self.root.join("prompt.stdout"));
        let _ = fs::remove_file(self.root.join("prompt.stderr"));
        self.write(
            "prompt.json",
            json!({"data": {"id": message_id, "sessionID": session_id}}),
        );
    }

    fn set_prompt_missing_session(&self, message_id: &str) {
        let _ = fs::remove_file(self.root.join("prompt.fail"));
        let _ = fs::remove_file(self.root.join("prompt.stdout"));
        let _ = fs::remove_file(self.root.join("prompt.stderr"));
        self.write("prompt.json", json!({"data": {"id": message_id}}));
    }

    fn set_prompt_failure(&self, status: u16, secret: &str) {
        fs::write(
            self.root.join("prompt.stderr"),
            format!("HTTP {status}\n{secret}\n"),
        )
        .unwrap();
        fs::write(
            self.root.join("prompt.stdout"),
            format!("{{\"error\":\"{secret}\"}}"),
        )
        .unwrap();
        fs::write(self.root.join("prompt.fail"), b"").unwrap();
    }

    fn prompt_data(&self) -> Option<Value> {
        let bytes = fs::read(self.root.join("prompt.data")).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    fn prompt_calls(&self) -> usize {
        fs::read_to_string(self.root.join("prompt.calls"))
            .map(|calls| calls.lines().count())
            .unwrap_or(0)
    }

    fn session_get_calls(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("session.calls"))
            .map(|calls| calls.lines().map(str::to_owned).collect())
            .unwrap_or_default()
    }
}

fn session_json(
    id: &str,
    directory: &Path,
    title: Option<&str>,
    updated: f64,
    parent: Option<&str>,
    archived: Option<f64>,
) -> Value {
    let mut session = json!({
        "id": id,
        "projectID": "opaque-project-id",
        "location": {"directory": directory.to_string_lossy()},
        "time": {"created": updated - 10.0, "updated": updated},
    });
    if let Some(title) = title {
        session["title"] = json!(title);
    }
    if let Some(parent) = parent {
        session["parentID"] = json!(parent);
    }
    if let Some(archived) = archived {
        session["time"]["archived"] = json!(archived);
    }
    session
}

fn project_list() -> Value {
    json!([
        {
            "id": "opaque-project-id",
            "canonical": "/work/app",
            "name": "app",
            "time": {"created": 1, "updated": 2, "active": 2},
        },
        {
            "id": "unused-project-id",
            "canonical": "/work/unrelated",
            "name": "unrelated",
            "time": {"created": 1, "updated": 2, "active": 2},
        }
    ])
}

#[derive(Default)]
struct MockAi {
    calls: AtomicUsize,
    mode: AtomicU8,
    target: Mutex<String>,
    bodies: Mutex<Vec<Value>>,
}

impl MockAi {
    fn set_mode(&self, mode: u8) {
        self.mode.store(mode, Ordering::SeqCst);
    }

    fn body(&self) -> Value {
        self.bodies
            .lock()
            .unwrap()
            .first()
            .cloned()
            .unwrap_or(Value::Null)
    }
}

async fn ai(State(state): State<Arc<MockAi>>, request: axum::extract::Request) -> Response {
    let auth = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    assert_eq!(auth, "Bearer ai-secret");
    let bytes = to_bytes(request.into_body(), 2 * 1024 * 1024)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    state.calls.fetch_add(1, Ordering::SeqCst);
    state.bodies.lock().unwrap().push(body);
    if state.mode.load(Ordering::SeqCst) == 3 {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "ai-secret"})),
        )
            .into_response();
    }
    let target = state.target.lock().unwrap().clone();
    let content = match state.mode.load(Ordering::SeqCst) {
        1 => json!({
            "sessionId": "ses_hallucinated",
            "confidence": "high",
            "reason": "This ID was not offered."
        })
        .to_string(),
        2 => "not valid json".to_owned(),
        _ => json!({
            "sessionId": target,
            "confidence": "high",
            "reason": "The capture matches this session."
        })
        .to_string(),
    };
    Json(json!({
        "choices": [{"finish_reason": "stop", "message": {"content": content}}]
    }))
    .into_response()
}

async fn mock_ai() -> (String, Arc<MockAi>, tokio::task::JoinHandle<()>) {
    let state = Arc::new(MockAi::default());
    *state.target.lock().unwrap() = "ses_target".to_owned();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = Router::new().fallback(ai).with_state(state.clone());
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (format!("http://{address}"), state, task)
}

fn provider(root: &Path, base: &str) {
    ProviderStore::new(root.to_path_buf())
        .connect(
            "default",
            ConnectProvider {
                kind: ProviderKind::OpenaiCompatible,
                model: "test-model".to_owned(),
                base_url: Some(format!("{base}/v1")),
                api_key: Some("ai-secret".to_owned()),
                clear_api_key: false,
                make_default: true,
            },
        )
        .unwrap();
}

fn settings_json(
    directory: &Path,
    cli: &FakeCli,
    enabled: bool,
    auto_draft: bool,
    prompt: &str,
) -> Value {
    json!({
        "enabled": enabled,
        "autoDraft": auto_draft,
        "directory": directory.to_string_lossy(),
        "prompt": prompt,
        "opencodePath": cli.path(),
        "maxCandidates": 5,
    })
}

async fn call(
    app: &Router,
    method: Method,
    path: &str,
    input: Value,
    token: &str,
) -> (StatusCode, Value) {
    let mut req = request(
        method,
        path,
        Body::from(serde_json::to_vec(&input).unwrap()),
    );
    req.headers_mut()
        .insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
    req.headers_mut()
        .insert(CONTENT_TYPE, "application/json".parse().unwrap());
    let response = app.clone().oneshot(req).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8_lossy(&bytes);
    assert!(!text.contains("ai-secret"));
    assert!(!text.contains("secret-cli-output"));
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, value)
}

async fn upload(app: &Router, session: &str) -> StatusCode {
    let mut req = request(
        Method::POST,
        "/v1/sessions",
        Body::from(capture_zip(session)),
    );
    req.headers_mut()
        .insert(AUTHORIZATION, "Bearer ingest-secret".parse().unwrap());
    req.headers_mut()
        .insert(CONTENT_TYPE, "application/zip".parse().unwrap());
    app.clone().oneshot(req).await.unwrap().status()
}

async fn wait_for(app: &Router, path: &str, expected: &str) -> Value {
    for _ in 0..500 {
        let (code, response) = call(app, Method::GET, path, Value::Null, "read-secret").await;
        assert_eq!(code, StatusCode::OK);
        if response["run"]["status"] == expected {
            return response["run"].clone();
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("OpenCode run did not reach {expected}");
}

async fn configure(app: &Router, settings: Value) -> StatusCode {
    call(
        app,
        Method::POST,
        "/v1/recipes/opencode",
        json!({"settings": settings}),
        "read-secret",
    )
    .await
    .0
}

fn run_path(session: &str) -> String {
    format!("/v1/sessions/{session}/recipes/opencode")
}

fn run_record(session_id: &str, status: OpenCodeRunStatus, version: &str) -> OpenCodeRun {
    OpenCodeRun {
        session_id: session_id.to_owned(),
        recipe: "opencode".to_owned(),
        recipe_version: version.to_owned(),
        status,
        settings: OpenCodeSettings {
            enabled: true,
            auto_draft: false,
            directory: "/work/app".to_owned(),
            prompt: "Trusted instructions".to_owned(),
            opencode_path: None,
            max_candidates: 30,
        },
        provider: None,
        eligible_session_ids: Vec::new(),
        candidates: Vec::new(),
        suggestion: None,
        prompt_preview: "Trusted preview".to_owned(),
        message_id: None,
        opencode_session_id: None,
        opencode_title: None,
        submitted_at_ms: None,
        error: None,
        revision: 1,
        created_at_ms: 1,
        updated_at_ms: 1,
    }
}

fn write_run(data_dir: &Path, run: &OpenCodeRun) {
    let digest: String = Sha256::digest(run.session_id.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    crate::private_config::access(
        &data_dir.join("recipe-runs"),
        &format!("opencode-{digest}"),
        true,
        |stored: &mut Option<OpenCodeRun>| {
            *stored = Some(run.clone());
            Ok(())
        },
    )
    .unwrap();
}

fn submit_body(revision: u64, target: &str, confirm: bool) -> Value {
    json!({"revision": revision, "sessionId": target, "confirm": confirm})
}

#[tokio::test]
async fn discovery_filters_exactly_and_returns_metadata_only() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    let other = temp.path().join("work/other");
    let mut sessions = vec![
        session_json(
            "ses_target",
            &directory,
            Some("Checkout bug"),
            1_760_000_500.0,
            None,
            None,
        ),
        session_json(
            "ses_child",
            &directory,
            Some("Child"),
            1_760_000_800.0,
            Some("ses_target"),
            None,
        ),
        session_json(
            "ses_archived",
            &directory,
            Some("Archived"),
            1_760_000_700.0,
            None,
            Some(1_760_000_700.0),
        ),
        session_json(
            "ses_other",
            &other,
            Some("Other"),
            1_760_000_600.0,
            None,
            None,
        ),
        session_json(
            "ses_subdir",
            &directory.join("sub"),
            Some("Sub"),
            1_760_000_600.0,
            None,
            None,
        ),
        session_json(
            "not_a_session",
            &directory,
            Some("Bad id"),
            1_760_000_900.0,
            None,
            None,
        ),
    ];
    for (index, updated) in [499.0, 498.0, 497.0, 496.0, 495.0, 494.0]
        .into_iter()
        .enumerate()
    {
        sessions.push(session_json(
            &format!("ses_extra_{index}"),
            &directory,
            (index != 1).then_some("Extra session"),
            1_760_000_000.0 + updated,
            None,
            None,
        ));
    }
    sessions.push(session_json(
        &format!("ses_{}", "x".repeat(300)),
        &directory,
        Some("Overlong id"),
        1_760_000_900.0,
        None,
        None,
    ));
    let mut overlong_project = session_json(
        "ses_overlong_project",
        &directory,
        Some("Overlong project"),
        1_760_000_900.0,
        None,
        None,
    );
    overlong_project["projectID"] = json!("p".repeat(300));
    sessions.push(overlong_project);
    cli.set_sessions(sessions);
    cli.set_project_list(project_list());

    let config = test_config(&temp);
    let app = crate::build_app(config.clone()).unwrap();
    let settings = settings_json(&directory, &cli, false, false, "Trusted instructions");
    assert_eq!(configure(&app, settings).await, StatusCode::OK);

    let (status, config_info) = call(
        &app,
        Method::GET,
        "/v1/recipes/opencode",
        Value::Null,
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(config_info["managementEnabled"], true);
    assert_eq!(config_info["recipe"]["id"], "opencode");
    assert_eq!(config_info["recipe"]["version"], "1.0.0");

    assert_eq!(
        call(
            &app,
            Method::POST,
            "/v1/recipes/opencode/discover",
            json!({}),
            "ingest-secret"
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (status, discovery) = call(
        &app,
        Method::POST,
        "/v1/recipes/opencode/discover",
        json!({}),
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(discovery["opencode"]["version"], "2.0.32");
    assert_eq!(discovery["directory"], directory.to_string_lossy().as_ref());
    assert_eq!(discovery["projects"][0]["projectId"], "opaque-project-id");
    assert_eq!(discovery["projects"][0]["name"], "app");
    assert_eq!(discovery["projects"].as_array().unwrap().len(), 1);
    let sessions = discovery["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 5);
    let ids: Vec<&str> = sessions
        .iter()
        .map(|session| session["sessionId"].as_str().unwrap())
        .collect();
    assert_eq!(ids[0], "ses_target");
    for excluded in [
        "ses_child",
        "ses_archived",
        "ses_other",
        "ses_subdir",
        "not_a_session",
        "ses_overlong_project",
    ] {
        assert!(!ids.contains(&excluded));
    }
    assert!(ids.iter().all(|id| id.len() <= 256));
    assert!(!ids.iter().any(|id| id.starts_with("ses_xxx")));
    assert_eq!(sessions[0]["title"], "Checkout bug");
    assert_eq!(
        sessions[0]["directory"],
        directory.to_string_lossy().as_ref()
    );
    assert_eq!(sessions[0]["projectName"], "app");
    assert_eq!(sessions[0]["createdAtMs"], 1_760_000_490_000u64);
    assert_eq!(sessions[0]["updatedAtMs"], 1_760_000_500_000u64);
    let fallback = sessions
        .iter()
        .find(|session| session["sessionId"] == "ses_extra_1")
        .unwrap();
    assert_eq!(fallback["title"], "Untitled session");
    assert!(!discovery.to_string().contains("messages"));
    assert!(!discovery.to_string().contains("cost"));

    let mut remote_config = config;
    remote_config.bind = "0.0.0.0:8787".to_owned();
    let remote_app = crate::build_app(remote_config).unwrap();
    assert_eq!(
        call(
            &remote_app,
            Method::POST,
            "/v1/recipes/opencode/discover",
            json!({}),
            "read-secret"
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn startup_recovery_skips_invalid_runs_and_keeps_the_relay_alive() {
    use std::os::unix::fs::symlink;

    let temp = TempDir::new().unwrap();
    let config = test_config(&temp);
    let recipe_runs = temp.path().join("recipe-runs");
    write_run(
        temp.path(),
        &run_record("recover-queued", OpenCodeRunStatus::Queued, "1.0.0"),
    );
    write_run(
        temp.path(),
        &run_record("recover-submitting", OpenCodeRunStatus::Submitting, "1.0.0"),
    );
    write_run(
        temp.path(),
        &run_record("recover-future", OpenCodeRunStatus::Suggested, "9.0.0"),
    );
    write_run(
        temp.path(),
        &run_record("recover-permission", OpenCodeRunStatus::Suggested, "1.0.0"),
    );
    let future_path = recipe_runs.join(format!(
        "opencode-{}.json",
        Sha256::digest(b"recover-future")
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ));
    let future_before = fs::read(&future_path).unwrap();
    let permission_path = recipe_runs.join(format!(
        "opencode-{}.json",
        Sha256::digest(b"recover-permission")
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ));
    fs::set_permissions(&permission_path, fs::Permissions::from_mode(0o644)).unwrap();
    let permission_before = fs::read(&permission_path).unwrap();
    let malformed_path = recipe_runs.join("opencode-malformed.json");
    fs::write(&malformed_path, b"not json").unwrap();
    fs::set_permissions(&malformed_path, fs::Permissions::from_mode(0o600)).unwrap();
    let target = temp.path().join("symlink-target.json");
    fs::write(&target, b"do not overwrite").unwrap();
    symlink(&target, recipe_runs.join("opencode-symlink.json")).unwrap();

    let app = crate::build_app(config.clone()).expect("invalid runs must not block startup");
    let store = crate::opencode_recipe::OpenCodeRunStore::new(temp.path());
    assert_eq!(
        store.read("recover-queued").unwrap().unwrap().status,
        OpenCodeRunStatus::Failed
    );
    assert_eq!(
        store.read("recover-submitting").unwrap().unwrap().status,
        OpenCodeRunStatus::SubmitUnknown
    );
    let future_error = store.read("recover-future").unwrap_err();
    assert!(future_error.contains("unsupported"));
    assert_eq!(fs::read(&future_path).unwrap(), future_before);
    assert_eq!(fs::read(&permission_path).unwrap(), permission_before);
    assert_eq!(fs::read(&malformed_path).unwrap(), b"not json");
    assert_eq!(fs::read(&target).unwrap(), b"do not overwrite");
    assert!(
        fs::symlink_metadata(recipe_runs.join("opencode-symlink.json"))
            .unwrap()
            .file_type()
            .is_symlink()
    );

    let req = request(Method::GET, "/healthz", Body::empty());
    let response = app.oneshot(req).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn submitted_run_is_idempotent_before_configuration_or_revision_checks() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    cli.set_session(session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    let (base, _ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );
    assert_eq!(
        upload(&app, "idempotent-session").await,
        StatusCode::CREATED
    );
    let path = run_path("idempotent-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    let run = wait_for(&app, &path, "suggested").await;
    cli.set_prompt_success("msg_idempotent");
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/submit"),
            submit_body(run["revision"].as_u64().unwrap(), "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    wait_for(&app, &path, "submitted").await;
    assert_eq!(cli.prompt_calls(), 1);

    let mut disabled = settings_json(&directory, &cli, false, false, "Trusted instructions");
    disabled["directory"] = json!(directory.to_string_lossy());
    assert_eq!(configure(&app, disabled).await, StatusCode::OK);
    let (status, existing) = call(
        &app,
        Method::POST,
        &format!("{path}/submit"),
        submit_body(999, "ses_target", true),
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(existing["status"], "submitted");
    assert_eq!(cli.prompt_calls(), 1);

    let other = temp.path().join("work/other");
    fs::create_dir_all(&other).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&other, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );
    let (status, existing) = call(
        &app,
        Method::POST,
        &format!("{path}/submit"),
        submit_body(999, "ses_target", true),
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(existing["status"], "submitted");
    assert_eq!(cli.prompt_calls(), 1);
    task.abort();
}

#[tokio::test]
async fn configuration_change_during_revalidation_prevents_delivery() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let other = temp.path().join("work/other");
    fs::create_dir_all(&other).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    cli.set_session(session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    let (base, _ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "delayed-session").await, StatusCode::CREATED);
    let path = run_path("delayed-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    let run = wait_for(&app, &path, "suggested").await;
    let revision = run["revision"].as_u64().unwrap();
    cli.delay_session_get("0.5");

    let submit_path = format!("{path}/submit");
    let submit_app = app.clone();
    let submit_task = tokio::spawn(async move {
        call(
            &submit_app,
            Method::POST,
            &submit_path,
            submit_body(revision, "ses_target", true),
            "read-secret",
        )
        .await
    });
    for _ in 0..100 {
        if !cli.session_get_calls().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        !cli.session_get_calls().is_empty(),
        "session.get should be in flight"
    );
    assert_eq!(
        configure(
            &app,
            settings_json(&other, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );
    let (status, error) = submit_task.await.unwrap();
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(
        error["error"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("settings changed")
    );
    assert_eq!(cli.prompt_calls(), 0);
    cli.clear_session_delay();
    task.abort();
}

#[tokio::test]
async fn spawn_failure_before_dispatch_is_retryable_not_unknown() {
    let temp = TempDir::new().unwrap();
    let missing = temp.path().join("missing-opencode");
    let cli = OpenCodeCli::new(Some(missing.to_string_lossy().as_ref())).unwrap();
    let outcome = cli
        .prompt(
            "ses_target",
            &json!({"id": "msg_x", "text": "preview", "delivery": "queue"}),
        )
        .await;
    match outcome {
        PromptOutcome::Rejected(error) => {
            assert!(error.contains("no prompt was sent"));
        }
        _ => panic!("a failed spawn must be classified as a safe, retryable rejection"),
    }
}

#[tokio::test]
async fn manual_run_suggests_without_submitting_and_revalidates_before_one_exact_prompt() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![
        session_json(
            "ses_target",
            &directory,
            Some("Checkout bug"),
            1_760_000_500.0,
            None,
            None,
        ),
        session_json(
            "ses_other",
            &directory,
            Some("Billing bug"),
            1_760_000_400.0,
            None,
            None,
        ),
    ]);
    cli.set_project_list(project_list());
    cli.set_session(session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    let (base, ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config.clone()).unwrap();
    let prompt = "Trusted team instructions: focus on reproduction steps";
    assert_eq!(
        configure(&app, settings_json(&directory, &cli, true, false, prompt)).await,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "hl-session").await, StatusCode::CREATED);

    let path = run_path("hl-session");
    let (status, started) = call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(started["status"], "queued");
    let run = wait_for(&app, &path, "suggested").await;
    assert_eq!(run["revision"], 1);
    assert_eq!(run["provider"]["id"], "default");
    assert_eq!(run["suggestion"]["sessionId"], "ses_target");
    assert_eq!(run["suggestion"]["confidence"], "high");
    assert_eq!(run["messageId"], Value::Null);
    assert_eq!(run["opencodeSessionId"], Value::Null);
    assert_eq!(run["eligibleSessionIds"].as_array().unwrap().len(), 2);
    assert_eq!(run["candidates"].as_array().unwrap().len(), 2);
    assert_eq!(run["settings"]["enabled"], true);
    assert_eq!(cli.prompt_calls(), 0, "suggestion must never submit");
    assert_eq!(ai.calls.load(Ordering::SeqCst), 1);

    let preview = run["promptPreview"].as_str().unwrap().to_owned();
    assert!(preview.starts_with(prompt));
    assert!(preview.contains("Inline capture summary"));
    assert!(!preview.contains(&directory.to_string_lossy().into_owned()));
    assert!(!preview.contains(&temp.path().to_string_lossy().into_owned()));
    assert!(preview.len() <= 64 * 1024);

    let evidence = ai.body()["messages"][1]["content"][0]["text"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(evidence.contains("ses_target"));
    assert!(evidence.contains("Checkout bug"));
    assert!(!evidence.contains("analysis.json"));
    assert!(!evidence.contains("bundle.json"));
    assert!(
        ai.body()["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("untrusted")
    );

    let (_, repeated) = call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    assert_eq!(repeated["revision"], 1);
    assert_eq!(repeated["promptPreview"], preview.as_str());
    let (_, fetched) = call(&app, Method::GET, &path, Value::Null, "read-secret").await;
    assert_eq!(fetched["run"]["promptPreview"], preview.as_str());

    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/submit"),
            submit_body(1, "ses_target", false),
            "read-secret"
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/submit"),
            submit_body(99, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/submit"),
            submit_body(1, "ses_missing", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::CONFLICT
    );

    let other_directory = temp.path().join("work/other");
    fs::create_dir_all(&other_directory).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&other_directory, &cli, true, false, prompt)
        )
        .await,
        StatusCode::OK
    );
    let (status, error) = call(
        &app,
        Method::POST,
        &format!("{path}/submit"),
        submit_body(1, "ses_target", true),
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(
        error["error"]
            .as_str()
            .unwrap()
            .contains("directory changed")
    );
    assert_eq!(cli.prompt_calls(), 0);
    assert_eq!(
        configure(&app, settings_json(&directory, &cli, true, false, prompt)).await,
        StatusCode::OK
    );

    cli.set_session(session_json(
        "ses_target",
        &other_directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/submit"),
            submit_body(1, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(cli.prompt_calls(), 0);

    cli.set_session(session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    cli.set_prompt_success("msg_returned");
    let (status, submitting) = call(
        &app,
        Method::POST,
        &format!("{path}/submit"),
        submit_body(1, "ses_target", true),
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(submitting["status"], "submitting");
    let submitted = wait_for(&app, &path, "submitted").await;
    assert_eq!(submitted["messageId"], "msg_returned");
    assert_eq!(submitted["opencodeSessionId"], "ses_target");
    assert_eq!(submitted["opencodeTitle"], "Checkout bug");
    assert!(submitted["submittedAtMs"].as_u64().unwrap() > 0);
    assert_eq!(cli.prompt_calls(), 1);
    assert_eq!(cli.session_get_calls().len(), 2);
    assert!(
        cli.session_get_calls()
            .iter()
            .all(|call| call == "sessionID=ses_target")
    );

    let data = cli.prompt_data().unwrap();
    assert_eq!(data["text"], preview.as_str());
    assert_eq!(data["delivery"], "queue");
    assert_eq!(
        data["id"],
        crate::opencode_recipe::deterministic_message_id("hl-session", 1, "ses_target")
    );

    let (status, existing) = call(
        &app,
        Method::POST,
        &format!("{path}/submit"),
        submit_body(1, "ses_target", true),
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(existing["status"], "submitted");
    assert_eq!(cli.prompt_calls(), 1);
    task.abort();
}

#[tokio::test]
async fn automatic_draft_creates_a_suggestion_but_never_submits() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    let (base, ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, true, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "auto-session").await, StatusCode::CREATED);
    let run = wait_for(&app, &run_path("auto-session"), "suggested").await;
    assert_eq!(run["suggestion"]["sessionId"], "ses_target");
    assert_eq!(ai.calls.load(Ordering::SeqCst), 1);
    assert_eq!(cli.prompt_calls(), 0);
    task.abort();
}

#[tokio::test]
async fn invalid_ai_output_abstains_while_provider_failure_fails_the_run() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    let (base, ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );

    ai.set_mode(1);
    assert_eq!(
        upload(&app, "hallucinated-session").await,
        StatusCode::CREATED
    );
    let path = run_path("hallucinated-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    let run = wait_for(&app, &path, "suggested").await;
    assert_eq!(run["suggestion"], Value::Null);
    assert_eq!(run["eligibleSessionIds"].as_array().unwrap().len(), 1);
    assert!(!run["promptPreview"].as_str().unwrap().is_empty());

    ai.set_mode(2);
    assert_eq!(upload(&app, "invalid-session").await, StatusCode::CREATED);
    let path = run_path("invalid-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    let run = wait_for(&app, &path, "suggested").await;
    assert_eq!(run["suggestion"], Value::Null);

    ai.set_mode(3);
    assert_eq!(upload(&app, "failed-session").await, StatusCode::CREATED);
    let path = run_path("failed-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    let run = wait_for(&app, &path, "failed").await;
    assert!(run["suggestion"].is_null());
    assert!(!run["error"].as_str().unwrap().contains("ai-secret"));
    assert_eq!(cli.prompt_calls(), 0);
    task.abort();
}

#[tokio::test]
async fn submission_classifies_rejections_and_never_retries_ambiguous_delivery() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    cli.set_session(session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    let (base, _ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );

    assert_eq!(upload(&app, "reject-session").await, StatusCode::CREATED);
    let reject_path = run_path("reject-session");
    call(&app, Method::POST, &reject_path, Value::Null, "read-secret").await;
    let rejected = wait_for(&app, &reject_path, "suggested").await;
    let revision = rejected["revision"].as_u64().unwrap();
    cli.set_prompt_failure(400, "secret-cli-output");
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{reject_path}/submit"),
            submit_body(revision, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    let failed = wait_for(&app, &reject_path, "failed").await;
    assert!(failed["error"].as_str().unwrap().contains("HTTP 400"));
    assert!(!failed["error"].as_str().unwrap().contains("secret"));
    assert_eq!(cli.prompt_calls(), 1);
    cli.set_prompt_success("msg_after_retry");
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{reject_path}/submit"),
            submit_body(revision, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    wait_for(&app, &reject_path, "submitted").await;
    assert_eq!(cli.prompt_calls(), 2);

    assert_eq!(upload(&app, "unknown-session").await, StatusCode::CREATED);
    let unknown_path = run_path("unknown-session");
    call(
        &app,
        Method::POST,
        &unknown_path,
        Value::Null,
        "read-secret",
    )
    .await;
    let unknown = wait_for(&app, &unknown_path, "suggested").await;
    let unknown_revision = unknown["revision"].as_u64().unwrap();
    cli.set_prompt_failure(409, "secret-cli-output");
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{unknown_path}/submit"),
            submit_body(unknown_revision, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    let ambiguous = wait_for(&app, &unknown_path, "submit-unknown").await;
    assert!(!ambiguous["error"].as_str().unwrap().contains("secret"));
    let calls = cli.prompt_calls();
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{unknown_path}/submit"),
            submit_body(unknown_revision, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(cli.prompt_calls(), calls);

    assert_eq!(upload(&app, "mismatch-session").await, StatusCode::CREATED);
    let mismatch_path = run_path("mismatch-session");
    call(
        &app,
        Method::POST,
        &mismatch_path,
        Value::Null,
        "read-secret",
    )
    .await;
    let mismatch = wait_for(&app, &mismatch_path, "suggested").await;
    cli.set_prompt_response("msg_wrong_target", "ses_other");
    call(
        &app,
        Method::POST,
        &format!("{mismatch_path}/submit"),
        submit_body(mismatch["revision"].as_u64().unwrap(), "ses_target", true),
        "read-secret",
    )
    .await;
    let ambiguous = wait_for(&app, &mismatch_path, "submit-unknown").await;
    assert!(!ambiguous["error"].as_str().unwrap().contains("secret"));

    assert_eq!(
        upload(&app, "missing-session-id").await,
        StatusCode::CREATED
    );
    let missing_path = run_path("missing-session-id");
    call(
        &app,
        Method::POST,
        &missing_path,
        Value::Null,
        "read-secret",
    )
    .await;
    let missing = wait_for(&app, &missing_path, "suggested").await;
    cli.set_prompt_missing_session("msg_missing_session");
    call(
        &app,
        Method::POST,
        &format!("{missing_path}/submit"),
        submit_body(missing["revision"].as_u64().unwrap(), "ses_target", true),
        "read-secret",
    )
    .await;
    let ambiguous = wait_for(&app, &missing_path, "submit-unknown").await;
    assert!(!ambiguous["error"].as_str().unwrap().contains("secret"));

    assert_eq!(upload(&app, "server-session").await, StatusCode::CREATED);
    let server_path = run_path("server-session");
    call(&app, Method::POST, &server_path, Value::Null, "read-secret").await;
    let server = wait_for(&app, &server_path, "suggested").await;
    cli.set_prompt_failure(500, "secret-cli-output");
    call(
        &app,
        Method::POST,
        &format!("{server_path}/submit"),
        submit_body(server["revision"].as_u64().unwrap(), "ses_target", true),
        "read-secret",
    )
    .await;
    wait_for(&app, &server_path, "submit-unknown").await;
    task.abort();
}

#[tokio::test]
async fn revalidation_rejects_changed_or_ineligible_target_sessions() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    let (base, _ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, false, "Trusted instructions")
        )
        .await,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "verify-session").await, StatusCode::CREATED);
    let path = run_path("verify-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    let run = wait_for(&app, &path, "suggested").await;
    let revision = run["revision"].as_u64().unwrap();
    let other = temp.path().join("work/other");
    fs::create_dir_all(&other).unwrap();
    for target in [
        session_json(
            "ses_target",
            &other,
            Some("Wrong directory"),
            1.0,
            None,
            None,
        ),
        session_json(
            "ses_target",
            &directory,
            Some("Child"),
            1.0,
            Some("ses_parent"),
            None,
        ),
        session_json(
            "ses_target",
            &directory,
            Some("Archived"),
            1.0,
            None,
            Some(1.0),
        ),
        json!({"id": "ses_different", "projectID": "prj_1", "location": {"directory": directory.to_string_lossy()}, "time": {"created": 1, "updated": 2}}),
    ] {
        cli.set_session(target);
        assert_eq!(
            call(
                &app,
                Method::POST,
                &format!("{path}/submit"),
                submit_body(revision, "ses_target", true),
                "read-secret"
            )
            .await
            .0,
            StatusCode::CONFLICT
        );
        assert_eq!(cli.prompt_calls(), 0);
    }
    cli.set_session(session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    ));
    cli.set_prompt_success("msg_verified");
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/submit"),
            submit_body(revision, "ses_target", true),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    wait_for(&app, &path, "submitted").await;
    assert_eq!(cli.prompt_calls(), 1);
    task.abort();
}

#[tokio::test]
async fn settings_require_absolute_directory_prompt_and_default_provider_when_enabled() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    let app = crate::build_app(test_config(&temp)).unwrap();

    let mut missing_provider = settings_json(&directory, &cli, true, false, "Trusted instructions");
    assert_eq!(
        configure(&app, missing_provider.clone()).await,
        StatusCode::BAD_REQUEST
    );
    let (_, error) = call(
        &app,
        Method::POST,
        "/v1/recipes/opencode",
        json!({"settings": missing_provider.clone()}),
        "read-secret",
    )
    .await;
    assert!(error["error"].as_str().unwrap().contains("provider"));

    missing_provider["enabled"] = json!(false);
    missing_provider["directory"] = json!("");
    assert_eq!(configure(&app, missing_provider).await, StatusCode::OK);

    let mut invalid_directory =
        settings_json(&directory, &cli, true, false, "Trusted instructions");
    invalid_directory["directory"] = json!("relative/path");
    assert_eq!(
        configure(&app, invalid_directory).await,
        StatusCode::BAD_REQUEST
    );

    let mut bad_prompt = settings_json(&directory, &cli, false, false, "   ");
    bad_prompt["prompt"] = json!("");
    assert_eq!(configure(&app, bad_prompt).await, StatusCode::BAD_REQUEST);

    let mut too_few = settings_json(&directory, &cli, false, false, "Trusted instructions");
    too_few["maxCandidates"] = json!(4);
    assert_eq!(configure(&app, too_few).await, StatusCode::BAD_REQUEST);

    let mut relative_path = settings_json(&directory, &cli, false, false, "Trusted instructions");
    relative_path["opencodePath"] = json!("bin/opencode");
    assert_eq!(
        configure(&app, relative_path).await,
        StatusCode::BAD_REQUEST
    );

    let mut remote = test_config(&temp);
    remote.bind = "0.0.0.0:8787".to_owned();
    let remote_app = crate::build_app(remote).unwrap();
    assert_eq!(
        configure(
            &remote_app,
            settings_json(&directory, &cli, false, false, "Trusted instructions")
        )
        .await,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn activity_unions_recipe_metadata_without_prompts_or_drafts() {
    let temp = TempDir::new().unwrap();
    let directory = temp.path().join("work/app");
    fs::create_dir_all(&directory).unwrap();
    let cli = FakeCli::new(&temp);
    cli.set_sessions(vec![session_json(
        "ses_target",
        &directory,
        Some("Checkout bug"),
        1_760_000_500.0,
        None,
        None,
    )]);
    cli.set_project_list(project_list());
    let (base, _ai, task) = mock_ai().await;
    let config = test_config(&temp);
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        configure(
            &app,
            settings_json(&directory, &cli, true, false, "ACTIVITY-PROMPT-SECRET")
        )
        .await,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "activity-session").await, StatusCode::CREATED);
    let path = run_path("activity-session");
    call(&app, Method::POST, &path, Value::Null, "read-secret").await;
    wait_for(&app, &path, "suggested").await;
    assert_eq!(upload(&app, "jira-session").await, StatusCode::CREATED);

    let digest: String = Sha256::digest(b"jira-session")
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let jira_run = crate::recipes::RecipeRun {
        session_id: "jira-session".to_owned(),
        recipe: "jira-issue".to_owned(),
        recipe_version: "1.1.0".to_owned(),
        status: crate::recipes::RecipeStatus::Published,
        settings: crate::recipes::RecipeSettings {
            enabled: true,
            auto_draft: false,
            publish_mode: crate::recipes::PublishMode::Review,
            include_images: false,
            attach_images: false,
            prompt: "JIRA-PROMPT-SECRET".to_owned(),
            jira: crate::jira::JiraTarget {
                site_url: "https://team.atlassian.net".to_owned(),
                email: "person@example.com".to_owned(),
                project_key: "TEAM".to_owned(),
                issue_type_id: "10001".to_owned(),
                extra_fields: Default::default(),
            },
        },
        provider: None,
        draft: None,
        available_attachments: Vec::new(),
        attachment_results: Vec::new(),
        revision: 1,
        issue_key: Some("TEAM-123".to_owned()),
        issue_url: Some("https://team.atlassian.net/browse/TEAM-123".to_owned()),
        error: Some("é".repeat(600)),
        created_at_ms: 1,
        updated_at_ms: 1_000,
    };
    crate::private_config::access(
        &temp.path().join("recipe-runs"),
        &format!("jira-{digest}"),
        true,
        |stored: &mut Option<crate::recipes::RecipeRun>| {
            *stored = Some(jira_run);
            Ok(())
        },
    )
    .unwrap();
    fs::write(temp.path().join("recipe-runs/jira-broken.json"), "not json").unwrap();

    assert_eq!(
        call(
            &app,
            Method::GET,
            "/v1/activity",
            Value::Null,
            "ingest-secret"
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (status, activity) = call(
        &app,
        Method::GET,
        "/v1/activity",
        Value::Null,
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let items = activity["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["recipe"], "opencode");
    assert_eq!(items[0]["status"], "suggested");
    assert_eq!(items[0]["title"], "Example");
    assert_eq!(items[0]["opencodeSessionId"], Value::Null);
    let jira = items
        .iter()
        .find(|item| item["recipe"] == "jira-issue")
        .unwrap();
    assert_eq!(jira["status"], "published");
    assert_eq!(jira["issueKey"], "TEAM-123");
    assert_eq!(
        jira["issueUrl"],
        "https://team.atlassian.net/browse/TEAM-123"
    );
    assert_eq!(jira["title"], "Example");
    assert_eq!(jira["error"].as_str().unwrap().chars().count(), 500);
    let serialized = activity.to_string();
    for secret in [
        "ACTIVITY-PROMPT-SECRET",
        "JIRA-PROMPT-SECRET",
        "summaryExcerpt",
        "eligibleSessionIds",
        "candidates",
    ] {
        assert!(!serialized.contains(secret), "activity leaked {secret}");
    }

    let (_, limited) = call(
        &app,
        Method::GET,
        "/v1/activity?limit=1",
        Value::Null,
        "read-secret",
    )
    .await;
    assert_eq!(limited["items"].as_array().unwrap().len(), 1);
    for limit in ["0", "101", "abc"] {
        assert_eq!(
            call(
                &app,
                Method::GET,
                &format!("/v1/activity?limit={limit}"),
                Value::Null,
                "read-secret"
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
    }
    task.abort();
}

#[tokio::test]
async fn activity_uses_lightweight_records_and_ignores_prompt_content() {
    let temp = TempDir::new().unwrap();
    let config = test_config(&temp);
    let runs = temp.path().join("recipe-runs");
    fs::create_dir_all(&runs).unwrap();
    fs::set_permissions(&runs, fs::Permissions::from_mode(0o700)).unwrap();
    let minimal = runs.join("opencode-minimal.json");
    fs::write(
        &minimal,
        serde_json::to_vec(&json!({
            "sessionId": "hl-minimal",
            "recipe": "opencode",
            "status": "suggested",
            "updatedAtMs": 42,
            "promptPreview": "ACTIVITY-PROMPT-SECRET",
            "eligibleSessionIds": ["ses_secret"],
            "candidates": [{"sessionId": "ses_secret"}]
        }))
        .unwrap(),
    )
    .unwrap();
    fs::set_permissions(&minimal, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(runs.join("opencode-broken.json"), b"not json").unwrap();

    let app = crate::build_app(config).unwrap();
    let (status, activity) = call(
        &app,
        Method::GET,
        "/v1/activity?limit=10",
        Value::Null,
        "read-secret",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let items = activity["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["recipe"], "opencode");
    assert_eq!(items[0]["status"], "suggested");
    assert_eq!(items[0]["sessionId"], "hl-minimal");
    assert_eq!(items[0]["title"], Value::Null);
    assert!(!activity.to_string().contains("ACTIVITY-PROMPT-SECRET"));
    assert!(!activity.to_string().contains("ses_secret"));
}

#[tokio::test]
async fn cli_invocation_is_bounded_and_times_out() {
    let temp = TempDir::new().unwrap();
    let script = temp.path().join("slow-opencode");
    fs::write(
        &script,
        "#!/bin/sh\nsleep 2\nprintf '{\"version\":\"2.0.32\"}'\n",
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    let cli = OpenCodeCli::new(Some(script.to_string_lossy().as_ref())).unwrap();
    let failure = cli
        .invoke_with_timeout(
            &["api".to_owned(), "server.info".to_owned()],
            Duration::from_millis(100),
        )
        .await
        .unwrap_err();
    assert_eq!(failure, CliFailure::Timeout);
}
