//! Private paths, relay tokens, and the app-owned relay environment file.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(1);

pub const READ_TOKEN_KEY: &str = "HIGHLITE_RELAY_READ_TOKEN";
pub const INGEST_TOKEN_KEY: &str = "HIGHLITE_RELAY_INGEST_TOKEN";
pub const BIND_KEY: &str = "HIGHLITE_RELAY_BIND";
pub const DATA_DIR_KEY: &str = "HIGHLITE_RELAY_DATA_DIR";
pub const CONFIG_DIR_KEY: &str = "HIGHLITE_CONFIG_DIR";
pub const UI_KEY: &str = "HIGHLITE_RELAY_UI";
pub const ALLOWED_HOSTS_KEY: &str = "HIGHLITE_RELAY_ALLOWED_HOSTS";
pub const ALLOWED_ORIGINS_KEY: &str = "HIGHLITE_RELAY_ALLOWED_ORIGINS";

const APP_OWNED_KEYS: &[&str] = &[
    READ_TOKEN_KEY,
    INGEST_TOKEN_KEY,
    BIND_KEY,
    DATA_DIR_KEY,
    CONFIG_DIR_KEY,
    UI_KEY,
    ALLOWED_HOSTS_KEY,
    ALLOWED_ORIGINS_KEY,
];

/// Paths reserved for the Linux desktop shell.
///
/// These are intentionally different from the macOS app sandbox and from a
/// user's existing `~/.config/highlite` provider credentials. The Linux MVP
/// opts into its own private provider config so a test or first run never
/// touches live integrations.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DesktopPaths {
    pub config_dir: PathBuf,
    pub data_dir: PathBuf,
    pub env_file: PathBuf,
}

impl DesktopPaths {
    pub fn from_environment() -> Result<Self, String> {
        let config_dir = match non_empty_env("HIGHLITE_DESKTOP_CONFIG_DIR") {
            Some(value) => PathBuf::from(value),
            None => xdg_dir("XDG_CONFIG_HOME", ".config")?
                .join("highlite")
                .join("linux"),
        };
        let data_dir = match non_empty_env("HIGHLITE_DESKTOP_DATA_DIR") {
            Some(value) => PathBuf::from(value),
            None => xdg_dir("XDG_DATA_HOME", ".local/share")?
                .join("highlite")
                .join("linux"),
        };
        Self::new(config_dir, data_dir)
    }

    pub fn new(config_dir: PathBuf, data_dir: PathBuf) -> Result<Self, String> {
        if config_dir.as_os_str().is_empty() || data_dir.as_os_str().is_empty() {
            return Err("Highlite config and data directories must not be empty.".to_owned());
        }
        let env_file = config_dir.join("relay.env");
        Ok(Self {
            config_dir,
            data_dir,
            env_file,
        })
    }

    /// Create the private roots and repair their permissions.
    pub fn prepare(&self) -> Result<(), String> {
        ensure_private_dir(&self.config_dir)?;
        ensure_private_dir(&self.data_dir)?;
        Ok(())
    }
}

fn non_empty_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn xdg_dir(variable: &str, home_relative: &str) -> Result<PathBuf, String> {
    if let Some(value) = non_empty_env(variable) {
        return Ok(PathBuf::from(value));
    }
    let home = non_empty_env("HOME")
        .ok_or_else(|| format!("{variable} is unset and HOME is unavailable."))?;
    Ok(PathBuf::from(home).join(home_relative))
}

fn ensure_private_dir(path: &Path) -> Result<(), String> {
    if path.exists() {
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
        if !metadata.is_dir() {
            return Err(format!("{} exists but is not a directory.", path.display()));
        }
    } else {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not secure {}: {error}", path.display()))
}

/// The two relay bearer tokens. They are never included in status text or logs.
#[derive(Clone, PartialEq, Eq)]
pub struct RelayTokens {
    pub read: String,
    pub ingest: String,
}

impl std::fmt::Debug for RelayTokens {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RelayTokens")
            .field("read", &"[redacted]")
            .field("ingest", &"[redacted]")
            .finish()
    }
}

impl RelayTokens {
    pub fn generate() -> Result<Self, String> {
        Ok(Self {
            read: random_token()?,
            ingest: random_token()?,
        })
    }
}

#[derive(Debug)]
pub struct RelayEnvironment {
    pub tokens: RelayTokens,
    pub port: u16,
}

struct TokenValues {
    read_env: String,
    ingest_env: String,
    read: String,
    ingest: String,
}

impl TokenValues {
    fn tokens(&self) -> RelayTokens {
        RelayTokens {
            read: self.read.clone(),
            ingest: self.ingest.clone(),
        }
    }
}

