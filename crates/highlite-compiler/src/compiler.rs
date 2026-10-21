use std::cmp::Ordering;

use serde_json::Value;

use crate::alignment::{AlignmentTarget, align_transcript};
use crate::cues::{SpeechCue, detect_speech_cues, weak_window_ms};
use crate::model::{
    COMPILER_NAME, COMPILER_SCHEMA_VERSION, COMPILER_VERSION, CaptureAnalysis, CompileInput,
    CompileOptions, CompileProvenance, CompiledBundle, CompiledKeyframe, CompilerInfo, DocsRef,
    EffectiveOptions, EventAlignment, FrameCandidate, HighliteManifest, Keyframe, KeyframeReason,
    NormalizedRect, Target, TimelineEvent, TimelineKind, TranscriptAnalysis, ViewportRect,
};
use crate::summary::build_handoff_summary;

const DEFAULT_MIN_GAP_MS: u64 = 500;
const DEFAULT_CLAUSE_GAP_MS: u64 = 1_500;
const DEFAULT_CROP_PADDING_PX: f64 = 24.0;
const DEFAULT_CUE_WINDOW_MS: u64 = 1_200;
const MIN_CROP_FRACTION: f64 = 0.4;
const MAX_KEYFRAME_CAP: usize = 24;
const EVENT_MATCH_MS: u64 = 1_200;
const COVERAGE_GAP_MS: u64 = 35_000;
const DOCS_METADATA_KEYS: [&str; 5] = ["docsId", "docs", "doc", "documentation", "docsPath"];

pub trait DocsResolver {
    fn resolve(&self, target: &Target, manifest: &HighliteManifest) -> Option<DocsRef>;
}

impl<F> DocsResolver for F
where
    F: Fn(&Target, &HighliteManifest) -> Option<DocsRef>,
{
    fn resolve(&self, target: &Target, manifest: &HighliteManifest) -> Option<DocsRef> {
        self(target, manifest)
    }
}

#[derive(Debug, Clone)]
struct Candidate {
    frame: FrameCandidate,
    reason: KeyframeReason,
    target_id: Option<String>,
    annotation_id: Option<String>,
    anchor_ms: u64,
    score: i32,
    score_reasons: Vec<String>,
    pinned: bool,
    cue: Option<SpeechCue>,
}

struct NormalizedOptions {
    max_keyframes: usize,
    min_gap_ms: u64,
    clause_gap_ms: u64,
    crop_padding_px: f64,
    crop: bool,
    coverage: bool,
    speech_cues: bool,
    cue_window_ms: u64,
    compiled_at: String,
}

#[derive(Default)]
struct Warnings(Vec<String>);

impl Warnings {
    fn add(&mut self, message: impl Into<String>) {
        let message = message.into();
        if !self.0.contains(&message) {
            self.0.push(message);
        }
    }

    fn into_vec(self) -> Vec<String> {
        self.0
    }
}

/// Scrawl's budget: six frames up to 20 s, then one more per 20 s, capped at twelve.
pub fn keyframe_budget(duration_ms: u64) -> usize {
    (6 + duration_ms.saturating_sub(20_000) / 20_000).min(12) as usize
}

fn finite_or(value: Option<f64>, fallback: f64) -> f64 {
    value.filter(|value| value.is_finite()).unwrap_or(fallback)
}

