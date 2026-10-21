use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const COMPILER_SCHEMA_VERSION: &str = "0.1.0";
pub const COMPILER_NAME: &str = "highlite-compiler";
pub const COMPILER_VERSION: &str = "0.1.0";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub initial_url: String,
    pub title: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ViewportRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum TimelineKind {
    Click,
    Scroll,
    Navigate,
    Annotation,
    Mark,
    Target,
    Context,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TimelineEvent {
    pub id: String,
    pub seq: u64,
    pub at_ms: u64,
    pub kind: TimelineKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_id: Option<String>,
    #[serde(default)]
    pub payload: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_excerpt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selector: Option<String>,
    pub rect: ViewportRect,
    pub page_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<BTreeMap<String, Value>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AnnotationKind {
    Freehand,
    Circle,
    Arrow,
    Highlight,
}

impl AnnotationKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Freehand => "freehand",
            Self::Circle => "circle",
            Self::Arrow => "arrow",
            Self::Highlight => "highlight",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum CoordinateSpace {
    ViewportNormalized,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Annotation {
    pub id: String,
    pub at_ms: u64,
    pub kind: AnnotationKind,
    pub points: Vec<Point>,
    pub coordinate_space: CoordinateSpace,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WordTiming {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptSegment {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub word_timings: Vec<WordTiming>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum KeyframeReason {
    Mark,
    Annotation,
    Interaction,
    VisualChange,
    SpeechCue,
}

impl KeyframeReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mark => "mark",
            Self::Annotation => "annotation",
            Self::Interaction => "interaction",
            Self::VisualChange => "visual-change",
            Self::SpeechCue => "speech-cue",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Keyframe {
    pub id: String,
    pub at_ms: u64,
    pub image_path: String,
    pub target_ids: Vec<String>,
    pub annotation_ids: Vec<String>,
    pub transcript_segment_ids: Vec<String>,
    pub reason: KeyframeReason,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Artifacts {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contact_sheet: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HighliteManifest {
    pub schema_version: String,
    pub session_id: String,
    pub created_at: String,
    pub page: Page,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewport: Option<ViewportRect>,
    pub duration_ms: u64,
    pub timeline: Vec<TimelineEvent>,
    pub targets: Vec<Target>,
    pub annotations: Vec<Annotation>,
    pub transcript: Vec<TranscriptSegment>,
    pub keyframes: Vec<Keyframe>,
    pub artifacts: Artifacts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_offset_ms: Option<u64>,
    pub capture_warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FrameCandidate {
    #[serde(flatten)]
    pub keyframe: Keyframe,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompileOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_keyframes: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_gap_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clause_gap_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub crop_padding_px: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub crop: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverage: Option<bool>,
    /// Detect spoken cues ("here", "look", "watch", …) and keep nearby frames.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speech_cues: Option<bool>,
    /// How close a frame must be to a strong cue to be selected by it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cue_window_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compiled_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompileInput {
    pub manifest: HighliteManifest,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frames: Option<Vec<FrameCandidate>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewport: Option<ViewportRect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<CompileOptions>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompiledKeyframe {
    pub id: String,
    pub index: usize,
    pub at_ms: u64,
    pub image_path: String,
    pub reason: KeyframeReason,
    pub target_ids: Vec<String>,
    pub annotation_ids: Vec<String>,
    pub transcript_segment_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub said: Option<String>,
    /// The spoken cue word that selected this frame, when one did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cue: Option<String>,
    pub score: i32,
    pub score_reasons: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub crop: Option<NormalizedRect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EventAlignment {
    pub event_id: String,
    pub kind: TimelineKind,
    pub at_ms: u64,
    pub segment_ids: Vec<String>,
    pub keyframe_ids: Vec<String>,
    pub confidence: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DocsRef {
    pub target_id: String,
    pub docs_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<BTreeMap<String, Value>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptAnalysis {
    pub segments: Vec<TranscriptSegment>,
    pub text: String,
    pub has_word_timings: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureAnalysis {
    pub schema_version: String,
    pub session_id: String,
    pub duration_ms: u64,
    pub page: Page,
    pub transcript: TranscriptAnalysis,
    pub alignment: Vec<EventAlignment>,
    pub keyframes: Vec<CompiledKeyframe>,
    pub targets: Vec<Target>,
    pub annotations: Vec<Annotation>,
    pub docs_refs: Vec<DocsRef>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompilerInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EffectiveOptions {
    pub max_keyframes: usize,
    pub min_gap_ms: u64,
    pub clause_gap_ms: u64,
    pub crop: bool,
    pub coverage: bool,
    pub speech_cues: bool,
    pub cue_window_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompileProvenance {
    pub compiler: CompilerInfo,
    pub compiled_at: String,
    pub options: EffectiveOptions,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CompiledBundle {
    pub schema_version: String,
    pub manifest: HighliteManifest,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewport: Option<ViewportRect>,
    pub keyframes: Vec<CompiledKeyframe>,
    pub analysis: CaptureAnalysis,
    pub summary: String,
    pub warnings: Vec<String>,
    pub provenance: CompileProvenance,
}
