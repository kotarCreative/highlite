//! Bounded, private, atomic JSON storage shared by credentials and recipe state.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

use fs2::FileExt;
use serde::{Serialize, de::DeserializeOwned};

const MAX_BYTES: u64 = 1024 * 1024;

pub(crate) fn access<T: Default + Serialize + DeserializeOwned, R>(
    root: &Path,
    name: &str,
    write: bool,
    operation: impl FnOnce(&mut T) -> Result<R, String>,
) -> Result<R, String> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("invalid config name".to_owned());
    }
    private_directory(root)?;
    let lock_path = root.join(format!("{name}.lock"));
    reject_symlink(&lock_path)?;
    let lock = private_options()
        .open(lock_path)
        .map_err(|_| "could not open private config lock")?;
    ensure_private(&lock)?;
    lock.lock_exclusive()
        .map_err(|_| "could not lock private config")?;
    let path = root.join(format!("{name}.json"));
    reject_symlink(&path)?;
    let mut config = match File::open(&path) {
        Ok(file) => {
            ensure_private(&file)?;
            let metadata = file
                .metadata()
                .map_err(|_| "could not inspect private config")?;
            if !metadata.is_file() || metadata.len() > MAX_BYTES {
                return Err(
                    "private config must be a regular file within the size limit".to_owned(),
                );
            }
            let mut bytes = Vec::new();
            file.take(MAX_BYTES + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| "could not read private config")?;
            if bytes.len() as u64 > MAX_BYTES {
                return Err("private config exceeds the size limit".to_owned());
            }
            // Parser errors can echo credential values. Never propagate them.
            serde_json::from_slice::<T>(&bytes)
                .map_err(|_| "invalid private config; existing file was not modified")?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => T::default(),
        Err(_) => return Err("could not read private config".to_owned()),
    };
    let result = operation(&mut config)?;
    if write {
        let bytes =
            serde_json::to_vec_pretty(&config).map_err(|_| "could not encode private config")?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err("private config exceeds the size limit".to_owned());
        }
        let mut temporary =
            tempfile::NamedTempFile::new_in(root).map_err(|_| "could not create private config")?;
        ensure_private(temporary.as_file())?;
        temporary
            .write_all(&bytes)
            .and_then(|()| temporary.as_file().sync_all())
            .map_err(|_| "could not write private config")?;
        temporary
            .persist(path)
            .map_err(|_| "could not replace private config")?;
    }
    Ok(result)
}

fn reject_symlink(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err("private config paths must not be symbolic links".to_owned())
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("could not inspect private config path".to_owned()),
    }
}

fn private_directory(path: &Path) -> Result<(), String> {
    reject_symlink(path)?;
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(path)
        .map_err(|_| "could not create private config folder")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if fs::metadata(path)
            .map_err(|_| "could not inspect private config folder")?
            .permissions()
            .mode()
            & 0o077
            != 0
        {
            return Err("private config folder must be private (chmod 700)".to_owned());
        }
    }
    Ok(())
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn ensure_private(file: &File) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if file
            .metadata()
            .map_err(|_| "could not inspect private config permissions")?
            .permissions()
            .mode()
            & 0o077
            != 0
        {
            return Err("private config files must be private (chmod 600)".to_owned());
        }
    }
    #[cfg(not(unix))]
    let _ = file;
    Ok(())
}
