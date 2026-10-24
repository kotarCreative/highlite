use std::io::Write;
use std::process::{Command, Stdio};

fn command(root: &std::path::Path, args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_highlite-relay"));
    command
        .arg("providers")
        .args(args)
        .arg("--config-dir")
        .arg(root.join("config"));
    command.env_remove("HIGHLITE_RELAY_INGEST_TOKEN");
    command.env("HIGHLITE_CONFIG_DIR", root.join("unused-override"));
    command
}

#[test]
fn connects_lists_selects_and_disconnects_without_running_a_relay() {
    let root = tempfile::tempdir().unwrap();
    let mut child = command(
        root.path(),
        &[
            "connect",
            "work",
            "--kind",
            "openai",
            "--model",
            "test-model",
            "--api-key-stdin",
        ],
    )
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"cli-secret-key\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains("cli-secret-key"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("cli-secret-key"));
    let from_env = Command::new(env!("CARGO_BIN_EXE_highlite-relay"))
        .args(["providers", "list"])
        .env("HIGHLITE_CONFIG_DIR", root.path().join("config"))
        .output()
        .unwrap();
    assert!(from_env.status.success());
    let metadata: serde_json::Value = serde_json::from_slice(&from_env.stdout).unwrap();
    assert_eq!(metadata["providers"][0]["id"], "work");
    assert!(!root.path().join("unused-override").exists());
    let store = highlite_relay::providers::ProviderStore::new(root.path().join("config"));
    assert_eq!(
        store.list().unwrap().default_provider.as_deref(),
        Some("work")
    );
    let output = command(
        root.path(),
        &[
            "connect",
            "local",
            "--kind",
            "openai-compatible",
            "--model",
            "local-model",
            "--base-url",
            "http://localhost:11434/v1",
            "--no-api-key",
        ],
    )
    .output()
    .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = command(root.path(), &["default", "local"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let output = command(root.path(), &["list"]).output().unwrap();
    let list: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(list["defaultProvider"], "local");
    assert_eq!(list["providers"].as_array().unwrap().len(), 2);
    assert!(!String::from_utf8_lossy(&output.stdout).contains("cli-secret-key"));
    assert!(
        command(root.path(), &["disconnect", "work"])
            .output()
            .unwrap()
            .status
            .success()
    );
    assert!(
        !std::fs::read_to_string(root.path().join("config/providers.json"))
            .unwrap()
            .contains("cli-secret-key")
    );
}

#[test]
fn rejects_keys_in_arguments_and_invalid_options() {
    let root = tempfile::tempdir().unwrap();
    for args in [
        vec!["connect", "work", "--api-key", "must-not-echo"],
        vec!["list", "--api-key-stdin"],
        vec!["connect", "work", "--kind", "invalid"],
    ] {
        let output = command(root.path(), &args).output().unwrap();
        assert!(!output.status.success());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("must-not-echo"));
    }
}
