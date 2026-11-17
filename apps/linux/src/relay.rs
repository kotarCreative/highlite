//! Locating and supervising the owned `highlite-relay` child process.

use std::collections::VecDeque;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::config::{self, DesktopPaths, RelayTokens};
use crate::http;

const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const PROBE_TIMEOUT: Duration = Duration::from_millis(300);
const STOP_GRACE: Duration = Duration::from_secs(3);
const MAX_LOGS: usize = 80;

#[derive(Debug, PartialEq, Eq)]
pub enum RelayPoll {
    Starting,
    Ready,
    Failed(String),
}

/// Resolve the relay binary in an explicit order that works for source runs and
/// for a `~/.local` install. It never attaches to a running process.
pub fn locate_relay_binary(explicit: Option<&str>) -> Option<PathBuf> {
    let executable = |path: &Path| {
        fs::metadata(path)
            .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    };
    let resolve = |raw: &str| {
        let raw = raw.trim();
        if raw.is_empty() {
            return None;
        }
        let path = Path::new(raw);
        if raw.contains('/') {
            return executable(path).then(|| path.to_path_buf());
        }
        env::split_paths(&env::var_os("PATH").unwrap_or_default())
            .map(|directory| directory.join(raw))
            .find(|candidate| executable(candidate))
    };

    if let Some(path) = explicit.and_then(resolve) {
        return Some(path);
    }
    if let Some(path) = env::var("HIGHLITE_RELAY_BIN")
        .ok()
        .and_then(|value| resolve(&value))
    {
        return Some(path);
    }

    if let Ok(current) = env::current_exe()
        && let Some(parent) = current.parent()
    {
        for candidate in [
            parent.join("highlite-relay"),
            parent.join("../lib/highlite/highlite-relay"),
            parent.join("../libexec/highlite/highlite-relay"),
        ] {
            if executable(&candidate) {
                return Some(candidate);
            }
        }
        let mut directory = parent.to_path_buf();
        for _ in 0..7 {
            for profile in ["release", "debug"] {
                let candidate = directory
                    .join("target")
                    .join(profile)
                    .join("highlite-relay");
                if executable(&candidate) {
                    return Some(candidate);
                }
            }
            let Some(parent) = directory.parent() else {
                break;
            };
            directory = parent.to_path_buf();
        }
    }

    resolve("highlite-relay")
}

#[derive(Clone, Debug)]
pub struct RelayInfo {
    pub port: u16,
    pub pid: u32,
    pub binary: PathBuf,
}

/// An owned relay child. Dropping it asks the child to terminate; it never
/// touches a process the app did not spawn.
pub struct RelayProcess {
    child: Child,
    info: RelayInfo,
    tokens: RelayTokens,
    logs: Arc<Mutex<VecDeque<String>>>,
    ready: bool,
    deadline: Instant,
}