/// Write the app-owned relay settings and return the tokens the relay will use.
///
/// Valid tokens already present in the file are preserved. Unrelated lines and
/// comments are preserved so an operator can keep optional relay settings in
/// the same file. The file is replaced atomically with mode 0600.
pub fn write_relay_env(paths: &DesktopPaths, port: u16) -> Result<RelayEnvironment, String> {
    if port == 0 {
        return Err("relay port must not be zero".to_owned());
    }
    paths.prepare()?;
    let existing = read_env_lines(&paths.env_file)?;
    let token_values = token_values_from_lines(&existing)?;
    let tokens = token_values.tokens();
    let bind = format!("127.0.0.1:{port}");
    let origin = format!("http://{bind}");

    let owned = [
        (BIND_KEY, bind),
        (DATA_DIR_KEY, path_value(&paths.data_dir)?),
        (CONFIG_DIR_KEY, path_value(&paths.config_dir)?),
        (UI_KEY, "true".to_owned()),
        (READ_TOKEN_KEY, token_values.read_env.clone()),
        (INGEST_TOKEN_KEY, token_values.ingest_env.clone()),
        (ALLOWED_HOSTS_KEY, format!("127.0.0.1:{port}")),
        (ALLOWED_ORIGINS_KEY, origin),
    ];

    let mut written: Vec<String> = Vec::new();
    let mut output = String::new();
    for line in existing {
        let Some(key) = env_line_key(&line) else {
            output.push_str(&line);
            output.push('\n');
            continue;
        };
        if APP_OWNED_KEYS.contains(&key) {
            if written.iter().any(|seen| seen == key) {
                continue;
            }
            if let Some((_, value)) = owned.iter().find(|(name, _)| *name == key) {
                output.push_str(&name_value_line(key, value)?);
                output.push('\n');
                written.push(key.to_owned());
            }
            continue;
        }
        output.push_str(&line);
        output.push('\n');
    }
    for (key, value) in owned {
        if !written.iter().any(|seen| seen == key) {
            output.push_str(&name_value_line(key, &value)?);
            output.push('\n');
        }
    }

    write_private_atomic(&paths.env_file, output.as_bytes())?;
    Ok(RelayEnvironment { tokens, port })
}

fn path_value(path: &Path) -> Result<String, String> {
    path.to_str()
        .map(str::to_owned)
        .ok_or_else(|| format!("{} is not valid UTF-8.", path.display()))
}

fn read_env_lines(path: &Path) -> Result<Vec<String>, String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(format!(
                    "refusing to read relay environment through symlink {}",
                    path.display()
                ));
            }
            if !metadata.is_file() {
                return Err(format!("{} is not a regular file.", path.display()));
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(format!(
                "could not inspect relay environment {}: {error}",
                path.display()
            ));
        }
    }
    let contents = fs::read_to_string(path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    Ok(contents.lines().map(str::to_owned).collect())
}

fn token_values_from_lines(lines: &[String]) -> Result<TokenValues, String> {
    let read_env = find_env_value(lines, READ_TOKEN_KEY)
        .filter(|value| valid_token_list(value))
        .unwrap_or(random_token()?);
    let ingest_env = find_env_value(lines, INGEST_TOKEN_KEY)
        .filter(|value| valid_token_list(value))
        .unwrap_or(random_token()?);
    Ok(TokenValues {
        read: first_token(&read_env),
        ingest: first_token(&ingest_env),
        read_env,
        ingest_env,
    })
}

fn first_token(value: &str) -> String {
    value.split(',').next().unwrap_or(value).trim().to_owned()
}

fn find_env_value(lines: &[String], wanted: &str) -> Option<String> {
    let mut found = None;
    for line in lines {
        if env_line_key(line) != Some(wanted) {
            continue;
        }
        let (_, raw) = line.split_once('=')?;
        found = Some(parse_env_value(raw));
    }
    found
}

fn env_line_key(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let trimmed = trimmed.strip_prefix("export ").unwrap_or(trimmed);
    let (key, _) = trimmed.split_once('=')?;
    let key = key.trim();
    key.starts_with("HIGHLITE_").then_some(key)
}

fn parse_env_value(raw: &str) -> String {
    let raw = raw.trim();
    if let Some(inner) = raw
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
    {
        let mut value = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(character) = chars.next() {
            if character == '\\' {
                match chars.next() {
                    Some('n') => value.push('\n'),
                    Some('r') => value.push('\r'),
                    Some('t') => value.push('\t'),
                    Some(other) => value.push(other),
                    None => value.push('\\'),
                }
            } else {
                value.push(character);
            }
        }
        return value;
    }
    if let Some(inner) = raw
        .strip_prefix('\'')
        .and_then(|value| value.strip_suffix('\''))
    {
        return inner.to_owned();
    }
    raw.split(" #").next().unwrap_or(raw).trim().to_owned()
}

