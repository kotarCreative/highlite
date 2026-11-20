//! Server-owned allowlist of compiled capture images that may be attached to a Jira issue.
//!
//! Models only choose stable identifiers from this inventory. Paths, file names, and
//! bytes are resolved from the trusted bundle directory and revalidated when used.

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub(crate) const MAX_ATTACHMENTS: usize = 5;
pub(crate) const MAX_ATTACHMENT_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_TOTAL_ATTACHMENT_BYTES: usize = 8 * 1024 * 1024;
const MAX_FRAME_ATTACHMENTS: u32 = 24;

const PNG_MAGIC: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
const CONTACT_SHEET_ID: &str = "contact-sheet";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AttachmentChoice {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum AttachmentStatus {
    Pending,
    Uploaded,
    Failed,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AttachmentResult {
    pub id: String,
    pub name: String,
    pub status: AttachmentStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

struct Artifact {
    choice: AttachmentChoice,
    path: PathBuf,
    size: u64,
}

pub(crate) struct AttachmentFile {
    pub name: String,
    pub bytes: Vec<u8>,
}

pub(crate) struct AttachmentInventory {
    root: PathBuf,
    artifacts: Vec<Artifact>,
}

impl AttachmentInventory {
    pub(crate) fn load(bundle_dir: &Path) -> Result<Self, String> {
        let root = bundle_dir
            .canonicalize()
            .map_err(|_| "the compiled capture is missing or unsafe")?;
        let mut artifacts = Vec::new();
        if let Some(artifact) = inspect(
            &root,
            Path::new("contact-sheet.png"),
            CONTACT_SHEET_ID.to_owned(),
            "contact-sheet.png".to_owned(),
            false,
        )? {
            artifacts.push(artifact);
        }

        let frames = root.join("frames");
        match fs::symlink_metadata(&frames) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                return Err("the compiled capture frames folder is unsafe".to_owned());
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self { root, artifacts });
            }
            Err(_) => return Err("could not inspect the compiled capture frames".to_owned()),
        }

        let mut numbered = Vec::new();
        for entry in
            fs::read_dir(&frames).map_err(|_| "could not inspect the compiled capture frames")?
        {
            let entry = entry.map_err(|_| "could not inspect a compiled capture frame")?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| "a compiled capture frame name is not UTF-8")?;
            let Some(number) = frame_number(&name) else {
                continue;
            };
            let id = format!("frame-{number:02}");
            if let Some(artifact) =
                inspect(&root, &Path::new("frames").join(&name), id, name, true)?
            {
                numbered.push((number, artifact));
            }
        }
        numbered.sort_by_key(|(number, _)| *number);
        artifacts.extend(numbered.into_iter().map(|(_, artifact)| artifact));
        Ok(Self { root, artifacts })
    }

    pub(crate) fn choices(&self) -> Vec<AttachmentChoice> {
        self.artifacts
            .iter()
            .map(|artifact| artifact.choice.clone())
            .collect()
    }

    pub(crate) fn validate_selection(&self, ids: &[String]) -> Result<(), String> {
        if ids.len() > MAX_ATTACHMENTS {
            return Err(format!(
                "at most {MAX_ATTACHMENTS} capture images can be attached to one Jira issue"
            ));
        }
        let mut seen = HashSet::new();
        let mut total = 0u64;
        for id in ids {
            if !seen.insert(id) {
                return Err("each Jira attachment can be selected only once".to_owned());
            }
            let artifact = self
                .artifacts
                .iter()
                .find(|artifact| artifact.choice.id == *id)
                .ok_or_else(|| {
                    "the draft selects an attachment that is not available in this capture"
                        .to_owned()
                })?;
            total = total
                .checked_add(artifact.size)
                .ok_or_else(|| "the selected Jira attachments are too large".to_owned())?;
            if total > MAX_TOTAL_ATTACHMENT_BYTES as u64 {
                return Err(format!(
                    "the selected Jira attachments exceed the {} MiB combined limit",
                    MAX_TOTAL_ATTACHMENT_BYTES / (1024 * 1024)
                ));
            }
        }
        Ok(())
    }

    /// Read one selected artifact from the bundle, rechecking type, path, size, and magic.
    pub(crate) fn read(&self, id: &str) -> Result<AttachmentFile, String> {
        let artifact = self
            .artifacts
            .iter()
            .find(|artifact| artifact.choice.id == id)
            .ok_or_else(|| "the attachment is not available in this capture".to_owned())?;
        let canonical = artifact
            .path
            .canonicalize()
            .map_err(|_| "the attachment is no longer available")?;
        if !canonical.starts_with(&self.root) {
            return Err("the attachment path is unsafe".to_owned());
        }
        let metadata = fs::symlink_metadata(&canonical)
            .map_err(|_| "the attachment is no longer available")?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err("the attachment is not a regular file".to_owned());
        }
        if metadata.len() > MAX_ATTACHMENT_BYTES as u64 {
            return Err(format!(
                "the attachment exceeds the {} MiB per-file limit",
                MAX_ATTACHMENT_BYTES / (1024 * 1024)
            ));
        }
        let file = File::open(&canonical).map_err(|_| "could not read the attachment")?;
        let mut bytes = Vec::new();
        file.take(MAX_ATTACHMENT_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "could not read the attachment")?;
        if bytes.len() > MAX_ATTACHMENT_BYTES {
            return Err(format!(
                "the attachment exceeds the {} MiB per-file limit",
                MAX_ATTACHMENT_BYTES / (1024 * 1024)
            ));
        }
        if !bytes.starts_with(PNG_MAGIC) {
            return Err("the attachment is not a PNG image".to_owned());
        }
        Ok(AttachmentFile {
            name: artifact.choice.name.clone(),
            bytes,
        })
    }
}