impl RelayProcess {
    pub fn spawn(
        paths: &DesktopPaths,
        binary: &Path,
        port_override: Option<u16>,
    ) -> Result<Self, String> {
        paths.prepare()?;
        if !binary.is_file() {
            return Err(format!(
                "highlite-relay was not found at {}. Build it with `cargo build -p highlite-relay` or set HIGHLITE_RELAY_BIN.",
                binary.display()
            ));
        }
        let metadata = fs::metadata(binary)
            .map_err(|error| format!("could not inspect {}: {error}", binary.display()))?;
        if metadata.permissions().mode() & 0o111 == 0 {
            return Err(format!("{} is not executable.", binary.display()));
        }

        let port = match port_override {
            Some(port) if port != 0 => port,
            Some(_) => return Err("relay port must not be zero".to_owned()),
            None => config::pick_loopback_port()?,
        };
        let environment = config::write_relay_env(paths, port)?;
        let secrets = vec![
            environment.tokens.read.clone(),
            environment.tokens.ingest.clone(),
        ];

        let mut command = Command::new(binary);
        command
            .arg("--env-file")
            .arg(&paths.env_file)
            .arg("--bind")
            .arg(format!("127.0.0.1:{port}"))
            .arg("--data-dir")
            .arg(&paths.data_dir)
            .arg("--config-dir")
            .arg(&paths.config_dir)
            .arg("--ui")
            .current_dir(&paths.data_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .env("NO_COLOR", "1");

        // Ambient HIGHLITE_* values would override the app-owned env file.
        for (name, _) in env::vars_os() {
            if name.to_string_lossy().starts_with("HIGHLITE_") {
                command.env_remove(name);
            }
        }

        // The relay's own files stay private, and it cannot outlive a crashed
        // desktop shell.
        unsafe {
            command.pre_exec(|| {
                libc::umask(0o077);
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let mut child = command.spawn().map_err(|error| {
            format!(
                "could not start {}: {error}. Build it with `cargo build -p highlite-relay`.",
                binary.display()
            )
        })?;
        let pid = child.id();
        let logs = Arc::new(Mutex::new(VecDeque::new()));
        if let Some(stderr) = child.stderr.take() {
            let logs = Arc::clone(&logs);
            let secrets = secrets.clone();
            let _ = thread::Builder::new()
                .name("highlite-relay-log".to_owned())
                .spawn(move || {
                    for line in BufReader::new(stderr).lines() {
                        let Ok(line) = line else { break };
                        let sanitized = config::redact_secrets(
                            &line,
                            &secrets.iter().map(String::as_str).collect::<Vec<_>>(),
                        );
                        if sanitized.trim().is_empty() {
                            continue;
                        }
                        eprintln!("[relay] {sanitized}");
                        let mut logs = logs.lock().unwrap_or_else(|poison| poison.into_inner());
                        if logs.len() == MAX_LOGS {
                            logs.pop_front();
                        }
                        logs.push_back(sanitized);
                    }
                });
        }

        Ok(Self {
            child,
            info: RelayInfo {
                port,
                pid,
                binary: binary.to_path_buf(),
            },
            tokens: environment.tokens,
            logs,
            ready: false,
            deadline: Instant::now() + STARTUP_TIMEOUT,
        })
    }

    pub fn info(&self) -> &RelayInfo {
        &self.info
    }

    pub fn tokens(&self) -> &RelayTokens {
        &self.tokens
    }

    pub fn logs(&self) -> Vec<String> {
        self.logs
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .iter()
            .cloned()
            .collect()
    }

    pub fn dashboard_url(&self) -> String {
        format!(
            "http://127.0.0.1:{}/#token={}",
            self.info.port,
            encode_fragment(&self.tokens.read)
        )
    }

    /// Check for readiness, token authentication, or an early child exit.
    pub fn poll(&mut self) -> RelayPoll {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                return RelayPoll::Failed(format!(
                    "relay exited unexpectedly ({status}).{}",
                    self.last_log_suffix()
                ));
            }
            Ok(None) => {}
            Err(error) => {
                return RelayPoll::Failed(format!("could not inspect relay state: {error}"));
            }
        }

        if self.ready {
            return RelayPoll::Ready;
        }
        if Instant::now() > self.deadline {
            return RelayPoll::Failed(format!(
                "relay did not become ready within {} seconds.{}",
                STARTUP_TIMEOUT.as_secs(),
                self.last_log_suffix()
            ));
        }

        match http::get_loopback(self.info.port, "/healthz", None, PROBE_TIMEOUT) {
            Ok(response) if response.status == 200 => {}
            Ok(response) => {
                return RelayPoll::Failed(format!(
                    "relay health check returned HTTP {}.{}",
                    response.status,
                    self.last_log_suffix()
                ));
            }
            Err(_) => return RelayPoll::Starting,
        }

        match http::get_loopback(
            self.info.port,
            "/v1/sessions",
            Some(&self.tokens.read),
            PROBE_TIMEOUT,
        ) {
            Ok(response) if response.status == 200 => {
                self.ready = true;
                RelayPoll::Ready
            }
            Ok(response) if response.status == 401 || response.status == 403 => RelayPoll::Failed(
                "relay rejected the app-owned read token; remove relay.env and retry.".to_owned(),
            ),
            Ok(response) => RelayPoll::Failed(format!(
                "relay authentication probe returned HTTP {}.",
                response.status
            )),
            Err(_) => RelayPoll::Starting,
        }
    }

    fn last_log_suffix(&self) -> String {
        let logs = self.logs();
        match logs.last() {
            Some(line) if !line.is_empty() => format!(" Last relay message: {line}"),
            _ => String::new(),
        }
    }

    /// Stop only this owned child, gracefully first.
    pub fn stop(&mut self) {
        if self.child.try_wait().ok().flatten().is_some() {
            return;
        }
        let pid = self.info.pid as i32;
        unsafe {
            let _ = libc::kill(pid, libc::SIGTERM);
        }
        let deadline = Instant::now() + STOP_GRACE;
        while Instant::now() < deadline {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(25));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for RelayProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

fn encode_fragment(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            use std::fmt::Write as _;
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn locates_an_explicit_binary() {
        let temp = TempDir::new().unwrap();
        let binary = temp.path().join("highlite-relay");
        fs::write(&binary, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o700)).unwrap();
        let found = locate_relay_binary(Some(binary.to_str().unwrap())).unwrap();
        assert_eq!(found, binary);
    }

    #[test]
    fn does_not_return_non_executable_files() {
        let temp = TempDir::new().unwrap();
        let binary = temp.path().join("highlite-relay");
        fs::write(&binary, "not executable").unwrap();
        // The explicit candidate is rejected; a development build elsewhere in
        // the repository may still be a legitimate fallback.
        assert_ne!(
            locate_relay_binary(Some(binary.to_str().unwrap())),
            Some(binary)
        );
    }

    #[test]
    fn encodes_fragment_values() {
        assert_eq!(encode_fragment("abc-._~123"), "abc-._~123");
        assert_eq!(encode_fragment("a b#c"), "a%20b%23c");
    }
}