fn valid_token_list(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 4096
        && value.split(',').all(|token| {
            let token = token.trim();
            !token.is_empty()
                && token.len() <= 4096
                && token.chars().all(|character| character.is_ascii_graphic())
        })
}

fn name_value_line(key: &str, value: &str) -> Result<String, String> {
    if value.contains(['\n', '\r', '\0']) {
        return Err(format!("{key} contains a control character."));
    }
    Ok(format!("{key}={}", quote_env_value(value)))
}

fn quote_env_value(value: &str) -> String {
    let needs_quotes = value.is_empty()
        || value
            .chars()
            .any(|character| !character.is_ascii() || !is_unquoted_env_char(character));
    if !needs_quotes {
        return value.to_owned();
    }
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for character in value.chars() {
        match character {
            '\\' => quoted.push_str("\\\\"),
            '"' => quoted.push_str("\\\""),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

fn is_unquoted_env_char(character: char) -> bool {
    character.is_ascii_alphanumeric()
        || matches!(
            character,
            '_' | '-' | '.' | '/' | ':' | '@' | '%' | '+' | ',' | '~'
        )
}

fn write_private_atomic(path: &Path, contents: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory.", path.display()))?;
    ensure_private_dir(parent)?;
    if let Ok(metadata) = fs::symlink_metadata(path)
        && metadata.file_type().is_symlink()
    {
        return Err(format!(
            "refusing to replace relay environment symlink {}",
            path.display()
        ));
    }

    let counter = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(".relay.env.{}.{counter}.tmp", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|error| format!("could not create {}: {error}", temporary.display()))?;
        file.write_all(contents)
            .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
        file.sync_all()
            .map_err(|error| format!("could not sync {}: {error}", temporary.display()))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("could not replace {}: {error}", path.display()))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("could not secure {}: {error}", path.display()))?;
        if let Ok(directory) = File::open(parent) {
            let _ = directory.sync_all();
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn random_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("could not read secure random bytes: {error}"))?;
    let mut token = String::with_capacity(64);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(token, "{byte:02x}");
    }
    Ok(token)
}

/// Redact every configured secret from a line before it reaches a log or menu.
pub fn redact_secrets(line: &str, secrets: &[&str]) -> String {
    let mut redacted = line.to_owned();
    for secret in secrets {
        if secret.len() >= 8 {
            redacted = redacted.replace(secret, "[redacted]");
        }
    }
    if let Some(index) = redacted.find("#token=") {
        redacted.truncate(index + "#token=".len());
        redacted.push_str("[redacted]");
    }
    redacted
}

