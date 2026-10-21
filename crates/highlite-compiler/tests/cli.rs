mod common;

use std::io::Write;
use std::process::{Command, Output, Stdio};

use common::{fixtures_dir, normalize_numbers, read_fixture};
use serde_json::Value;

fn capture_json() -> String {
    std::fs::read_to_string(fixtures_dir().join("capture.json")).expect("capture fixture")
}

fn run(args: &[&str], input: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_highlite-compiler"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn compiler binary");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(input.as_bytes())
        .expect("write stdin");
    child.wait_with_output().expect("wait for compiler")
}

fn stdout_json(output: &Output) -> Value {
    assert!(
        output.status.success(),
        "compiler failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("JSON on stdout")
}

fn assert_json_equal(mut actual: Value, mut expected: Value) {
    normalize_numbers(&mut actual);
    normalize_numbers(&mut expected);
    assert_eq!(actual, expected);
}

#[test]
fn compiles_the_shared_fixture_on_stdin() {
    let output = run(&["compile"], &capture_json());
    assert_json_equal(stdout_json(&output), read_fixture("expected-bundle.json"));
}

#[test]
fn exports_the_scrawl_subset_for_the_shared_fixture() {
    let output = run(&["scrawl"], &capture_json());
    assert_json_equal(stdout_json(&output), read_fixture("expected-scrawl.json"));
}

#[test]
fn prints_help_and_rejects_unknown_commands() {
    let help = run(&["--help"], "");
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage:"));

    let unknown = run(&["nope"], "{}");
    assert!(!unknown.status.success());
    assert!(String::from_utf8_lossy(&unknown.stderr).contains("unknown command"));
}

#[test]
fn reports_a_missing_viewport_for_scrawl_export() {
    let mut input: Value = serde_json::from_str(&capture_json()).expect("capture JSON");
    input.as_object_mut().expect("object").remove("viewport");
    input["manifest"]
        .as_object_mut()
        .expect("manifest object")
        .remove("viewport");

    let output = run(&["scrawl"], &serde_json::to_string(&input).unwrap());
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("viewport"));
}
