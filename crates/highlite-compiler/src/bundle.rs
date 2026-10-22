//! Turn a compiled capture into the folder an agent reads: transparent keyframes,
//! a contact sheet, `summary.md`, `scrawl.json`, and the machine-readable bundle.

use std::fs;
use std::path::{Path, PathBuf};

use crate::model::{CompiledBundle, CompiledKeyframe, KeyframeReason};
use crate::render::{
    RenderError, SheetFrame, load_rgba, render_contact_sheet, render_frame, save_png,
};
use crate::scrawl::{ScrawlExportOptions, to_scrawl_bundle};

#[derive(Debug, Clone)]
pub struct BundleOptions {
    /// Burn captured annotations into the rendered keyframes.
    pub annotations: bool,
    /// Write `contact-sheet.png`.
    pub contact_sheet: bool,
    pub contact_sheet_width: u32,
}

impl Default for BundleOptions {
    fn default() -> Self {
        Self {
            annotations: true,
            contact_sheet: true,
            contact_sheet_width: 1600,
        }
    }
}

#[derive(Debug, Clone)]
pub struct WrittenBundle {
    pub directory: PathBuf,
    pub summary: String,
    pub keyframe_paths: Vec<String>,
    pub contact_sheet: Option<String>,
}

fn caption_for(keyframe: &CompiledKeyframe) -> String {
    match (&keyframe.cue, &keyframe.said) {
        (Some(cue), Some(said)) => return format!("cue “{cue}” · “{said}”"),
        (Some(cue), None) => return format!("cue “{cue}”"),
        (None, Some(said)) => return format!("“{said}”"),
        (None, None) => {}
    }
    match keyframe.reason {
        KeyframeReason::Mark => "marked".to_owned(),
        KeyframeReason::Annotation => "annotated".to_owned(),
        KeyframeReason::Interaction => "interaction".to_owned(),
        KeyframeReason::VisualChange => "screen changed".to_owned(),
        KeyframeReason::SpeechCue => "spoke".to_owned(),
    }
}

fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> Result<(), RenderError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| RenderError::new(format!("Could not serialize JSON: {error}")))?;
    fs::write(path, format!("{json}\n"))
        .map_err(|error| RenderError::new(format!("Could not write {}: {error}", path.display())))
}

