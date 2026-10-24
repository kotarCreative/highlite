//! Shared, private provider configuration for the relay and its CLI.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Resolve the central configuration directory independently of session storage.
pub fn config_dir(override_dir: Option<PathBuf>) -> Result<PathBuf, String> {
    if let Some(path) = override_dir.filter(|path| !path.as_os_str().is_empty()) {
        return Ok(path);
    }
    if let Some(path) = std::env::var_os("HIGHLITE_CONFIG_DIR").filter(|path| !path.is_empty()) {
        return Ok(PathBuf::from(path));
    }
    #[cfg(target_os = "windows")]
    if let Some(path) = std::env::var_os("APPDATA") {
        return Ok(PathBuf::from(path).join("Highlite"));
    }
    #[cfg(target_os = "macos")]
    if let Some(path) = std::env::var_os("HOME") {
        return Ok(PathBuf::from(path).join("Library/Application Support/Highlite"));
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        if let Some(path) = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
        {
            return Ok(path.join("highlite"));
        }
        if let Some(path) = std::env::var_os("HOME") {
            return Ok(PathBuf::from(path).join(".config/highlite"));
        }
    }
    Err("cannot resolve the config folder; set HIGHLITE_CONFIG_DIR or --config-dir".to_owned())
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderKind {
    Openai,
    Anthropic,
    OpenaiCompatible,
}

impl std::str::FromStr for ProviderKind {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "openai" => Ok(Self::Openai),
            "anthropic" => Ok(Self::Anthropic),
            "openai-compatible" => Ok(Self::OpenaiCompatible),
            _ => Err("provider kind must be openai, anthropic, or openai-compatible".to_owned()),
        }
    }
}

/// Write-only credential input. Intentionally does not implement Debug or Serialize.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConnectProvider {
    pub kind: ProviderKind,
    pub model: String,
    pub base_url: Option<String>,
    pub api_key: Option<String>,
    #[serde(default)]
    pub clear_api_key: bool,
    #[serde(default)]
    pub make_default: bool,
}

/// Public metadata: never includes credentials, even partially masked ones.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    pub id: String,
    pub kind: ProviderKind,
    pub model: String,
    pub base_url: String,
    pub has_api_key: bool,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderList {
    pub default_provider: Option<String>,
    pub providers: Vec<ProviderInfo>,
}

