use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::model::{
    AnnotationKind, CompiledBundle, CompiledKeyframe, HighliteManifest, KeyframeReason, Point,
    Target, TimelineKind, ViewportRect,
};

/// Scrawl bundle fields mirrored from `kitlangton/scrawl` `src/model.rs` (MIT), schema
/// version 1. This is an export target, not a claim of full compatibility: the bundle is
/// a browser subset (no native window log, cursor or video) and must be validated with
/// Scrawl's own CLI before it is advertised as Scrawl-compatible.
pub const SCRAWL_BUNDLE_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrawlShape {
    Circle,
    Underline,
    Line,
    Arrow,
    Tap,
    Pin,
    Mark,
    Flag,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrawlKeyframeReason {
    Mark,
    Click,
    Laser,
    SceneChange,
    Speech,
    Initial,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrawlCaptureMode {
    Display,
    Window,
    Region,
    Device,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlTargetFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlTargetInfo {
    pub mode: ScrawlCaptureMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<u32>,
    pub display_id: u32,
    pub frame: ScrawlTargetFrame,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlTranscriptSegment {
    pub t0: u64,
    pub t1: u64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlWordTiming {
    pub t0: u64,
    pub t1: u64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlTranscriptData {
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub text: String,
    pub segments: Vec<ScrawlTranscriptSegment>,
    #[serde(default)]
    pub words: Vec<ScrawlWordTiming>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlStroke {
    pub t0: u64,
    pub t1: u64,
    pub fw: f64,
    pub fh: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<u32>,
    pub laser: bool,
    pub pts: Vec<i32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlMark {
    pub id: String,
    pub strokes: Vec<usize>,
    pub t0: u64,
    pub t1: u64,
    pub box_norm: [f64; 4],
    pub shape: ScrawlShape,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<[f64; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<[f64; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on: Option<String>,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ScrawlEvent {
    Click {
        t: u64,
        x: f64,
        y: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        button: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        label: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        role: Option<String>,
    },
    AppEvent {
        t: u64,
        label: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlKeyframe {
    pub index: usize,
    pub t: u64,
    pub reason: ScrawlKeyframeReason,
    pub file: String,
    pub event: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub said: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mark_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<[f64; 2]>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlScreenSpan {
    pub t0: u64,
    pub t1: u64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScrawlBundleV1 {
    pub version: u32,
    pub id: String,
    pub created_at_ms: u64,
    pub duration_ms: u64,
    pub target: ScrawlTargetInfo,
    pub transcript: ScrawlTranscriptData,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub strokes: Vec<ScrawlStroke>,
    pub marks: Vec<ScrawlMark>,
    pub events: Vec<ScrawlEvent>,
    pub keyframes: Vec<ScrawlKeyframe>,
    pub contact_sheet: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_offset_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_changes: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screens: Option<Vec<ScrawlScreenSpan>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub windows: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cursor: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub autocrop: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub destination: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct ScrawlExportOptions {
    pub viewport: Option<ViewportRect>,
    pub app: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrawlExportError {
    MissingViewport,
}

impl std::fmt::Display for ScrawlExportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingViewport => formatter.write_str(
                "Scrawl export requires a positive viewport; pass compile input viewport.",
            ),
        }
    }
}

impl std::error::Error for ScrawlExportError {}

fn clamp01(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

fn number_or(value: Option<&Value>, fallback: f64) -> f64 {
    value
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .unwrap_or(fallback)
}

fn target_for<'a>(manifest: &'a HighliteManifest, target_id: Option<&str>) -> Option<&'a Target> {
    target_id.and_then(|id| {
        manifest
            .targets
            .iter()
            .find(|target| target.id.as_str() == id)
    })
}

fn shape_for(kind: AnnotationKind) -> ScrawlShape {
    match kind {
        AnnotationKind::Circle => ScrawlShape::Circle,
        AnnotationKind::Arrow => ScrawlShape::Arrow,
        AnnotationKind::Highlight => ScrawlShape::Underline,
        AnnotationKind::Freehand => ScrawlShape::Mark,
    }
}

fn bounds_of(points: &[Point]) -> [f64; 4] {
    if points.is_empty() {
        return [0.0, 0.0, 0.0, 0.0];
    }
    let mut min_x = 1.0_f64;
    let mut min_y = 1.0_f64;
    let mut max_x = 0.0_f64;
    let mut max_y = 0.0_f64;
    for point in points {
        min_x = min_x.min(point.x);
        min_y = min_y.min(point.y);
        max_x = max_x.max(point.x);
        max_y = max_y.max(point.y);
    }
    [
        clamp01(min_x),
        clamp01(min_y),
        clamp01(max_x),
        clamp01(max_y),
    ]
}

fn frame_for_annotation(keyframes: &[CompiledKeyframe], annotation_id: &str) -> Option<String> {
    keyframes
        .iter()
        .find(|keyframe| keyframe.annotation_ids.iter().any(|id| id == annotation_id))
        .map(|keyframe| keyframe.image_path.clone())
}

fn scrawl_reason(reason: KeyframeReason) -> ScrawlKeyframeReason {
    match reason {
        KeyframeReason::Mark | KeyframeReason::Annotation => ScrawlKeyframeReason::Mark,
        KeyframeReason::VisualChange => ScrawlKeyframeReason::SceneChange,
        KeyframeReason::SpeechCue => ScrawlKeyframeReason::Speech,
        KeyframeReason::Interaction => ScrawlKeyframeReason::Click,
    }
}

fn route_name(href: &str) -> String {
    if let Some((_, rest)) = href.split_once("://") {
        let rest = rest.split(['?', '#']).next().unwrap_or(rest);
        let (authority, path) = match rest.find('/') {
            Some(index) => (&rest[..index], &rest[index..]),
            None => (rest, ""),
        };
        if path.is_empty() || path == "/" {
            authority.to_owned()
        } else {
            format!("{authority}{path}")
        }
    } else {
        href.to_owned()
    }
}

fn build_screens(manifest: &HighliteManifest) -> Vec<ScrawlScreenSpan> {
    let mut spans = Vec::new();
    let mut start = 0_u64;
    let mut name = route_name(&manifest.page.initial_url);

    for event in manifest
        .timeline
        .iter()
        .filter(|event| event.kind == TimelineKind::Navigate)
    {
        let at = event.at_ms.min(manifest.duration_ms);
        if at > start {
            spans.push(ScrawlScreenSpan {
                t0: start,
                t1: at,
                name: name.clone(),
            });
        }
        start = at;
        name = event
            .payload
            .get("to")
            .and_then(Value::as_str)
            .map_or_else(|| name.clone(), route_name);
    }

    if manifest.duration_ms > start {
        spans.push(ScrawlScreenSpan {
            t0: start,
            t1: manifest.duration_ms,
            name,
        });
    }

    spans
}

pub fn to_scrawl_bundle(
    compiled: &CompiledBundle,
    options: &ScrawlExportOptions,
) -> Result<ScrawlBundleV1, ScrawlExportError> {
    let manifest = &compiled.manifest;
    let viewport = options
        .viewport
        .or(compiled.viewport)
        .ok_or(ScrawlExportError::MissingViewport)?;
    if !viewport.width.is_finite()
        || !viewport.height.is_finite()
        || viewport.width <= 0.0
        || viewport.height <= 0.0
    {
        return Err(ScrawlExportError::MissingViewport);
    }

    let created_at_ms = OffsetDateTime::parse(&manifest.created_at, &Rfc3339)
        .map(|date| (date.unix_timestamp().max(0) as u64) * 1_000 + u64::from(date.millisecond()))
        .unwrap_or(0);

    let segments: Vec<ScrawlTranscriptSegment> = manifest
        .transcript
        .iter()
        .map(|segment| ScrawlTranscriptSegment {
            t0: segment.start_ms,
            t1: segment.end_ms,
            text: segment.text.clone(),
        })
        .collect();
    let words: Vec<ScrawlWordTiming> = manifest
        .transcript
        .iter()
        .flat_map(|segment| {
            segment.word_timings.iter().map(|word| ScrawlWordTiming {
                t0: word.start_ms,
                t1: word.end_ms,
                text: word.text.clone(),
            })
        })
        .collect();
    let text = manifest
        .transcript
        .iter()
        .map(|segment| segment.text.trim())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join(" ");

    let mut strokes = Vec::new();
    let mut marks = Vec::new();
    let mut mark_id_by_annotation: BTreeMap<String, String> = BTreeMap::new();

    for (index, annotation) in manifest.annotations.iter().enumerate() {
        let mark_id = format!("m{}", index + 1);
        mark_id_by_annotation.insert(annotation.id.clone(), mark_id.clone());
        strokes.push(ScrawlStroke {
            t0: annotation.at_ms,
            t1: annotation.at_ms,
            fw: viewport.width,
            fh: viewport.height,
            on: None,
            pin: None,
            laser: false,
            pts: annotation
                .points
                .iter()
                .flat_map(|point| {
                    [
                        (clamp01(point.x) * 10_000.0).round() as i32,
                        (clamp01(point.y) * 10_000.0).round() as i32,
                        0,
                    ]
                })
                .collect(),
        });

        let target = target_for(manifest, annotation.target_id.as_deref());
        let label =
            target.and_then(|target| target.label.clone().or_else(|| target.text_excerpt.clone()));
        marks.push(ScrawlMark {
            id: mark_id,
            strokes: vec![index],
            t0: annotation.at_ms,
            t1: annotation.at_ms,
            box_norm: bounds_of(&annotation.points),
            shape: shape_for(annotation.kind),
            from: None,
            to: None,
            pin: None,
            on: None,
            description: label.map_or_else(
                || annotation.kind.as_str().to_owned(),
                |label| format!("{} on “{label}”", annotation.kind.as_str()),
            ),
            frame: frame_for_annotation(&compiled.keyframes, &annotation.id),
        });
    }

    let mut events = Vec::new();
    for event in &manifest.timeline {
        match event.kind {
            TimelineKind::Click => {
                let target = target_for(manifest, event.target_id.as_deref());
                let label = target.and_then(|target| {
                    target.label.clone().or_else(|| target.text_excerpt.clone())
                });
                events.push(ScrawlEvent::Click {
                    t: event.at_ms,
                    x: clamp01(
                        number_or(event.payload.get("x"), viewport.width / 2.0) / viewport.width,
                    ),
                    y: clamp01(
                        number_or(event.payload.get("y"), viewport.height / 2.0) / viewport.height,
                    ),
                    button: event
                        .payload
                        .get("button")
                        .and_then(Value::as_i64)
                        .map(|button| button.to_string())
                        .or_else(|| Some("left".to_owned())),
                    label,
                    role: target.and_then(|target| target.role.clone()),
                });
            }
            TimelineKind::Navigate => events.push(ScrawlEvent::AppEvent {
                t: event.at_ms,
                label: format!(
                    "navigate to {}",
                    event
                        .payload
                        .get("to")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                ),
            }),
            TimelineKind::Scroll => events.push(ScrawlEvent::AppEvent {
                t: event.at_ms,
                label: format!(
                    "scroll to {}, {}",
                    event
                        .payload
                        .get("x")
                        .and_then(Value::as_f64)
                        .unwrap_or(0.0),
                    event
                        .payload
                        .get("y")
                        .and_then(Value::as_f64)
                        .unwrap_or(0.0)
                ),
            }),
            TimelineKind::Mark => events.push(ScrawlEvent::AppEvent {
                t: event.at_ms,
                label: format!(
                    "mark: {}",
                    event
                        .payload
                        .get("label")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                ),
            }),
            TimelineKind::Annotation => events.push(ScrawlEvent::AppEvent {
                t: event.at_ms,
                label: format!(
                    "annotation: {}",
                    event
                        .payload
                        .get("annotationKind")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                ),
            }),
            TimelineKind::Context => events.push(ScrawlEvent::AppEvent {
                t: event.at_ms,
                label: format!(
                    "context: {}={}",
                    event
                        .payload
                        .get("scope")
                        .and_then(Value::as_str)
                        .unwrap_or(""),
                    event
                        .payload
                        .get("value")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                ),
            }),
            TimelineKind::Target => {}
        }
    }

    let screens = build_screens(manifest);
    let keyframes: Vec<ScrawlKeyframe> = compiled
        .keyframes
        .iter()
        .map(|keyframe| {
            let mark_id = keyframe
                .annotation_ids
                .iter()
                .find_map(|annotation_id| mark_id_by_annotation.get(annotation_id))
                .cloned();
            ScrawlKeyframe {
                index: keyframe.index,
                t: keyframe.at_ms,
                reason: scrawl_reason(keyframe.reason),
                file: keyframe.image_path.clone(),
                event: format!("highlite:{}", keyframe.id),
                said: keyframe.said.clone(),
                mark_id,
                cursor: None,
            }
        })
        .collect();

    Ok(ScrawlBundleV1 {
        version: SCRAWL_BUNDLE_VERSION,
        id: manifest.session_id.clone(),
        created_at_ms,
        duration_ms: manifest.duration_ms,
        target: ScrawlTargetInfo {
            mode: ScrawlCaptureMode::Window,
            app: Some(options.app.clone().unwrap_or_else(|| "Browser".to_owned())),
            bundle_id: None,
            window_title: (!manifest.page.title.is_empty()).then(|| manifest.page.title.clone()),
            window_id: None,
            display_id: 0,
            frame: ScrawlTargetFrame {
                x: 0.0,
                y: 0.0,
                width: viewport.width,
                height: viewport.height,
                scale: 1.0,
            },
        },
        transcript: ScrawlTranscriptData {
            source: "highlite".to_owned(),
            model: None,
            text,
            segments,
            words,
            estimated: None,
        },
        note: None,
        strokes,
        marks,
        events,
        keyframes,
        contact_sheet: "contact-sheet.png".to_owned(),
        video: manifest.artifacts.video.clone(),
        video_offset_ms: None,
        audio: manifest.artifacts.audio.clone(),
        source: Some("browser".to_owned()),
        context: None,
        context_changes: None,
        screens: (!screens.is_empty()).then_some(screens),
        windows: Vec::new(),
        cursor: Vec::new(),
        autocrop: None,
        destination: None,
    })
}