/// Materialize a compiled capture in `output_directory`.
///
/// `capture_directory` is the folder that holds the original `manifest.json` and
/// the media it references. Keyframes are renumbered sequentially and rewritten
/// as PNG so the bundle is self-contained.
pub fn write_bundle(
    compiled: &mut CompiledBundle,
    capture_directory: &Path,
    output_directory: &Path,
    options: &BundleOptions,
) -> Result<WrittenBundle, RenderError> {
    fs::create_dir_all(output_directory).map_err(|error| {
        RenderError::new(format!(
            "Could not create {}: {error}",
            output_directory.display()
        ))
    })?;
    let canonical_capture = capture_directory.canonicalize().map_err(|error| {
        RenderError::new(format!(
            "Could not read {}: {error}",
            capture_directory.display()
        ))
    })?;
    let canonical_output = output_directory.canonicalize().map_err(|error| {
        RenderError::new(format!(
            "Could not read {}: {error}",
            output_directory.display()
        ))
    })?;
    if canonical_capture == canonical_output {
        return Err(RenderError::new(
            "The bundle output must be a different folder from the capture.",
        ));
    }

    let frames_directory = output_directory.join("frames");
    fs::create_dir_all(&frames_directory).map_err(|error| {
        RenderError::new(format!(
            "Could not create {}: {error}",
            frames_directory.display()
        ))
    })?;

    let mut paths = Vec::with_capacity(compiled.keyframes.len());
    let mut images = Vec::with_capacity(compiled.keyframes.len());

    for (position, keyframe) in compiled.keyframes.iter().enumerate() {
        let source_path = resolve_capture_path(capture_directory, &keyframe.image_path)?;
        let annotations: Vec<_> = if options.annotations {
            compiled
                .manifest
                .annotations
                .iter()
                .filter(|annotation| keyframe.annotation_ids.contains(&annotation.id))
                .cloned()
                .collect()
        } else {
            Vec::new()
        };

        let viewport = compiled.viewport.or(compiled.manifest.viewport);
        let rendered = render_frame(
            &source_path,
            keyframe.crop,
            &annotations,
            viewport,
            keyframe.at_ms,
        )?;
        let relative = format!("frames/frame-{:02}.png", position + 1);
        save_png(&rendered.image, &output_directory.join(&relative))?;
        paths.push(relative);
        images.push(rendered.image);
    }

    for (position, path) in paths.iter().enumerate() {
        if let Some(keyframe) = compiled.keyframes.get_mut(position) {
            keyframe.image_path = path.clone();
        }
        if let Some(keyframe) = compiled.manifest.keyframes.get_mut(position) {
            keyframe.image_path = path.clone();
        }
        if let Some(keyframe) = compiled.analysis.keyframes.get_mut(position) {
            keyframe.image_path = path.clone();
        }
    }

    let contact_sheet = if options.contact_sheet && !images.is_empty() {
        let title = if compiled.manifest.page.title.is_empty() {
            compiled.manifest.page.initial_url.clone()
        } else {
            format!(
                "{} · {}",
                compiled.manifest.page.title, compiled.manifest.page.initial_url
            )
        };
        let sheet_frames: Vec<SheetFrame<'_>> = compiled
            .keyframes
            .iter()
            .zip(images.iter())
            .map(|(keyframe, image)| SheetFrame {
                image,
                index: keyframe.index,
                at_ms: keyframe.at_ms,
                reason: keyframe.reason,
                caption: caption_for(keyframe),
            })
            .collect();
        let sheet = render_contact_sheet(&sheet_frames, &title, options.contact_sheet_width)?;
        let relative = "contact-sheet.png".to_owned();
        save_png(&sheet, &output_directory.join(&relative))?;
        Some(relative)
    } else {
        None
    };

    if let Some(contact_sheet) = &contact_sheet {
        compiled.manifest.artifacts.contact_sheet = Some(contact_sheet.clone());
    }

    if let Some(audio) = &compiled.manifest.artifacts.audio {
        let source = resolve_capture_path(capture_directory, audio)?;
        let file_name = Path::new(audio)
            .file_name()
            .ok_or_else(|| RenderError::new("The manifest audio path has no file name."))?
            .to_owned();
        let destination = output_directory.join(&file_name);
        fs::copy(&source, &destination).map_err(|error| {
            RenderError::new(format!(
                "Could not copy {} to {}: {error}",
                source.display(),
                destination.display()
            ))
        })?;
        compiled.manifest.artifacts.audio = Some(file_name.to_string_lossy().into_owned());
    }

    let mut scrawl = to_scrawl_bundle(compiled, &ScrawlExportOptions::default())
        .map_err(|error| RenderError::new(format!("Could not build scrawl.json: {error}")))?;
    scrawl.contact_sheet = contact_sheet.clone().unwrap_or_default();

    fs::write(output_directory.join("summary.md"), &compiled.summary)
        .map_err(|error| RenderError::new(format!("Could not write summary.md: {error}")))?;
    write_json(&output_directory.join("manifest.json"), &compiled.manifest)?;
    write_json(&output_directory.join("analysis.json"), &compiled.analysis)?;
    write_json(&output_directory.join("bundle.json"), compiled)?;
    write_json(&output_directory.join("scrawl.json"), &scrawl)?;

    Ok(WrittenBundle {
        directory: output_directory.to_path_buf(),
        summary: compiled.summary.clone(),
        keyframe_paths: paths,
        contact_sheet,
    })
}

/// Resolve a relative path inside a capture directory, rejecting escapes.
pub fn resolve_capture_path(
    capture_directory: &Path,
    relative: &str,
) -> Result<PathBuf, RenderError> {
    let candidate = capture_directory.join(relative);
    let canonical_capture = capture_directory.canonicalize().map_err(|error| {
        RenderError::new(format!(
            "Could not read {}: {error}",
            capture_directory.display()
        ))
    })?;
    let canonical = candidate.canonicalize().map_err(|error| {
        RenderError::new(format!("Could not read {}: {error}", candidate.display()))
    })?;
    if !canonical.starts_with(&canonical_capture) {
        return Err(RenderError::new(format!(
            "The manifest references {} outside the capture folder.",
            relative
        )));
    }
    Ok(canonical)
}

/// Read an optional frame image for callers that need the rendered pixels.
pub fn read_frame(path: &Path) -> Result<image::RgbaImage, RenderError> {
    load_rgba(path)
}