/// Resolved credentials are internal only: never serialized or debug-printed.
pub(crate) struct ResolvedProvider {
    pub id: String,
    pub kind: ProviderKind,
    pub model: String,
    pub base_url: String,
    pub api_key: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredProvider {
    id: String,
    kind: ProviderKind,
    model: String,
    base_url: String,
    api_key: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProviderFile {
    schema_version: u32,
    default_provider: Option<String>,
    providers: Vec<StoredProvider>,
}

impl Default for ProviderFile {
    fn default() -> Self {
        Self {
            schema_version: 1,
            default_provider: None,
            providers: Vec::new(),
        }
    }
}

impl ProviderFile {
    fn metadata(&self) -> ProviderList {
        ProviderList {
            default_provider: self.default_provider.clone(),
            providers: self
                .providers
                .iter()
                .map(|provider| ProviderInfo {
                    id: provider.id.clone(),
                    kind: provider.kind,
                    model: provider.model.clone(),
                    base_url: provider.base_url.clone(),
                    has_api_key: provider.api_key.is_some(),
                })
                .collect(),
        }
    }
}

/// Every operation reloads under a cross-process lock, so CLI and UI updates coexist.
#[derive(Clone)]
pub struct ProviderStore {
    root: PathBuf,
}

impl ProviderStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn list(&self) -> Result<ProviderList, String> {
        self.access(false, |config| Ok(config.metadata()))
    }

    pub(crate) fn resolve_default(&self) -> Result<ResolvedProvider, String> {
        self.access(false, |config| {
            let id = config
                .default_provider
                .as_ref()
                .ok_or("configure a default AI provider first")?;
            let provider = config
                .providers
                .iter()
                .find(|provider| &provider.id == id)
                .ok_or("default AI provider not found")?;
            Ok(ResolvedProvider {
                id: provider.id.clone(),
                kind: provider.kind,
                model: provider.model.clone(),
                base_url: provider.base_url.clone(),
                api_key: provider.api_key.clone(),
            })
        })
    }

    pub fn connect(&self, id: &str, input: ConnectProvider) -> Result<ProviderList, String> {
        validate_id(id)?;
        let model = input.model.trim().to_owned();
        if model.is_empty() || model.len() > 256 || model.chars().any(char::is_control) {
            return Err(
                "model must contain 1-256 characters without control characters".to_owned(),
            );
        }
        let base_url = normalize_base_url(input.kind, input.base_url.as_deref())?;
        let supplied_key = input.api_key.map(|key| key.trim().to_owned());
        if input.clear_api_key
            && (supplied_key.is_some() || input.kind != ProviderKind::OpenaiCompatible)
        {
            return Err("clearing an API key requires an openai-compatible connection and no replacement key".to_owned());
        }
        if supplied_key.as_ref().is_some_and(|key| {
            key.is_empty() || key.len() > 16 * 1024 || key.chars().any(char::is_control)
        }) {
            return Err("API key must be non-empty and contain no control characters".to_owned());
        }
        self.access(true, |config| {
            let first_connection = config.providers.is_empty();
            let existing = config.providers.iter().find(|provider| provider.id == id);
            let api_key = supplied_key.or_else(|| {
                existing
                    .filter(|provider| {
                        !input.clear_api_key
                            && provider.kind == input.kind
                            && provider.base_url == base_url
                    })
                    .and_then(|provider| provider.api_key.clone())
            });
            if api_key.is_none() && input.kind != ProviderKind::OpenaiCompatible {
                return Err("an API key is required for this provider".to_owned());
            }
            config.providers.retain(|provider| provider.id != id);
            config.providers.push(StoredProvider {
                id: id.to_owned(),
                kind: input.kind,
                model,
                base_url,
                api_key,
            });
            config.providers.sort_by(|a, b| a.id.cmp(&b.id));
            if input.make_default || first_connection {
                config.default_provider = Some(id.to_owned());
            }
            Ok(config.metadata())
        })
    }

    pub fn set_default(&self, id: &str) -> Result<ProviderList, String> {
        validate_id(id)?;
        self.access(true, |config| {
            if !config.providers.iter().any(|provider| provider.id == id) {
                return Err("provider not found".to_owned());
            }
            config.default_provider = Some(id.to_owned());
            Ok(config.metadata())
        })
    }

    pub fn disconnect(&self, id: &str) -> Result<ProviderList, String> {
        validate_id(id)?;
        self.access(true, |config| {
            if !config.providers.iter().any(|provider| provider.id == id) {
                return Err("provider not found".to_owned());
            }
            config.providers.retain(|provider| provider.id != id);
            if config.default_provider.as_deref() == Some(id) {
                // Never silently switch a user's capture data to another provider.
                config.default_provider = None;
            }
            Ok(config.metadata())
        })
    }

    fn access<T>(
        &self,
        write: bool,
        operation: impl FnOnce(&mut ProviderFile) -> Result<T, String>,
    ) -> Result<T, String> {
        crate::private_config::access(
            &self.root,
            "providers",
            write,
            |config: &mut ProviderFile| {
                if config.schema_version != 1 {
                    return Err("unsupported provider config schema version".to_owned());
                }
                // Hand-edited files must satisfy the same contract as CLI/UI writes.
                let mut ids = std::collections::HashSet::new();
                for provider in &config.providers {
                    if validate_id(&provider.id).is_err()
                        || !ids.insert(provider.id.as_str())
                        || provider.model.trim().is_empty()
                        || provider.model.len() > 256
                        || provider.model.chars().any(char::is_control)
                        || normalize_base_url(provider.kind, Some(&provider.base_url)).is_err()
                        || (provider.api_key.is_none()
                            && provider.kind != ProviderKind::OpenaiCompatible)
                        || provider.api_key.as_ref().is_some_and(|key| {
                            key.trim().is_empty()
                                || key.len() > 16 * 1024
                                || key.chars().any(char::is_control)
                        })
                    {
                        return Err(
                            "invalid provider config; existing file was not modified".to_owned()
                        );
                    }
                }
                if config
                    .default_provider
                    .as_ref()
                    .is_some_and(|id| !ids.contains(id.as_str()))
                {
                    return Err("default provider does not exist in provider config".to_owned());
                }
                operation(config)
            },
        )
    }
}

fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty()
        || id.len() > 64
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("provider id must be 1-64 letters, digits, '-' or '_'".to_owned());
    }
    Ok(())
}