fn normalize_options(
    options: Option<&CompileOptions>,
    manifest: &HighliteManifest,
) -> NormalizedOptions {
    let requested = options
        .and_then(|options| options.max_keyframes)
        .map_or_else(
            || keyframe_budget(manifest.duration_ms),
            |value| value as usize,
        );

    NormalizedOptions {
        max_keyframes: requested.min(MAX_KEYFRAME_CAP),
        min_gap_ms: options
            .and_then(|options| options.min_gap_ms)
            .unwrap_or(DEFAULT_MIN_GAP_MS),
        clause_gap_ms: options
            .and_then(|options| options.clause_gap_ms)
            .unwrap_or(DEFAULT_CLAUSE_GAP_MS)
            .max(1),
        crop_padding_px: finite_or(
            options.and_then(|options| options.crop_padding_px),
            DEFAULT_CROP_PADDING_PX,
        )
        .max(0.0),
        crop: options.and_then(|options| options.crop).unwrap_or(true),
        coverage: options.and_then(|options| options.coverage).unwrap_or(true),
        speech_cues: options
            .and_then(|options| options.speech_cues)
            .unwrap_or(true),
        cue_window_ms: options
            .and_then(|options| options.cue_window_ms)
            .unwrap_or(DEFAULT_CUE_WINDOW_MS)
            .max(1),
        compiled_at: options
            .and_then(|options| options.compiled_at.clone())
            .unwrap_or_else(|| manifest.created_at.clone()),
    }
}

fn format_clock(ms: u64) -> String {
    let total_seconds = ms / 1_000;
    format!("{}:{:02}", total_seconds / 60, total_seconds % 60)
}

fn unique_strings(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        if !result.contains(&value) {
            result.push(value);
        }
    }
    result
}

fn by_time(left: &Candidate, right: &Candidate) -> Ordering {
    left.frame
        .keyframe
        .at_ms
        .cmp(&right.frame.keyframe.at_ms)
        .then(left.score.cmp(&right.score))
}

fn nearest_event(
    timeline: &[TimelineEvent],
    at_ms: u64,
    max_distance_ms: u64,
) -> Option<&TimelineEvent> {
    let mut best: Option<&TimelineEvent> = None;
    let mut best_distance = u64::MAX;

    for event in timeline {
        let distance = event.at_ms.abs_diff(at_ms);
        if distance < best_distance
            || (distance == best_distance
                && event.at_ms < best.map_or(u64::MAX, |event| event.at_ms))
        {
            best = Some(event);
            best_distance = distance;
        }
    }

    if best_distance <= max_distance_ms {
        best
    } else {
        None
    }
}

fn annotation_id_from_event(event: Option<&TimelineEvent>) -> Option<String> {
    match event {
        Some(event) if event.kind == TimelineKind::Annotation => event
            .payload
            .get("annotationId")
            .and_then(Value::as_str)
            .map(str::to_owned),
        _ => None,
    }
}

fn normalize_frame(frame: &FrameCandidate) -> Option<FrameCandidate> {
    if frame.keyframe.image_path.is_empty() {
        return None;
    }
    Some(frame.clone())
}

fn base_score(reason: KeyframeReason) -> i32 {
    match reason {
        KeyframeReason::Mark => 100,
        KeyframeReason::Annotation => 92,
        KeyframeReason::VisualChange => 72,
        KeyframeReason::SpeechCue => 66,
        KeyframeReason::Interaction => 60,
    }
}

fn nearest_cue(
    cues: &[SpeechCue],
    at_ms: u64,
    strong_window_ms: u64,
    allow_weak: bool,
) -> Option<(SpeechCue, u64)> {
    let weak_window = weak_window_ms(strong_window_ms);
    cues.iter()
        .filter_map(|cue| {
            if !cue.strong && !allow_weak {
                return None;
            }
            let window = if cue.strong {
                strong_window_ms
            } else {
                weak_window
            };
            let distance = cue.at_ms.abs_diff(at_ms);
            (distance <= window).then(|| (cue.clone(), distance))
        })
        .min_by_key(|(cue, distance)| (*distance, u8::from(!cue.strong)))
}

