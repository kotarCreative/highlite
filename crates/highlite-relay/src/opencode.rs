//! Authenticated, bounded invocation of the OpenCode V2 CLI.
//!
//! The relay never talks to OpenCode's HTTP service directly and never reads its
//! configuration or credentials. The installed `opencode api` CLI performs its own
//! discovery and authentication; this module only runs it without a shell and
//! classifies its bounded result. Raw stdout/stderr never leaves this module.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(20);
const PROMPT_TIMEOUT: Duration = Duration::from_secs(30);
const SESSION_GET_TIMEOUT: Duration = Duration::from_secs(10);
const STDOUT_LIMIT: usize = 2 * 1024 * 1024;
const STDERR_LIMIT: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CliFailure {
    Spawn,
    Timeout,
    OutputTooLarge,
    Exit { http_status: Option<u16> },
    InvalidJson,
}

impl CliFailure {
    /// Only an explicit HTTP status on stderr is trusted for classification.
    pub(crate) fn is_clear_rejection(&self) -> bool {
        matches!(
            self,
            Self::Exit {
                http_status: Some(400 | 401 | 403 | 404)
            }
        )
    }

    pub(crate) fn discovery_message(&self) -> String {
        match self {
            Self::Spawn => {
                "could not start the OpenCode CLI; check that it is installed and authenticated"
                    .to_owned()
            }
            Self::Timeout => "the OpenCode CLI did not respond in time".to_owned(),
            Self::OutputTooLarge | Self::InvalidJson => {
                "the OpenCode CLI returned an unexpected response".to_owned()
            }
            Self::Exit { .. } => "the OpenCode CLI reported an error".to_owned(),
        }
    }
}

/// A resolved CLI executable. The path is validated before every invocation.
#[derive(Clone, Debug)]
pub(crate) struct OpenCodeCli {
    path: String,
}