fn inspect(
    root: &Path,
    relative: &Path,
    id: String,
    name: String,
    framed: bool,
) -> Result<Option<Artifact>, String> {
    let path = root.join(relative);
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("could not inspect a compiled capture image".to_owned()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(if framed {
            "a compiled capture frame is not a regular file".to_owned()
        } else {
            "the compiled capture contact sheet is not a regular file".to_owned()
        });
    }
    if metadata.len() > MAX_ATTACHMENT_BYTES as u64 {
        return Err(if framed {
            "a compiled capture frame exceeds the Jira attachment size limit".to_owned()
        } else {
            "the compiled capture contact sheet exceeds the Jira attachment size limit".to_owned()
        });
    }
    let canonical = path
        .canonicalize()
        .map_err(|_| "a compiled capture image is missing or unsafe")?;
    if !canonical.starts_with(root) {
        return Err("a compiled capture image is outside the capture bundle".to_owned());
    }
    let mut magic = [0u8; 8];
    let mut file = File::open(&canonical)
        .map_err(|_| "a compiled capture image could not be read".to_owned())?;
    file.read_exact(&mut magic)
        .map_err(|_| "a compiled capture image is not a valid PNG".to_owned())?;
    if &magic != PNG_MAGIC {
        return Err("a compiled capture image is not a valid PNG".to_owned());
    }
    Ok(Some(Artifact {
        choice: AttachmentChoice { id, name },
        path: canonical,
        size: metadata.len(),
    }))
}

fn frame_number(name: &str) -> Option<u32> {
    let digits = name.strip_prefix("frame-")?.strip_suffix(".png")?;
    if digits.len() != 2 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let number = digits.parse::<u32>().ok()?;
    (1..=MAX_FRAME_ATTACHMENTS)
        .contains(&number)
        .then_some(number)
}

pub(crate) fn valid_id(id: &str) -> bool {
    if id == CONTACT_SHEET_ID {
        return true;
    }
    let Some(digits) = id.strip_prefix("frame-") else {
        return false;
    };
    digits.len() == 2
        && digits
            .parse::<u32>()
            .is_ok_and(|number| (1..=MAX_FRAME_ATTACHMENTS).contains(&number))
}