fn build_candidates(
    manifest: &HighliteManifest,
    frames: &[FrameCandidate],
    cues: &[SpeechCue],
    options: &NormalizedOptions,
) -> Vec<Candidate> {
    frames
        .iter()
        .map(|frame| {
            let event =
                nearest_event(&manifest.timeline, frame.keyframe.at_ms, EVENT_MATCH_MS).cloned();
            let reason = frame.keyframe.reason;
            let target_id = frame
                .keyframe
                .target_ids
                .first()
                .cloned()
                .or_else(|| event.as_ref().and_then(|event| event.target_id.clone()));
            let annotation_id = frame
                .keyframe
                .annotation_ids
                .first()
                .cloned()
                .or_else(|| annotation_id_from_event(event.as_ref()));
            let mut score = base_score(reason);
            let mut score_reasons = vec![format!("reason:{}", reason.as_str())];

            if target_id.is_some() {
                score += 8;
                score_reasons.push("target".to_owned());
            }
            if annotation_id.is_some() {
                score += 6;
                score_reasons.push("annotation".to_owned());
            }
            if let Some(event) = &event {
                match event.kind {
                    TimelineKind::Mark => {
                        score += 12;
                        score_reasons.push("event:mark".to_owned());
                    }
                    TimelineKind::Annotation => {
                        score += 10;
                        score_reasons.push("event:annotation".to_owned());
                    }
                    TimelineKind::Navigate => {
                        score += 6;
                        score_reasons.push("event:navigate".to_owned());
                    }
                    TimelineKind::Click => {
                        score += 4;
                        score_reasons.push("event:click".to_owned());
                    }
                    _ => {}
                }
            }

            let allow_weak = matches!(
                reason,
                KeyframeReason::Mark | KeyframeReason::Annotation | KeyframeReason::VisualChange
            );
            let cue = options
                .speech_cues
                .then(|| {
                    nearest_cue(
                        cues,
                        frame.keyframe.at_ms,
                        options.cue_window_ms,
                        allow_weak,
                    )
                })
                .flatten()
                .map(|(cue, _)| cue);
            if let Some(cue) = &cue {
                if cue.strong {
                    score += 24;
                }
                score_reasons.push(format!("cue:{}", cue.word));
            }

            Candidate {
                reason,
                target_id,
                annotation_id,
                anchor_ms: event
                    .as_ref()
                    .map_or(frame.keyframe.at_ms, |event| event.at_ms),
                score,
                score_reasons,
                pinned: matches!(reason, KeyframeReason::Mark | KeyframeReason::Annotation)
                    || cue.as_ref().is_some_and(|cue| cue.strong),
                cue,
                frame: frame.clone(),
            }
        })
        .collect()
}

fn is_duplicate(left: &Candidate, right: &Candidate, min_gap_ms: u64) -> bool {
    if left.frame.keyframe.image_path == right.frame.keyframe.image_path {
        return true;
    }
    if left.frame.signature.is_some()
        && right.frame.signature.is_some()
        && left.frame.signature == right.frame.signature
    {
        return true;
    }
    if left
        .frame
        .keyframe
        .at_ms
        .abs_diff(right.frame.keyframe.at_ms)
        >= min_gap_ms
    {
        return false;
    }
    if !left.pinned && !right.pinned {
        return true;
    }
    left.pinned && right.pinned && left.reason == right.reason && left.target_id == right.target_id
}