impl OpenCodeCli {
    pub(crate) fn new(configured_path: Option<&str>) -> Result<Self, String> {
        let path = match configured_path {
            Some(path) => path.to_owned(),
            None => std::env::var("HIGHLITE_OPENCODE_BIN")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "opencode".to_owned()),
        };
        validate_path(&path)?;
        Ok(Self { path })
    }

    pub(crate) async fn server_info(&self) -> Result<ServerInfo, String> {
        let value = self
            .invoke(
                &["api".to_owned(), "server.info".to_owned()],
                DISCOVERY_TIMEOUT,
            )
            .await
            .map_err(|failure| failure.discovery_message())?;
        let info = object_data(&value)
            .ok_or_else(|| "the OpenCode CLI returned an unexpected response".to_owned())?;
        let version = info["version"]
            .as_str()
            .filter(|version| !version.is_empty() && version.len() <= 64)
            .ok_or_else(|| "the OpenCode CLI did not report a version".to_owned())?
            .to_owned();
        if major_version(&version) != Some(2) {
            return Err(format!(
                "OpenCode CLI major version 2 is required (found {version})"
            ));
        }
        Ok(ServerInfo { version })
    }

    pub(crate) async fn list_projects(&self) -> Result<Vec<ProjectInfo>, String> {
        let value = self
            .invoke(
                &["api".to_owned(), "project.list".to_owned()],
                DISCOVERY_TIMEOUT,
            )
            .await
            .map_err(|failure| failure.discovery_message())?;
        let entries = array_data(&value)
            .ok_or_else(|| "the OpenCode CLI returned an unexpected response".to_owned())?;
        Ok(entries
            .iter()
            .filter_map(|entry| serde_json::from_value::<ProjectInfo>(entry.clone()).ok())
            .filter(|project| !project.id.is_empty() && project.id.len() <= 256)
            .collect())
    }

    pub(crate) async fn list_sessions(
        &self,
        directory: &str,
        limit: u32,
    ) -> Result<Vec<SessionInfo>, String> {
        let value = self
            .invoke(
                &[
                    "api".to_owned(),
                    "session.list".to_owned(),
                    "--param".to_owned(),
                    format!("directory={directory}"),
                    "--param".to_owned(),
                    "archived=false".to_owned(),
                    "--param".to_owned(),
                    "parentID=null".to_owned(),
                    "--param".to_owned(),
                    "order=desc".to_owned(),
                    "--param".to_owned(),
                    format!("limit={limit}"),
                ],
                DISCOVERY_TIMEOUT,
            )
            .await
            .map_err(|failure| failure.discovery_message())?;
        let entries = value["data"]
            .as_array()
            .ok_or_else(|| "the OpenCode CLI returned unexpected session metadata".to_owned())?;
        Ok(entries
            .iter()
            .filter_map(|entry| serde_json::from_value::<SessionInfo>(entry.clone()).ok())
            .collect())
    }

    pub(crate) async fn get_session(&self, session_id: &str) -> Result<SessionInfo, String> {
        let value = self
            .invoke(
                &[
                    "api".to_owned(),
                    "session.get".to_owned(),
                    "--param".to_owned(),
                    format!("sessionID={session_id}"),
                ],
                SESSION_GET_TIMEOUT,
            )
            .await
            .map_err(|failure| failure.discovery_message())?;
        let info = object_data(&value)
            .ok_or_else(|| "the OpenCode CLI returned unexpected session metadata".to_owned())?;
        let session: SessionInfo = serde_json::from_value(info.clone())
            .map_err(|_| "the OpenCode CLI returned unexpected session metadata".to_owned())?;
        if session.id != session_id {
            return Err("the OpenCode CLI returned a different session".to_owned());
        }
        Ok(session)
    }

    /// Send exactly one prompt. Ambiguous failures are never retried here.
    ///
    /// The V2 schema requires `{ data: { id, sessionID, time, type, payload, delivery } }`.
    /// A missing or mismatched `sessionID` is a malformed success, not proof of delivery.
    pub(crate) async fn prompt(&self, target: &str, body: &Value) -> PromptOutcome {
        let data = serde_json::to_string(body).unwrap_or_else(|_| "{}".to_owned());
        match self
            .invoke(
                &[
                    "api".to_owned(),
                    "session.prompt".to_owned(),
                    "--param".to_owned(),
                    format!("sessionID={target}"),
                    "--data".to_owned(),
                    data,
                ],
                PROMPT_TIMEOUT,
            )
            .await
        {
            Ok(value) => {
                let data = &value["data"];
                let message_id = data["id"]
                    .as_str()
                    .filter(|id| id.starts_with("msg_") && id.len() <= 128)
                    .map(str::to_owned);
                let target_matches = data["sessionID"].as_str() == Some(target);
                match (target_matches, message_id) {
                    (true, Some(message_id)) => PromptOutcome::Submitted { message_id },
                    _ => PromptOutcome::Unknown(
                        "OpenCode accepted the request but did not confirm the selected session and message. Check the target session in OpenCode before taking further action; it will not be retried automatically."
                            .to_owned(),
                    ),
                }
            }
            Err(CliFailure::Spawn) => PromptOutcome::Rejected(
                "could not start the OpenCode CLI, so no prompt was sent. Restore the CLI path and retry."
                    .to_owned(),
            ),
            Err(failure) if failure.is_clear_rejection() => {
                let status = match failure {
                    CliFailure::Exit {
                        http_status: Some(status),
                    } => status,
                    _ => 0,
                };
                PromptOutcome::Rejected(format!(
                    "OpenCode rejected the prompt (HTTP {status}). Check the target session and try again."
                ))
            }
            Err(_) => PromptOutcome::Unknown(
                "OpenCode did not confirm delivery. Check the target session in OpenCode before taking further action; the prompt will not be retried automatically."
                    .to_owned(),
            ),
        }
    }

    async fn invoke(&self, args: &[String], timeout: Duration) -> Result<Value, CliFailure> {
        self.invoke_with_timeout(args, timeout).await
    }

    /// Separated so tests can exercise the timeout without a 30 second wait.
    pub(crate) async fn invoke_with_timeout(
        &self,
        args: &[String],
        timeout: Duration,
    ) -> Result<Value, CliFailure> {
        let mut command = Command::new(&self.path);
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .env("NO_COLOR", "1");
        for (key, _) in std::env::vars_os() {
            let Some(key) = key.to_str() else {
                continue;
            };
            if key.starts_with("HIGHLITE_RELAY_") || key == "HIGHLITE_CONFIG_DIR" {
                command.env_remove(key);
            }
        }
        let mut child = command.spawn().map_err(|_| CliFailure::Spawn)?;
        let mut stdout = child.stdout.take().ok_or(CliFailure::Spawn)?;
        let mut stderr = child.stderr.take().ok_or(CliFailure::Spawn)?;
        let joined = tokio::time::timeout(timeout, async {
            tokio::join!(
                capture(&mut stdout, STDOUT_LIMIT),
                capture(&mut stderr, STDERR_LIMIT),
                child.wait(),
            )
        })
        .await;
        let (stdout, stderr, status) = match joined {
            Ok(result) => result,
            Err(_) => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                return Err(CliFailure::Timeout);
            }
        };
        if stdout.1 {
            return Err(CliFailure::OutputTooLarge);
        }
        let success = status.map(|status| status.success()).unwrap_or(false);
        if !success {
            return Err(CliFailure::Exit {
                http_status: parse_http_status(&stderr.0),
            });
        }
        serde_json::from_slice(&stdout.0).map_err(|_| CliFailure::InvalidJson)
    }
}

