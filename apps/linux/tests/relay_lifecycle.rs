//! End-to-end checks against a real, isolated `highlite-relay` child.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use highlite_desktop::config::{ALLOWED_ORIGINS_KEY, BIND_KEY, DesktopPaths, READ_TOKEN_KEY};
use highlite_desktop::http;
use highlite_desktop::relay::{RelayPoll, RelayProcess, locate_relay_binary};
use tempfile::TempDir;

fn relay_binary() -> PathBuf {
    locate_relay_binary(None).expect(
        "highlite-relay was not found; run `cargo build -p highlite-relay` or set HIGHLITE_RELAY_BIN",
    )
}

fn wait_until_ready(process: &mut RelayProcess) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        match process.poll() {
            RelayPoll::Ready => return,
            RelayPoll::Failed(detail) => panic!("relay failed to start: {detail}"),
            RelayPoll::Starting if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(100));
            }
            RelayPoll::Starting => panic!("relay did not become ready before the test deadline"),
        }
    }
}

#[test]
fn starts_private_relay_with_read_and_ingest_separation() {
    let temp = TempDir::new().unwrap();
    let paths = DesktopPaths::new(temp.path().join("config"), temp.path().join("data")).unwrap();
    let binary = relay_binary();
    let mut process = RelayProcess::spawn(&paths, &binary, None).unwrap();
    wait_until_ready(&mut process);

    let port = process.info().port;
    let tokens = process.tokens().clone();
    assert_eq!(tokens.read.len(), 64);
    assert_eq!(tokens.ingest.len(), 64);

    let health = http::get_loopback(port, "/healthz", None, Duration::from_secs(2)).unwrap();
    assert_eq!(health.status, 200);
    assert!(health.body.contains("\"status\":\"ok\""), "{}", health.body);

    let read = http::get_loopback(
        port,
        "/v1/sessions",
        Some(&tokens.read),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(read.status, 200, "{}", read.body);

    let ingest_token_on_read = http::get_loopback(
        port,
        "/v1/sessions",
        Some(&tokens.ingest),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(ingest_token_on_read.status, 401);

    let read_token_on_ingest = http::send(
        port,
        "POST",
        "/v1/sessions",
        Some(&tokens.read),
        &[("Content-Type", "application/zip")],
        &[],
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(read_token_on_ingest.status, 401);

    let unauthenticated =
        http::get_loopback(port, "/v1/sessions", None, Duration::from_secs(2)).unwrap();
    assert_eq!(unauthenticated.status, 401);

    let env = fs::read_to_string(&paths.env_file).unwrap();
    assert!(env.contains(&format!("{BIND_KEY}=127.0.0.1:{port}")));
    assert!(env.contains(&format!("{ALLOWED_ORIGINS_KEY}=http://127.0.0.1:{port}")));
    assert!(env.contains(&format!("{READ_TOKEN_KEY}={}", tokens.read)));
    assert_eq!(
        fs::metadata(&paths.env_file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&paths.config_dir)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&paths.data_dir).unwrap().permissions().mode() & 0o777,
        0o700
    );

    let logs = process.logs().join("\n");
    assert!(!logs.contains(&tokens.read), "read token leaked into logs");
    assert!(
        !logs.contains(&tokens.ingest),
        "ingest token leaked into logs"
    );

    let pid = process.info().pid;
    process.stop();
    assert!(
        !Path::new(&format!("/proc/{pid}")).exists(),
        "owned relay survived stop"
    );
    assert_eq!(
        fs::metadata(paths.env_file).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

#[test]
fn missing_binary_is_reported_without_spawning() {
    let temp = TempDir::new().unwrap();
    let paths = DesktopPaths::new(temp.path().join("config"), temp.path().join("data")).unwrap();
    let missing = temp.path().join("does-not-exist");
    let error = match RelayProcess::spawn(&paths, &missing, None) {
        Ok(_) => panic!("missing binary unexpectedly started"),
        Err(error) => error,
    };
    assert!(error.contains("was not found"), "{error}");
    assert!(!paths.env_file.exists());
}

#[test]
fn port_conflict_fails_without_orphaning_a_process() {
    let temp = TempDir::new().unwrap();
    let paths = DesktopPaths::new(temp.path().join("config"), temp.path().join("data")).unwrap();
    let occupied = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = occupied.local_addr().unwrap().port();
    let mut process = RelayProcess::spawn(&paths, &relay_binary(), Some(port)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match process.poll() {
            RelayPoll::Failed(detail) => {
                assert!(
                    detail.contains("exited") || detail.to_lowercase().contains("address"),
                    "{detail}"
                );
                break;
            }
            RelayPoll::Ready => panic!("relay bound an occupied port"),
            RelayPoll::Starting if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(100));
            }
            RelayPoll::Starting => panic!("relay startup timeout did not report the conflict"),
        }
    }
    let pid = process.info().pid;
    process.stop();
    assert!(!Path::new(&format!("/proc/{pid}")).exists());
    drop(occupied);
}

#[test]
fn preserves_tokens_across_restart_and_rewrites_the_port() {
    let temp = TempDir::new().unwrap();
    let paths = DesktopPaths::new(temp.path().join("config"), temp.path().join("data")).unwrap();
    let binary = relay_binary();

    let mut first = RelayProcess::spawn(&paths, &binary, None).unwrap();
    wait_until_ready(&mut first);
    let first_tokens = first.tokens().clone();
    first.stop();

    let mut second = RelayProcess::spawn(&paths, &binary, None).unwrap();
    wait_until_ready(&mut second);
    assert_eq!(second.tokens(), &first_tokens);
    let env = fs::read_to_string(&paths.env_file).unwrap();
    assert!(env.contains(&format!("{BIND_KEY}=127.0.0.1:{}", second.info().port)));
    let auth = http::get_loopback(
        second.info().port,
        "/v1/sessions",
        Some(&second.tokens().read),
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(auth.status, 200);
    second.stop();
}