fn merge_candidates(left: Candidate, right: Candidate) -> Candidate {
    let (mut merged, loser) = if right.score > left.score {
        (right, left)
    } else {
        (left, right)
    };
    let Candidate {
        frame: loser_frame,
        target_id: loser_target,
        annotation_id: loser_annotation,
        score_reasons: loser_reasons,
        pinned: loser_pinned,
        cue: loser_cue,
        ..
    } = loser;

    merged.frame.keyframe.target_ids = unique_strings(
        merged
            .frame
            .keyframe
            .target_ids
            .into_iter()
            .chain(loser_frame.keyframe.target_ids),
    );
    merged.frame.keyframe.annotation_ids = unique_strings(
        merged
            .frame
            .keyframe
            .annotation_ids
            .into_iter()
            .chain(loser_frame.keyframe.annotation_ids),
    );
    merged.frame.keyframe.transcript_segment_ids = unique_strings(
        merged
            .frame
            .keyframe
            .transcript_segment_ids
            .into_iter()
            .chain(loser_frame.keyframe.transcript_segment_ids),
    );
    merged.score_reasons = unique_strings(merged.score_reasons.into_iter().chain(loser_reasons));
    merged.target_id = merged.target_id.or(loser_target);
    merged.annotation_id = merged.annotation_id.or(loser_annotation);
    merged.pinned = merged.pinned || loser_pinned;
    let preferred_cue = match (&merged.cue, &loser_cue) {
        (None, Some(_)) => loser_cue.clone(),
        (Some(current), Some(loser)) if loser.strong && !current.strong => loser_cue.clone(),
        _ => None,
    };
    if preferred_cue.is_some() {
        merged.cue = preferred_cue;
    }
    merged
}

fn dedupe_candidates(mut candidates: Vec<Candidate>, min_gap_ms: u64) -> Vec<Candidate> {
    candidates.sort_by(|left, right| {
        left.frame
            .keyframe
            .at_ms
            .cmp(&right.frame.keyframe.at_ms)
            .then(right.score.cmp(&left.score))
    });

    let mut kept: Vec<Candidate> = Vec::new();
    for candidate in candidates {
        if let Some(index) = kept
            .iter()
            .position(|existing| is_duplicate(existing, &candidate, min_gap_ms))
        {
            let existing = kept.remove(index);
            kept.insert(index, merge_candidates(existing, candidate));
        } else {
            kept.push(candidate);
        }
    }

    kept.sort_by(by_time);
    kept
}

fn add_coverage_frames(
    selected: &mut Vec<Candidate>,
    ordinary: &[Candidate],
    options: &NormalizedOptions,
    duration_ms: u64,
) {
    let mut boundaries = vec![0_u64];
    boundaries.extend(
        selected
            .iter()
            .map(|candidate| candidate.frame.keyframe.at_ms),
    );
    boundaries.push(duration_ms);

    let mut gaps: Vec<(u64, u64)> = boundaries
        .windows(2)
        .filter_map(|window| {
            let (start, end) = (window[0], window[1]);
            (end.saturating_sub(start) >= COVERAGE_GAP_MS).then_some((start, end))
        })
        .collect();
    gaps.sort_by(|left, right| {
        right
            .1
            .saturating_sub(right.0)
            .cmp(&left.1.saturating_sub(left.0))
    });

    for (start, end) in gaps {
        if selected.len() >= options.max_keyframes {
            return;
        }
        let chosen = ordinary
            .iter()
            .find(|item| {
                let at_ms = item.frame.keyframe.at_ms;
                at_ms > start
                    && at_ms < end
                    && !selected.iter().any(|chosen| {
                        chosen.frame.keyframe.image_path == item.frame.keyframe.image_path
                            && chosen.frame.keyframe.at_ms == at_ms
                    })
                    && selected.iter().all(|chosen| {
                        chosen.frame.keyframe.at_ms.abs_diff(at_ms) >= options.min_gap_ms
                    })
            })
            .cloned();
        if let Some(mut chosen) = chosen {
            if !chosen
                .score_reasons
                .iter()
                .any(|reason| reason == "coverage")
            {
                chosen.score_reasons.push("coverage".to_owned());
            }
            selected.push(chosen);
        }
    }
}