pub(crate) fn describe_choices(choices: &[AttachmentChoice]) -> String {
    choices
        .iter()
        .map(|choice| {
            let description = if choice.id == CONTACT_SHEET_ID {
                "contact sheet of the selected keyframes".to_owned()
            } else {
                format!("keyframe #{}", choice.id.trim_start_matches("frame-"))
            };
            format!("- {}: {} ({description})", choice.id, choice.name)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nimage";

    fn write_png(root: &Path, relative: &str) {
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, PNG).unwrap();
    }

    #[test]
    fn inventory_uses_stable_ids_and_bounds_the_selection() {
        let temp = tempfile::tempdir().unwrap();
        write_png(temp.path(), "contact-sheet.png");
        write_png(temp.path(), "frames/frame-01.png");
        write_png(temp.path(), "frames/frame-02.png");
        fs::write(temp.path().join("frames/frame-99.png"), PNG).unwrap();
        fs::write(temp.path().join("frames/not-a-frame.png"), PNG).unwrap();

        let inventory = AttachmentInventory::load(temp.path()).unwrap();
        assert_eq!(
            inventory.choices(),
            vec![
                AttachmentChoice {
                    id: "contact-sheet".to_owned(),
                    name: "contact-sheet.png".to_owned()
                },
                AttachmentChoice {
                    id: "frame-01".to_owned(),
                    name: "frame-01.png".to_owned()
                },
                AttachmentChoice {
                    id: "frame-02".to_owned(),
                    name: "frame-02.png".to_owned()
                }
            ]
        );
        assert!(
            inventory
                .validate_selection(&["contact-sheet".to_owned(), "frame-02".to_owned()])
                .is_ok()
        );
        assert!(
            inventory
                .validate_selection(&["../contact-sheet.png".to_owned()])
                .is_err()
        );
        assert!(
            inventory
                .validate_selection(&["frame-99".to_owned()])
                .is_err()
        );
        assert!(
            inventory
                .validate_selection(&vec!["frame-01".to_owned(); MAX_ATTACHMENTS + 1])
                .is_err()
        );
        assert_eq!(inventory.read("frame-02").unwrap().name, "frame-02.png");
        assert_eq!(inventory.read("frame-02").unwrap().bytes, PNG);
    }

    #[test]
    fn video_media_is_not_an_automatic_attachment_choice() {
        let temp = tempfile::tempdir().unwrap();
        write_png(temp.path(), "contact-sheet.png");
        write_png(temp.path(), "frames/frame-01.png");
        fs::write(
            temp.path().join("recording.mp4"),
            b"\x00\x00\x00\x18ftypmp42video",
        )
        .unwrap();

        let inventory = AttachmentInventory::load(temp.path()).unwrap();
        assert_eq!(
            inventory.choices(),
            vec![
                AttachmentChoice {
                    id: "contact-sheet".to_owned(),
                    name: "contact-sheet.png".to_owned()
                },
                AttachmentChoice {
                    id: "frame-01".to_owned(),
                    name: "frame-01.png".to_owned()
                }
            ]
        );
        assert!(
            inventory
                .validate_selection(&["recording.mp4".to_owned()])
                .is_err()
        );
    }

    #[test]
    fn inventory_rejects_missing_magic_oversized_and_symlinked_images() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("frames")).unwrap();
        fs::write(temp.path().join("contact-sheet.png"), b"not a png").unwrap();
        assert!(AttachmentInventory::load(temp.path()).is_err());

        fs::write(temp.path().join("contact-sheet.png"), PNG).unwrap();
        fs::write(
            temp.path().join("frames/frame-01.png"),
            vec![0; MAX_ATTACHMENT_BYTES + 1],
        )
        .unwrap();
        assert!(AttachmentInventory::load(temp.path()).is_err());

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            fs::remove_file(temp.path().join("frames/frame-01.png")).unwrap();
            symlink(
                temp.path().join("contact-sheet.png"),
                temp.path().join("frames/frame-01.png"),
            )
            .unwrap();
            assert!(AttachmentInventory::load(temp.path()).is_err());
        }
    }

    #[test]
    fn selection_limits_cover_duplicates_unknown_ids_and_combined_size() {
        let temp = tempfile::tempdir().unwrap();
        write_png(temp.path(), "contact-sheet.png");
        let inventory = AttachmentInventory::load(temp.path()).unwrap();
        assert_eq!(MAX_ATTACHMENTS, 5);
        assert!(
            inventory
                .validate_selection(&["unknown".to_owned()])
                .is_err()
        );
        assert!(
            inventory
                .validate_selection(&["contact-sheet".to_owned(), "contact-sheet".to_owned()])
                .is_err()
        );

        let temp = tempfile::tempdir().unwrap();
        let large = [PNG, vec![0; 3 * 1024 * 1024].as_slice()].concat();
        for name in [
            "contact-sheet.png",
            "frames/frame-01.png",
            "frames/frame-02.png",
        ] {
            let path = temp.path().join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, &large).unwrap();
        }
        let inventory = AttachmentInventory::load(temp.path()).unwrap();
        assert!(
            inventory
                .validate_selection(&[
                    "contact-sheet".to_owned(),
                    "frame-01".to_owned(),
                    "frame-02".to_owned()
                ])
                .is_err()
        );
        assert!(
            inventory
                .validate_selection(&["contact-sheet".to_owned(), "frame-01".to_owned()])
                .is_ok()
        );
    }

    #[test]
    fn ids_and_descriptions_are_bounded() {
        assert!(valid_id("contact-sheet"));
        assert!(valid_id("frame-01"));
        assert!(valid_id("frame-24"));
        assert!(!valid_id("frame-0"));
        assert!(!valid_id("frame-25"));
        assert!(!valid_id("frame-001"));
        assert!(!valid_id("frames/frame-01.png"));
        assert!(!valid_id("contact-sheet.png"));
        assert!(
            describe_choices(&[AttachmentChoice {
                id: "frame-01".to_owned(),
                name: "frame-01.png".to_owned()
            }])
            .contains("keyframe #01")
        );
    }
}
