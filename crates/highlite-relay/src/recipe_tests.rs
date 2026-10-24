use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};
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
use base64::{Engine, engine::general_purpose::STANDARD};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tempfile::TempDir;
use tower::ServiceExt;

use crate::providers::{ConnectProvider, ProviderKind, ProviderStore};
use crate::tests::{capture_zip, request, test_config};

#[derive(Default)]
struct MockRemote {
    ai_calls: AtomicUsize,
    jira_calls: AtomicUsize,
    jira_status: AtomicU16,
    invalid_ai: std::sync::atomic::AtomicBool,
    bodies: Mutex<Vec<Value>>,
}

async fn remote(State(state): State<Arc<MockRemote>>, request: axum::extract::Request) -> Response {
    let path = request.uri().path().to_owned();
    let auth = request
        .headers()
        .get(AUTHORIZATION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    let bytes = to_bytes(request.into_body(), 8 * 1024 * 1024)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    state.bodies.lock().unwrap().push(body.clone());
    if path == "/v1/chat/completions" {
        assert_eq!(auth, "Bearer ai-secret");
        state.ai_calls.fetch_add(1, Ordering::SeqCst);
        assert_eq!(body["model"], "test-model");
        assert!(
            body["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains("Custom team guidance")
        );
        assert!(!body.to_string().contains("jira-secret"));
        let content = if state.invalid_ai.load(Ordering::SeqCst) {
            "not valid JSON".to_owned()
        } else {
            json!({"summary": "Captured defect", "description": "Observed behavior\nSteps at #0\nExpected behavior is not evidenced."}).to_string()
        };
        return Json(
            json!({"choices": [{"finish_reason": "stop", "message": {"content": content}}]}),
        )
        .into_response();
    }
    assert_eq!(path, "/rest/api/3/issue");
    assert_eq!(
        auth,
        format!(
            "Basic {}",
            STANDARD.encode("person@example.com:jira-secret")
        )
    );
    state.jira_calls.fetch_add(1, Ordering::SeqCst);
    let status = state.jira_status.load(Ordering::SeqCst);
    if status != 0 && status != 201 {
        return (
            StatusCode::from_u16(status).unwrap(),
            Json(json!({"errorMessages": ["do not expose jira-secret or ai-secret"]})),
        )
            .into_response();
    }
    tokio::time::sleep(Duration::from_millis(20)).await;
    (
        StatusCode::CREATED,
        Json(json!({"key": "TEAM-123", "id": "123"})),
    )
        .into_response()
}

async fn mock_remote() -> (String, Arc<MockRemote>, tokio::task::JoinHandle<()>) {
    let state = Arc::new(MockRemote::default());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = Router::new().fallback(remote).with_state(state.clone());
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (format!("http://{address}"), state, task)
}

fn settings(base: &str, automatic: bool, publish_mode: &str) -> Value {
    json!({"enabled": true, "autoDraft": automatic, "publishMode": publish_mode, "includeImages": false, "prompt": "Custom team guidance: focus on reproduction steps", "jira": {
        "siteUrl": base, "email": "person@example.com", "projectKey": "TEAM", "issueTypeId": "10001", "extraFields": {"labels": ["highlite"]},
    }})
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
    assert!(!String::from_utf8_lossy(&bytes).contains("jira-secret"));
    assert!(!String::from_utf8_lossy(&bytes).contains("ai-secret"));
    (status, serde_json::from_slice(&bytes).unwrap())
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

async fn wait_for(app: &Router, path: &str, status: &str) -> Value {
    for _ in 0..200 {
        let (code, response) = call(app, Method::GET, path, Value::Null, "read-secret").await;
        assert_eq!(code, StatusCode::OK);
        if response["run"]["status"] == status {
            return response["run"].clone();
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("recipe did not reach {status}");
}

fn provider(root: &std::path::Path, base: &str) {
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

#[tokio::test]
async fn automatically_drafts_then_publishes_only_the_reviewed_revision_once() {
    let temp = TempDir::new().unwrap();
    let config = test_config(&temp);
    let (base, remote, task) = mock_remote().await;
    provider(&config.config_dir, &base);
    let app = crate::build_app(config.clone()).unwrap();
    assert_eq!(upload(&app, "before-enabled").await, StatusCode::CREATED);
    assert_eq!(remote.ai_calls.load(Ordering::SeqCst), 0);
    let input = json!({"settings": settings(&base, true, "review"), "apiToken": "jira-secret"});
    for token in ["ingest-secret", "wrong"] {
        assert_eq!(
            call(
                &app,
                Method::POST,
                "/v1/recipes/jira-issue",
                input.clone(),
                token
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        call(
            &app,
            Method::POST,
            "/v1/recipes/jira-issue",
            input,
            "read-secret"
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "jira-session").await, StatusCode::CREATED);
    let path = "/v1/sessions/jira-session/recipes/jira-issue";
    let draft = wait_for(&app, path, "draft").await;
    assert_eq!(draft["provider"]["id"], "default");
    assert_eq!(draft["draft"]["summary"], "Captured defect");
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 0);
    assert_eq!(upload(&app, "jira-session").await, StatusCode::OK);
    assert_eq!(remote.ai_calls.load(Ordering::SeqCst), 1);
    let (code, edited) = call(&app, Method::POST, &format!("{path}/draft"), json!({"revision": draft["revision"], "draft": {"summary": "Reviewed defect", "description": "Reviewed reproduction steps\nMissing evidence noted."}}), "read-secret").await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/publish"),
            json!({"revision": draft["revision"]}),
            "read-secret"
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let approval = json!({"revision": edited["revision"]});
    let publish_path = format!("{path}/publish");
    let (first, second) = tokio::join!(
        call(
            &app,
            Method::POST,
            &publish_path,
            approval.clone(),
            "read-secret"
        ),
        call(
            &app,
            Method::POST,
            &publish_path,
            approval.clone(),
            "read-secret"
        )
    );
    assert!(first.0 == StatusCode::ACCEPTED || second.0 == StatusCode::ACCEPTED);
    let published = wait_for(&app, path, "published").await;
    assert_eq!(published["issueKey"], "TEAM-123");
    assert_eq!(
        call(&app, Method::POST, &publish_path, approval, "read-secret")
            .await
            .0,
        StatusCode::ACCEPTED
    );
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 1);
    let bodies = remote.bodies.lock().unwrap();
    let issue = bodies
        .iter()
        .find(|body| body["fields"].is_object())
        .unwrap();
    assert_eq!(issue["fields"]["summary"], "Reviewed defect");
    assert_eq!(issue["fields"]["description"]["type"], "doc");
    assert_eq!(issue["fields"]["issuetype"]["id"], "10001");
    assert_eq!(issue["fields"]["labels"][0], "highlite");
    assert_eq!(issue["properties"][0]["value"]["sessionId"], "jira-session");
    assert!(!issue.to_string().contains("Custom team guidance"));
    task.abort();
}

#[tokio::test]
async fn automatic_mode_publishes_without_review_and_keeps_rejections_actionable() {
    let temp = TempDir::new().unwrap();
    let config = test_config(&temp);
    let (base, remote, task) = mock_remote().await;
    provider(&config.config_dir, &base);
    let app = crate::build_app(config).unwrap();
    assert_eq!(
        call(
            &app,
            Method::POST,
            "/v1/recipes/jira-issue",
            json!({"settings": settings(&base, true, "automatic"), "apiToken": "jira-secret"}),
            "read-secret",
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(upload(&app, "auto-publish").await, StatusCode::CREATED);
    let path = "/v1/sessions/auto-publish/recipes/jira-issue";
    let published = wait_for(&app, path, "published").await;
    assert_eq!(published["issueKey"], "TEAM-123");
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 1);
    assert_eq!(published["draft"]["summary"], "Captured defect");

    remote.jira_status.store(400, Ordering::SeqCst);
    assert_eq!(upload(&app, "auto-rejected").await, StatusCode::CREATED);
    let rejected_path = "/v1/sessions/auto-rejected/recipes/jira-issue";
    let rejected = wait_for(&app, rejected_path, "draft").await;
    assert_eq!(rejected["draft"]["summary"], "Captured defect");
    assert!(rejected["error"].as_str().unwrap().contains("HTTP 400"));
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 2);

    remote.jira_status.store(201, Ordering::SeqCst);
    let approval = json!({"revision": rejected["revision"]});
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{rejected_path}/publish"),
            approval,
            "read-secret",
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    wait_for(&app, rejected_path, "published").await;
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 3);
    task.abort();
}

#[tokio::test]
async fn rejects_invalid_ai_and_does_not_retry_ambiguous_jira_publication() {
    let temp = TempDir::new().unwrap();
    let config = test_config(&temp);
    let (base, remote, task) = mock_remote().await;
    provider(&config.config_dir, &base);
    let app = crate::build_app(config.clone()).unwrap();
    assert_eq!(
        call(
            &app,
            Method::POST,
            "/v1/recipes/jira-issue",
            json!({"settings": settings(&base, true, "review"), "apiToken": "jira-secret"}),
            "read-secret"
        )
        .await
        .0,
        StatusCode::OK
    );
    remote.invalid_ai.store(true, Ordering::SeqCst);
    assert_eq!(upload(&app, "failed-ai").await, StatusCode::CREATED);
    let path = "/v1/sessions/failed-ai/recipes/jira-issue";
    let failed = wait_for(&app, path, "failed").await;
    assert!(failed["draft"].is_null());
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 0);
    remote.invalid_ai.store(false, Ordering::SeqCst);
    assert_eq!(
        call(&app, Method::POST, path, Value::Null, "read-secret")
            .await
            .0,
        StatusCode::ACCEPTED
    );
    let draft = wait_for(&app, path, "draft").await;
    remote.jira_status.store(400, Ordering::SeqCst);
    let approval = json!({"revision": draft["revision"]});
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/publish"),
            approval.clone(),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    let rejected = wait_for(&app, path, "draft").await;
    assert!(rejected["error"].as_str().unwrap().contains("HTTP 400"));
    remote.jira_status.store(500, Ordering::SeqCst);
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/publish"),
            approval.clone(),
            "read-secret"
        )
        .await
        .0,
        StatusCode::ACCEPTED
    );
    wait_for(&app, path, "publish-unknown").await;
    assert_eq!(
        call(
            &app,
            Method::POST,
            &format!("{path}/publish"),
            approval,
            "read-secret"
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(remote.jira_calls.load(Ordering::SeqCst), 2);
    assert_eq!(
        call(&app, Method::POST, path, Value::Null, "read-secret")
            .await
            .1["status"],
        "publish-unknown"
    );
    assert_eq!(remote.ai_calls.load(Ordering::SeqCst), 2);
    task.abort();
}