fn select_candidates(
    candidates: Vec<Candidate>,
    options: &NormalizedOptions,
    duration_ms: u64,
    warnings: &mut Warnings,
) -> Vec<Candidate> {
    if options.max_keyframes == 0 {
        return Vec::new();
    }

    let (mut pinned, mut ordinary): (Vec<Candidate>, Vec<Candidate>) = candidates
        .into_iter()
        .partition(|candidate| candidate.pinned);
    pinned.sort_by(by_time);
    ordinary.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then(left.frame.keyframe.at_ms.cmp(&right.frame.keyframe.at_ms))
    });

    let mut selected: Vec<Candidate> = Vec::new();

    for candidate in pinned {
        let near = selected.iter().position(|chosen| {
            chosen.pinned
                && chosen
                    .frame
                    .keyframe
                    .at_ms
                    .abs_diff(candidate.frame.keyframe.at_ms)
                    < options.min_gap_ms
                && chosen.reason == candidate.reason
                && chosen.target_id == candidate.target_id
        });
        if let Some(index) = near {
            let existing = selected.remove(index);
            selected.insert(index, merge_candidates(existing, candidate));
        } else {
            selected.push(candidate);
        }
    }

    if selected.len() > options.max_keyframes {
        warnings.add(format!(
            "More marks and annotations were captured than the {}-keyframe budget; the lowest-scored ones were dropped.",
            options.max_keyframes
        ));
        selected.sort_by(|left, right| {
            right
                .score
                .cmp(&left.score)
                .then(left.frame.keyframe.at_ms.cmp(&right.frame.keyframe.at_ms))
        });
        selected.truncate(options.max_keyframes);
        selected.sort_by(by_time);
    }

    for candidate in &ordinary {
        if selected.len() >= options.max_keyframes {
            break;
        }
        if selected.iter().any(|chosen| {
            chosen
                .frame
                .keyframe
                .at_ms
                .abs_diff(candidate.frame.keyframe.at_ms)
                < options.min_gap_ms
        }) {
            continue;
        }
        selected.push(candidate.clone());
    }

    if options.coverage && selected.len() < options.max_keyframes {
        add_coverage_frames(&mut selected, &ordinary, options, duration_ms);
    }

    selected.sort_by(by_time);
    selected
}

fn clamp(value: f64, min: f64, max: f64) -> f64 {
    value.min(max).max(min)
}

/// Grow a tight crop around its center so a single small element still carries
/// enough context to be readable in the bundle.
fn expand_span(start: f64, end: f64, minimum: f64, maximum: f64) -> (f64, f64) {
    if end - start >= minimum {
        return (start, end);
    }
    let center = (start + end) / 2.0;
    let mut start = center - minimum / 2.0;
    let mut end = center + minimum / 2.0;
    if start < 0.0 {
        end -= start;
        start = 0.0;
    }
    if end > maximum {
        start -= end - maximum;
        end = maximum;
    }
    (start.max(0.0), end.min(maximum))
}

fn crop_for(
    candidate: &Candidate,
    manifest: &HighliteManifest,
    viewport: ViewportRect,
    padding_px: f64,
) -> Option<NormalizedRect> {
    let (width, height) = (viewport.width, viewport.height);
    if !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0 {
        return None;
    }

    let annotation = candidate.annotation_id.as_ref().and_then(|id| {
        manifest
            .annotations
            .iter()
            .find(|annotation| &annotation.id == id)
    });
    let target = candidate
        .target_id
        .as_ref()
        .and_then(|id| manifest.targets.iter().find(|target| &target.id == id));

    let mut rect: Option<ViewportRect> = None;
    if let Some(annotation) = annotation
        && annotation.coordinate_space == crate::model::CoordinateSpace::ViewportNormalized
        && !annotation.points.is_empty()
    {
        let xs: Vec<f64> = annotation
            .points
            .iter()
            .map(|point| point.x * width)
            .collect();
        let ys: Vec<f64> = annotation
            .points
            .iter()
            .map(|point| point.y * height)
            .collect();
        let min_x = xs.iter().copied().fold(f64::INFINITY, f64::min);
        let min_y = ys.iter().copied().fold(f64::INFINITY, f64::min);
        let max_x = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let max_y = ys.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        rect = Some(ViewportRect {
            x: min_x,
            y: min_y,
            width: max_x - min_x,
            height: max_y - min_y,
        });
    }
    if rect.is_none_or(|rect| rect.width < 24.0 || rect.height < 24.0)
        && let Some(target) = target
    {
        rect = Some(target.rect);
    }

    let rect = rect?;
    if rect.width <= 0.0 || rect.height <= 0.0 {
        return None;
    }

    let x0 = clamp(rect.x - padding_px, 0.0, width);
    let y0 = clamp(rect.y - padding_px, 0.0, height);
    let x1 = clamp(rect.x + rect.width + padding_px, 0.0, width);
    let y1 = clamp(rect.y + rect.height + padding_px, 0.0, height);
    let (x0, x1) = expand_span(x0, x1, width * MIN_CROP_FRACTION, width);
    let (y0, y1) = expand_span(y0, y1, height * MIN_CROP_FRACTION, height);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }

    let crop = NormalizedRect {
        x: x0 / width,
        y: y0 / height,
        width: (x1 - x0) / width,
        height: (y1 - y0) / height,
    };
    if crop.width >= 0.92 && crop.height >= 0.92 {
        None
    } else {
        Some(crop)
    }
}