fn normalize_base_url(kind: ProviderKind, supplied: Option<&str>) -> Result<String, String> {
    let default = match kind {
        ProviderKind::Openai => "https://api.openai.com/v1",
        ProviderKind::Anthropic => "https://api.anthropic.com/v1",
        ProviderKind::OpenaiCompatible => "",
    };
    let value = supplied
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(default);
    if kind != ProviderKind::OpenaiCompatible && value.trim_end_matches('/') != default {
        return Err("custom endpoints require the openai-compatible provider kind".to_owned());
    }
    let url = reqwest::Url::parse(value).map_err(|_| "a valid provider base URL is required")?;
    let loopback = url.host_str().is_some_and(|host| {
        host.eq_ignore_ascii_case("localhost")
            || host
                .trim_matches(['[', ']'])
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
    });
    if url.host_str().is_none()
        || !(url.scheme() == "https" || (url.scheme() == "http" && loopback))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("provider URL must use HTTPS (or loopback HTTP), without credentials, query, or fragment".to_owned());
    }
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn test_dir() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        }
        root
    }

    fn connection(key: Option<&str>) -> ConnectProvider {
        ConnectProvider {
            kind: ProviderKind::Openai,
            model: "test-model".to_owned(),
            base_url: None,
            api_key: key.map(str::to_owned),
            clear_api_key: false,
            make_default: false,
        }
    }

    #[test]
    fn shares_credentials_without_exposing_them() {
        let root = test_dir();
        let store = ProviderStore::new(root.path().to_path_buf());
        let list = store
            .connect("work", connection(Some("secret-test-key")))
            .unwrap();
        assert_eq!(list.default_provider.as_deref(), Some("work"));
        assert!(
            !serde_json::to_string(&list)
                .unwrap()
                .contains("secret-test-key")
        );
        assert!(!format!("{list:?}").contains("secret-test-key"));
        let second = ProviderStore::new(root.path().to_path_buf());
        assert!(second.list().unwrap().providers[0].has_api_key);
        second.connect("work", connection(None)).unwrap();
        let stored = fs::read_to_string(root.path().join("providers.json")).unwrap();
        assert!(stored.contains("secret-test-key"));
        store
            .connect("work", connection(Some("replacement-key")))
            .unwrap();
        assert!(
            !fs::read_to_string(root.path().join("providers.json"))
                .unwrap()
                .contains("secret-test-key")
        );
        store.disconnect("work").unwrap();
        assert!(second.list().unwrap().providers.is_empty());
        assert!(
            !fs::read_to_string(root.path().join("providers.json"))
                .unwrap()
                .contains("replacement-key")
        );
    }

    #[test]
    fn default_changes_are_explicit_and_failures_preserve_config() {
        let root = test_dir();
        let store = ProviderStore::new(root.path().to_path_buf());
        store.connect("a", connection(Some("a-key"))).unwrap();
        store.connect("b", connection(Some("b-key"))).unwrap();
        assert_eq!(store.list().unwrap().default_provider.as_deref(), Some("a"));
        store.set_default("b").unwrap();
        store.disconnect("b").unwrap();
        assert!(store.list().unwrap().default_provider.is_none());
        store.connect("a", connection(None)).unwrap();
        assert!(store.list().unwrap().default_provider.is_none());
        let before = fs::read(root.path().join("providers.json")).unwrap();
        assert!(store.set_default("missing").is_err());
        assert!(store.disconnect("missing").is_err());
        assert!(store.connect("../escape", connection(Some("key"))).is_err());
        assert!(store.connect("new", connection(None)).is_err());
        assert_eq!(
            before,
            fs::read(root.path().join("providers.json")).unwrap()
        );
    }

    #[test]
    fn validates_endpoints_and_does_not_reuse_keys_across_endpoints() {
        let root = test_dir();
        let store = ProviderStore::new(root.path().to_path_buf());
        for url in [
            "http://example.com/v1",
            "https://user:secret@example.com",
            "https://example.com?key=secret",
            "https://example.com/#secret",
            "file:///secret",
        ] {
            let mut input = connection(Some("secret"));
            input.kind = ProviderKind::OpenaiCompatible;
            input.base_url = Some(url.to_owned());
            assert!(store.connect("work", input).is_err());
        }
        for url in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:8080/v1",
            "http://[::1]:8080/v1",
            "https://example.com/v1",
        ] {
            let mut input = connection(None);
            input.kind = ProviderKind::OpenaiCompatible;
            input.base_url = Some(url.to_owned());
            store.connect("local", input).unwrap();
        }
        store
            .connect("work", connection(Some("cloud-secret")))
            .unwrap();
        let mut input = connection(None);
        input.kind = ProviderKind::Anthropic;
        assert!(store.connect("work", input).is_err());
        let mut input = connection(None);
        input.kind = ProviderKind::OpenaiCompatible;
        input.base_url = Some("https://example.com/v1".to_owned());
        let list = store.connect("work", input).unwrap();
        assert!(
            !list
                .providers
                .iter()
                .find(|provider| provider.id == "work")
                .unwrap()
                .has_api_key
        );
        let mut authenticated = connection(Some("compatible-secret"));
        authenticated.kind = ProviderKind::OpenaiCompatible;
        authenticated.base_url = Some("http://localhost:11434/v1".to_owned());
        store.connect("local", authenticated).unwrap();
        let mut unauthenticated = connection(None);
        unauthenticated.kind = ProviderKind::OpenaiCompatible;
        unauthenticated.base_url = Some("http://localhost:11434/v1".to_owned());
        unauthenticated.clear_api_key = true;
        let list = store.connect("local", unauthenticated).unwrap();
        assert!(
            !list
                .providers
                .iter()
                .find(|provider| provider.id == "local")
                .unwrap()
                .has_api_key
        );
    }

    #[test]
    fn malformed_files_are_not_overwritten_or_disclosed() {
        let root = test_dir();
        let store = ProviderStore::new(root.path().to_path_buf());
        store.connect("work", connection(Some("key"))).unwrap();
        let path = root.path().join("providers.json");
        fs::write(&path, "{\"schemaVersion\":\"super-secret-invalid-value\"}").unwrap();
        let error = store.connect("other", connection(Some("key"))).unwrap_err();
        assert!(!error.contains("super-secret"));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "{\"schemaVersion\":\"super-secret-invalid-value\"}"
        );
    }

    #[test]
    fn concurrent_stores_do_not_lose_updates() {
        let root = test_dir();
        let threads: Vec<_> = (0..12)
            .map(|index| {
                let store = ProviderStore::new(root.path().to_path_buf());
                std::thread::spawn(move || {
                    store
                        .connect(&format!("provider-{index}"), connection(Some("key")))
                        .unwrap()
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(
            ProviderStore::new(root.path().to_path_buf())
                .list()
                .unwrap()
                .providers
                .len(),
            12
        );
    }

    #[cfg(unix)]
    #[test]
    fn credentials_are_private_and_symlinks_are_rejected() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("private");
        let store = ProviderStore::new(folder.clone());
        store.connect("work", connection(Some("secret"))).unwrap();
        assert_eq!(
            fs::metadata(&folder).unwrap().permissions().mode() & 0o777,
            0o700
        );
        for name in ["providers.json", "providers.lock"] {
            assert_eq!(
                fs::metadata(folder.join(name))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        let path = folder.join("providers.json");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(store.list().is_err());
        fs::remove_file(&path).unwrap();
        let target = root.path().join("target");
        fs::write(&target, "do not overwrite").unwrap();
        symlink(&target, &path).unwrap();
        assert!(store.connect("work", connection(Some("key"))).is_err());
        assert_eq!(fs::read_to_string(target).unwrap(), "do not overwrite");
    }
}