pub fn pick_loopback_port() -> Result<u16, String> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))
        .map_err(|error| format!("could not select a loopback port: {error}"))?;
    listener
        .local_addr()
        .map(|address| address.port())
        .map_err(|error| format!("could not read the selected loopback port: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_paths(temp: &TempDir) -> DesktopPaths {
        DesktopPaths::new(temp.path().join("config"), temp.path().join("data")).unwrap()
    }

    #[test]
    fn writes_private_environment_and_generates_tokens() {
        let temp = TempDir::new().unwrap();
        let paths = test_paths(&temp);
        let environment = write_relay_env(&paths, 43210).unwrap();

        assert_eq!(environment.tokens.read.len(), 64);
        assert_eq!(environment.tokens.ingest.len(), 64);
        assert_ne!(environment.tokens.read, environment.tokens.ingest);
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
        let contents = fs::read_to_string(&paths.env_file).unwrap();
        assert!(contents.contains("HIGHLITE_RELAY_BIND=127.0.0.1:43210"));
        assert!(contents.contains("HIGHLITE_RELAY_UI=true"));
        assert!(contents.contains(&format!("{READ_TOKEN_KEY}={}", environment.tokens.read)));
    }

    #[test]
    fn preserves_tokens_unknown_settings_and_comments() {
        let temp = TempDir::new().unwrap();
        let paths = test_paths(&temp);
        paths.prepare().unwrap();
        let existing = "\
# operator note
HIGHLITE_RELAY_READ_TOKEN=read-keep-me
HIGHLITE_RELAY_INGEST_TOKEN=ingest-keep-me
HIGHLITE_RELAY_LANGUAGE=en
HIGHLITE_RELAY_PARAKEET_MODEL=\"/tmp/model with space.gguf\"
";
        fs::write(&paths.env_file, existing).unwrap();
        fs::set_permissions(&paths.env_file, fs::Permissions::from_mode(0o644)).unwrap();

        let environment = write_relay_env(&paths, 40123).unwrap();
        assert_eq!(environment.tokens.read, "read-keep-me");
        assert_eq!(environment.tokens.ingest, "ingest-keep-me");
        let contents = fs::read_to_string(&paths.env_file).unwrap();
        assert!(contents.contains("# operator note"));
        assert!(contents.contains("HIGHLITE_RELAY_LANGUAGE=en"));
        assert!(contents.contains("HIGHLITE_RELAY_BIND=127.0.0.1:40123"));
        assert!(contents.contains("HIGHLITE_CONFIG_DIR="));
        assert_eq!(
            fs::metadata(&paths.env_file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn keeps_comma_separated_token_rotation_and_probes_with_the_first_token() {
        let temp = TempDir::new().unwrap();
        let paths = test_paths(&temp);
        paths.prepare().unwrap();
        fs::write(
            &paths.env_file,
            "HIGHLITE_RELAY_READ_TOKEN=read-a,read-b\nHIGHLITE_RELAY_INGEST_TOKEN=ingest-a,ingest-b\n",
        )
        .unwrap();

        let environment = write_relay_env(&paths, 40126).unwrap();
        assert_eq!(environment.tokens.read, "read-a");
        assert_eq!(environment.tokens.ingest, "ingest-a");
        let contents = fs::read_to_string(&paths.env_file).unwrap();
        assert!(contents.contains("HIGHLITE_RELAY_READ_TOKEN=read-a,read-b"));
        assert!(contents.contains("HIGHLITE_RELAY_INGEST_TOKEN=ingest-a,ingest-b"));
    }

    #[test]
    fn replaces_invalid_tokens_and_quotes_paths_with_spaces() {
        let temp = TempDir::new().unwrap();
        let config = temp.path().join("config dir");
        let data = temp.path().join("data dir");
        let paths = DesktopPaths::new(config, data).unwrap();
        paths.prepare().unwrap();
        fs::write(&paths.env_file, "HIGHLITE_RELAY_READ_TOKEN=\n").unwrap();

        let environment = write_relay_env(&paths, 40124).unwrap();
        assert_eq!(environment.tokens.read.len(), 64);
        let contents = fs::read_to_string(&paths.env_file).unwrap();
        assert!(contents.contains("HIGHLITE_RELAY_DATA_DIR=\""));
        assert!(contents.contains("data dir\""));
    }

    #[test]
    fn replaces_tokens_that_cannot_be_sent_as_bearer_headers() {
        let temp = TempDir::new().unwrap();
        let paths = test_paths(&temp);
        paths.prepare().unwrap();
        fs::write(
            &paths.env_file,
            "HIGHLITE_RELAY_READ_TOKEN=not a bearer token\n",
        )
        .unwrap();
        let environment = write_relay_env(&paths, 40127).unwrap();
        assert_eq!(environment.tokens.read.len(), 64);
    }

    #[test]
    fn rejects_symlinked_environment() {
        let temp = TempDir::new().unwrap();
        let paths = test_paths(&temp);
        paths.prepare().unwrap();
        let target = temp.path().join("elsewhere");
        fs::write(&target, "HIGHLITE_RELAY_READ_TOKEN=abc\n").unwrap();
        std::os::unix::fs::symlink(&target, &paths.env_file).unwrap();

        let error = write_relay_env(&paths, 40125).unwrap_err();
        assert!(error.contains("symlink"), "{error}");
    }

    #[test]
    fn debug_output_never_contains_tokens() {
        let tokens = RelayTokens::generate().unwrap();
        let debug = format!("{tokens:?}");
        assert!(!debug.contains(&tokens.read));
        assert!(!debug.contains(&tokens.ingest));
        assert!(debug.contains("[redacted]"));
    }

    #[test]
    fn redacts_tokens_and_tokenized_urls() {
        let line = "UI http://127.0.0.1:8787/#token=abcdef0123456789 and abcdef0123456789";
        assert_eq!(
            redact_secrets(line, &["abcdef0123456789"]),
            "UI http://127.0.0.1:8787/#token=[redacted]"
        );
    }

    #[test]
    fn picks_a_free_loopback_port() {
        let port = pick_loopback_port().unwrap();
        assert_ne!(port, 0);
        let listener = std::net::TcpListener::bind(("127.0.0.1", port)).unwrap();
        assert!(listener.local_addr().unwrap().port() > 0);
    }
}