fn collect_docs_refs(
    manifest: &HighliteManifest,
    resolver: Option<&dyn DocsResolver>,
) -> Vec<DocsRef> {
    let mut refs: Vec<DocsRef> = Vec::new();

    for target in &manifest.targets {
        let metadata = target.metadata.as_ref();
        let key = metadata.and_then(|metadata| {
            DOCS_METADATA_KEYS.iter().copied().find(|key| {
                metadata
                    .get(*key)
                    .and_then(Value::as_str)
                    .is_some_and(|value| !value.trim().is_empty())
            })
        });
        let docs_id = key
            .and_then(|key| metadata.and_then(|metadata| metadata.get(key)))
            .and_then(Value::as_str)
            .map(|value| value.trim().to_owned())
            .or_else(|| target.id.strip_prefix("context:").map(str::to_owned));
        let resolved = resolver.and_then(|resolver| resolver.resolve(target, manifest));
        if docs_id.is_none() && resolved.is_none() {
            continue;
        }

        let docs_id = resolved
            .as_ref()
            .map(|resolved| resolved.docs_id.clone())
            .or(docs_id)
            .unwrap_or_else(|| target.id.clone());
        let label = resolved
            .as_ref()
            .and_then(|resolved| resolved.label.clone())
            .or_else(|| target.label.clone())
            .or_else(|| target.text_excerpt.clone());
        let url = resolved.and_then(|resolved| resolved.url);
        let metadata = target
            .metadata
            .clone()
            .filter(|metadata| !metadata.is_empty());

        let reference = DocsRef {
            target_id: target.id.clone(),
            docs_id,
            label,
            url,
            metadata,
        };
        if !refs
            .iter()
            .any(|existing| existing.target_id == reference.target_id)
        {
            refs.push(reference);
        }
    }

    refs
}

