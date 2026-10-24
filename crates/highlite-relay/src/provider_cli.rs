use std::io::Read;
use std::path::PathBuf;

use highlite_relay::providers::{ConnectProvider, ProviderKind, ProviderStore, config_dir};

/// Local configuration commands do not require a running relay or relay tokens.
pub fn run(args: &[String]) -> Result<(), String> {
    let action = args
        .first()
        .map(String::as_str)
        .ok_or("expected providers connect, list, default, or disconnect")?;
    let mut id = None;
    let mut kind = None;
    let mut model = None;
    let mut base_url = None;
    let mut root: Option<PathBuf> = None;
    let mut key_stdin = false;
    let mut no_key = false;
    let mut make_default = false;
    let mut index = 1;
    while index < args.len() {
        let argument = args[index].as_str();
        match argument {
            "--kind" | "--model" | "--base-url" | "--config-dir" => {
                index += 1;
                let value = args
                    .get(index)
                    .ok_or_else(|| format!("{argument} needs a value"))?;
                match argument {
                    "--kind" => kind = Some(value.parse::<ProviderKind>()?),
                    "--model" => model = Some(value.clone()),
                    "--base-url" => base_url = Some(value.clone()),
                    _ => root = Some(PathBuf::from(value)),
                }
            }
            "--api-key-stdin" => key_stdin = true,
            "--no-api-key" => no_key = true,
            "--default" => make_default = true,
            value if !value.starts_with('-') && id.is_none() => id = Some(value.to_owned()),
            _ => return Err("unexpected provider argument; see --help".to_owned()),
        }
        index += 1;
    }
    if action != "connect"
        && (kind.is_some()
            || model.is_some()
            || base_url.is_some()
            || key_stdin
            || no_key
            || make_default)
    {
        return Err("connection options are only valid for providers connect".to_owned());
    }
    if key_stdin && no_key {
        return Err("--api-key-stdin and --no-api-key cannot be combined".to_owned());
    }
    let root = config_dir(root)?;
    let store = ProviderStore::new(root.clone());
    let list = match action {
        "list" => {
            if id.is_some() {
                return Err("providers list does not accept an id".to_owned());
            }
            store.list()?
        }
        "connect" => {
            let id = id.ok_or("providers connect requires an id")?;
            let kind = kind.ok_or("providers connect requires --kind")?;
            let model = model.ok_or("providers connect requires --model")?;
            if no_key && kind != ProviderKind::OpenaiCompatible {
                return Err(
                    "--no-api-key is only supported for openai-compatible endpoints".to_owned(),
                );
            }
            let api_key = if key_stdin {
                let mut value = String::new();
                std::io::stdin()
                    .take(16 * 1024 + 1)
                    .read_to_string(&mut value)
                    .map_err(|_| "could not read API key from stdin")?;
                if value.len() > 16 * 1024 {
                    return Err("API key is too long".to_owned());
                }
                Some(value.trim_end_matches(['\r', '\n']).to_owned())
            } else if no_key {
                None
            } else {
                Some(rpassword::prompt_password("API key (hidden): ").map_err(
                    |_| "could not read API key; use --api-key-stdin for non-interactive setup",
                )?)
            };
            store.connect(
                &id,
                ConnectProvider {
                    kind,
                    model,
                    base_url,
                    api_key,
                    clear_api_key: no_key,
                    make_default,
                },
            )?
        }
        "default" => store.set_default(&id.ok_or("providers default requires an id")?)?,
        "disconnect" => store.disconnect(&id.ok_or("providers disconnect requires an id")?)?,
        _ => return Err("expected providers connect, list, default, or disconnect".to_owned()),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&list).map_err(|_| "could not format providers")?
    );
    eprintln!("Provider config: {}", root.join("providers.json").display());
    if action == "connect" {
        eprintln!("Connection saved. Credentials have not been verified with the provider.");
    }
    Ok(())
}