pub(crate) enum PromptOutcome {
    Submitted { message_id: String },
    Rejected(String),
    Unknown(String),
}

#[derive(Debug, Clone)]
pub(crate) struct ServerInfo {
    pub version: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectInfo {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub canonical: String,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SessionInfo {
    pub id: String,
    #[serde(rename = "parentID", default)]
    pub parent_id: Option<String>,
    #[serde(rename = "projectID", default)]
    pub project_id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub location: Option<SessionLocation>,
    #[serde(default)]
    pub time: Option<SessionTime>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct SessionLocation {
    #[serde(default)]
    pub directory: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(crate) struct SessionTime {
    #[serde(default)]
    pub created: Option<f64>,
    #[serde(default)]
    pub updated: Option<f64>,
    #[serde(default)]
    pub archived: Option<f64>,
}

impl SessionInfo {
    pub(crate) fn directory(&self) -> &str {
        self.location
            .as_ref()
            .map(|location| location.directory.as_str())
            .unwrap_or_default()
    }

    pub(crate) fn is_archived(&self) -> bool {
        self.time
            .as_ref()
            .is_some_and(|time| time.archived.is_some())
    }

    pub(crate) fn created_at_ms(&self) -> u64 {
        normalize_epoch_ms(self.time.as_ref().and_then(|time| time.created))
    }

    pub(crate) fn updated_at_ms(&self) -> u64 {
        normalize_epoch_ms(self.time.as_ref().and_then(|time| time.updated))
    }
}

fn object_data(value: &Value) -> Option<&Value> {
    value
        .get("data")
        .filter(|data| data.is_object())
        .or_else(|| value.is_object().then_some(value))
}

fn array_data(value: &Value) -> Option<&Vec<Value>> {
    value
        .as_array()
        .or_else(|| value.get("data").and_then(Value::as_array))
}

fn major_version(version: &str) -> Option<u32> {
    version
        .trim()
        .trim_start_matches('v')
        .split('.')
        .next()
        .and_then(|major| major.parse().ok())
}

fn normalize_epoch_ms(value: Option<f64>) -> u64 {
    let Some(value) = value.filter(|value| value.is_finite() && *value > 0.0) else {
        return 0;
    };
    if value < 100_000_000_000.0 {
        (value * 1000.0) as u64
    } else {
        value as u64
    }
}

fn parse_http_status(stderr: &[u8]) -> Option<u16> {
    String::from_utf8_lossy(stderr).lines().find_map(|line| {
        let line = line.trim_end_matches('\r');
        let rest = line.strip_prefix("HTTP ")?;
        let bytes = rest.as_bytes();
        if bytes.len() < 3 || !bytes[..3].iter().all(u8::is_ascii_digit) {
            return None;
        }
        if bytes
            .get(3)
            .is_some_and(|next| next.is_ascii_alphanumeric() || *next == b'_')
        {
            return None;
        }
        let code = rest[..3].parse::<u16>().ok()?;
        (100..=599).contains(&code).then_some(code)
    })
}

async fn capture<R>(mut reader: R, limit: usize) -> (Vec<u8>, bool)
where
    R: AsyncRead + Unpin,
{
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    let mut total = 0usize;
    loop {
        match reader.read(&mut buffer).await {
            Ok(0) => break,
            Ok(read) => {
                total += read;
                if bytes.len() < limit {
                    let take = (limit - bytes.len()).min(read);
                    bytes.extend_from_slice(&buffer[..take]);
                }
            }
            Err(_) => break,
        }
    }
    (bytes, total > limit)
}

pub(crate) fn validate_path(path: &str) -> Result<(), String> {
    if path.is_empty() || path.len() > 1024 {
        return Err("the OpenCode CLI path must contain 1-1024 characters".to_owned());
    }
    if path
        .chars()
        .any(|character| matches!(character, '\0' | '\n' | '\r'))
    {
        return Err("the OpenCode CLI path contains an invalid character".to_owned());
    }
    if path.contains('/') && !Path::new(path).is_absolute() {
        return Err("an OpenCode CLI path containing '/' must be absolute".to_owned());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_cli_paths_before_spawning() {
        assert!(validate_path("opencode").is_ok());
        assert!(validate_path("/opt/homebrew/bin/opencode").is_ok());
        assert!(validate_path("").is_err());
        assert!(validate_path("bin/opencode").is_err());
        assert!(validate_path("opencode\n").is_err());
        assert!(validate_path(&"x".repeat(1025)).is_err());
    }

    #[test]
    fn normalizes_seconds_and_milliseconds() {
        assert_eq!(normalize_epoch_ms(Some(1_760_000_000.0)), 1_760_000_000_000);
        assert_eq!(
            normalize_epoch_ms(Some(1_760_000_000_000.0)),
            1_760_000_000_000
        );
        assert_eq!(normalize_epoch_ms(None), 0);
    }

    #[test]
    fn classifies_only_explicit_clear_rejections() {
        for status in [400, 401, 403, 404] {
            assert!(
                CliFailure::Exit {
                    http_status: Some(status)
                }
                .is_clear_rejection()
            );
        }
        for status in [409, 429, 500, 503] {
            assert!(
                !CliFailure::Exit {
                    http_status: Some(status)
                }
                .is_clear_rejection()
            );
        }
        assert!(!CliFailure::Timeout.is_clear_rejection());
        assert!(!CliFailure::Exit { http_status: None }.is_clear_rejection());
    }

    #[test]
    fn reads_the_http_status_only_from_strict_stderr_lines() {
        assert_eq!(parse_http_status(b"HTTP 404\nbody follows"), Some(404));
        assert_eq!(parse_http_status(b"noise\nHTTP 500"), Some(500));
        assert_eq!(parse_http_status(b"{\"error\":\"HTTP 400\"}"), None);
        assert_eq!(parse_http_status(b" HTTP 400"), None);
        assert_eq!(parse_http_status(b"HTTP 4000"), None);
        assert_eq!(parse_http_status(b"HTTP 400x"), None);
        assert_eq!(parse_http_status(b""), None);
    }
}