fn build_event_alignment(
    manifest: &HighliteManifest,
    keyframes: &[CompiledKeyframe],
) -> Vec<EventAlignment> {
    let segments: Vec<(String, u64, u64)> = manifest
        .transcript
        .iter()
        .enumerate()
        .map(|(index, segment)| {
            (
                segment
                    .id
                    .clone()
                    .unwrap_or_else(|| format!("segment-{}", index + 1)),
                segment.start_ms,
                segment.end_ms,
            )
        })
        .collect();

    manifest
        .timeline
        .iter()
        .map(|event| {
            let nearest = keyframes
                .iter()
                .map(|keyframe| (keyframe, keyframe.at_ms.abs_diff(event.at_ms)))
                .min_by_key(|(_, distance)| *distance);
            let nearby: Vec<&CompiledKeyframe> = match nearest {
                Some((keyframe, distance)) if distance <= 2_000 => vec![keyframe],
                _ => Vec::new(),
            };
            let overlapping: Vec<&(String, u64, u64)> = segments
                .iter()
                .filter(|(_, start_ms, end_ms)| {
                    *start_ms <= event.at_ms.saturating_add(1_500)
                        && *end_ms >= event.at_ms.saturating_sub(1_500)
                })
                .collect();
            let segment_ids = if nearby.is_empty() {
                unique_strings(overlapping.iter().map(|(id, _, _)| id.clone()))
            } else {
                unique_strings(
                    nearby
                        .iter()
                        .flat_map(|keyframe| keyframe.transcript_segment_ids.clone()),
                )
            };
            let confidence = match nearest {
                None => {
                    if segment_ids.is_empty() {
                        0.0
                    } else {
                        0.4
                    }
                }
                Some((_, distance)) if distance <= 500 => 1.0,
                Some((_, distance)) if distance <= 2_000 => 0.7,
                Some(_) if !segment_ids.is_empty() => 0.4,
                Some(_) => 0.0,
            };

            EventAlignment {
                event_id: event.id.clone(),
                kind: event.kind,
                at_ms: event.at_ms,
                segment_ids,
                keyframe_ids: nearby.iter().map(|keyframe| keyframe.id.clone()).collect(),
                confidence,
            }
        })
        .collect()
}

fn to_core_keyframe(keyframe: &CompiledKeyframe) -> Keyframe {
    Keyframe {
        id: keyframe.id.clone(),
        at_ms: keyframe.at_ms,
        image_path: keyframe.image_path.clone(),
        target_ids: keyframe.target_ids.clone(),
        annotation_ids: keyframe.annotation_ids.clone(),
        transcript_segment_ids: keyframe.transcript_segment_ids.clone(),
        reason: keyframe.reason,
    }
}

/// Compiles a raw capture into a selected, transcript-aligned bundle. Pure: no I/O,
/// no model calls, no platform APIs.
pub fn compile_capture(input: &CompileInput) -> CompiledBundle {
    compile_capture_with(input, None)
}

/// Same as [`compile_capture`], with an optional documentation resolver.
pub fn compile_capture_with(
    input: &CompileInput,
    resolver: Option<&dyn DocsResolver>,
) -> CompiledBundle {
    let manifest = &input.manifest;
    let options = normalize_options(input.options.as_ref(), manifest);
    let mut warnings = Warnings::default();
    for warning in &manifest.capture_warnings {
        if !warning.trim().is_empty() {
            warnings.add(warning.clone());
        }
    }

    let viewport = input.viewport.or(manifest.viewport);
    let mut frames: Vec<FrameCandidate> = match &input.frames {
        Some(frames) => frames.iter().filter_map(normalize_frame).collect(),
        None => manifest
            .keyframes
            .iter()
            .cloned()
            .map(|keyframe| FrameCandidate {
                keyframe,
                width: None,
                height: None,
                signature: None,
            })
            .filter_map(|frame| normalize_frame(&frame))
            .collect(),
    };
    frames.sort_by_key(|frame| frame.keyframe.at_ms);

    if frames.is_empty() {
        warnings.add("No frame candidates were supplied, so the bundle has no visual evidence.");
    }

    let cues = if options.speech_cues {
        detect_speech_cues(manifest)
    } else {
        Vec::new()
    };
    if options.speech_cues {
        for cue in cues.iter().filter(|cue| cue.strong) {
            let nearby = frames
                .iter()
                .any(|frame| frame.keyframe.at_ms.abs_diff(cue.at_ms) <= options.cue_window_ms);
            if !nearby {
                warnings.add(format!(
                    "Speech cue “{}” at {} had no captured frame nearby, so it could not become a keyframe.",
                    cue.word,
                    format_clock(cue.at_ms)
                ));
            }
        }
    }
    let candidates = dedupe_candidates(
        build_candidates(manifest, &frames, &cues, &options),
        options.min_gap_ms,
    );
    let selected = select_candidates(candidates, &options, manifest.duration_ms, &mut warnings);
    let alignment_targets: Vec<AlignmentTarget> = selected
        .iter()
        .map(|candidate| AlignmentTarget {
            at_ms: candidate.frame.keyframe.at_ms,
            anchor_ms: candidate.anchor_ms,
        })
        .collect();
    let aligned = align_transcript(
        &alignment_targets,
        &manifest.transcript,
        options.clause_gap_ms,
    );

    let keyframes: Vec<CompiledKeyframe> = selected
        .iter()
        .enumerate()
        .map(|(index, candidate)| {
            let alignment = aligned.get(index).cloned().unwrap_or_default();
            let crop = viewport.filter(|_| options.crop).and_then(|viewport| {
                crop_for(candidate, manifest, viewport, options.crop_padding_px)
            });
            CompiledKeyframe {
                id: candidate.frame.keyframe.id.clone(),
                index: index + 1,
                at_ms: candidate.frame.keyframe.at_ms,
                image_path: candidate.frame.keyframe.image_path.clone(),
                reason: candidate.reason,
                target_ids: candidate.frame.keyframe.target_ids.clone(),
                annotation_ids: candidate.frame.keyframe.annotation_ids.clone(),
                transcript_segment_ids: alignment.transcript_segment_ids,
                said: alignment.said,
                cue: candidate.cue.as_ref().map(|cue| cue.word.clone()),
                score: candidate.score,
                score_reasons: candidate.score_reasons.clone(),
                crop,
            }
        })
        .collect();

    let docs_refs = collect_docs_refs(manifest, resolver);
    let warnings = warnings.into_vec();
    let transcript_text = manifest
        .transcript
        .iter()
        .map(|segment| segment.text.trim())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let analysis = CaptureAnalysis {
        schema_version: COMPILER_SCHEMA_VERSION.to_owned(),
        session_id: manifest.session_id.clone(),
        duration_ms: manifest.duration_ms,
        page: manifest.page.clone(),
        transcript: TranscriptAnalysis {
            segments: manifest.transcript.clone(),
            text: transcript_text,
            has_word_timings: manifest
                .transcript
                .iter()
                .any(|segment| !segment.word_timings.is_empty()),
        },
        alignment: build_event_alignment(manifest, &keyframes),
        keyframes: keyframes.clone(),
        targets: manifest.targets.clone(),
        annotations: manifest.annotations.clone(),
        docs_refs: docs_refs.clone(),
        warnings: warnings.clone(),
    };

    let mut compiled_manifest = manifest.clone();
    compiled_manifest.viewport = viewport;
    compiled_manifest.keyframes = keyframes.iter().map(to_core_keyframe).collect();
    compiled_manifest.capture_warnings = warnings.clone();

    let summary = build_handoff_summary(
        manifest,
        &keyframes,
        &manifest.transcript,
        &docs_refs,
        &warnings,
    );

    CompiledBundle {
        schema_version: COMPILER_SCHEMA_VERSION.to_owned(),
        manifest: compiled_manifest,
        viewport,
        keyframes,
        analysis,
        summary,
        warnings,
        provenance: CompileProvenance {
            compiler: CompilerInfo {
                name: COMPILER_NAME.to_owned(),
                version: COMPILER_VERSION.to_owned(),
            },
            compiled_at: options.compiled_at.clone(),
            options: EffectiveOptions {
                max_keyframes: options.max_keyframes,
                min_gap_ms: options.min_gap_ms,
                clause_gap_ms: options.clause_gap_ms,
                crop: options.crop,
                coverage: options.coverage,
                speech_cues: options.speech_cues,
                cue_window_ms: options.cue_window_ms,
            },
        },
    }
}

/// Resolves docs refs without a custom resolver.
pub fn docs_refs(manifest: &HighliteManifest) -> Vec<DocsRef> {
    collect_docs_refs(manifest, None)
}
