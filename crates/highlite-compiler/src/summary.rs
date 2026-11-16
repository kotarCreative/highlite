use std::fmt::Write as _;

use serde_json::Value;

use crate::model::{
    Annotation, CaptureReport, CompiledKeyframe, DocsRef, FrameMatch, HighliteManifest,
    ReportAction, Target, TimelineEvent, TimelineKind, TranscriptSegment,
};

fn format_clock(ms: u64) -> String {
    let total_seconds = ms / 1_000;
    format!("{}:{:02}", total_seconds / 60, total_seconds % 60)
}

fn plain_text(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn quote(value: &str) -> String {
    format!("“{}”", plain_text(value))
}

fn safe_url(href: &str) -> String {
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
        href.split_once(':')
            .map(|(_, rest)| rest.to_owned())
            .unwrap_or_else(|| href.to_owned())
    }
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

fn event_for_frame<'a>(
    frame: &CompiledKeyframe,
    manifest: &'a HighliteManifest,
) -> Option<&'a TimelineEvent> {
    frame
        .event_ids
        .iter()
        .find_map(|id| manifest.timeline.iter().find(|event| &event.id == id))
        .or_else(|| nearest_event(&manifest.timeline, frame.at_ms, 1_500))
}

fn describe_frame(frame: &CompiledKeyframe, manifest: &HighliteManifest) -> String {
    let target: Option<&Target> = frame
        .target_ids
        .iter()
        .find_map(|id| manifest.targets.iter().find(|target| &target.id == id));
    let annotation: Option<&Annotation> = frame
        .annotation_ids
        .iter()
        .filter_map(|id| {
            manifest
                .annotations
                .iter()
                .find(|annotation| &annotation.id == id)
        })
        .min_by_key(|annotation| annotation.at_ms.abs_diff(frame.at_ms));
    let event = event_for_frame(frame, manifest);
    let label =
        target.and_then(|target| target.label.clone().or_else(|| target.text_excerpt.clone()));

    match frame.reason {
        crate::model::KeyframeReason::Mark => {
            let mark_label = event
                .filter(|event| event.kind == TimelineKind::Mark)
                .and_then(|event| event.payload.get("label"))
                .and_then(Value::as_str)
                .map(str::to_owned);
            match label.or(mark_label) {
                Some(text) => format!("marked {}", quote(&text)),
                None => "marked".to_owned(),
            }
        }
        crate::model::KeyframeReason::Annotation => {
            let kind = annotation.map_or("mark", |annotation| annotation.kind.as_str());
            match label {
                Some(text) => format!("annotated {kind} on {}", quote(&text)),
                None => format!("annotated {kind}"),
            }
        }
        crate::model::KeyframeReason::VisualChange => "screen changed".to_owned(),
        crate::model::KeyframeReason::SpeechCue => "spoke".to_owned(),
        crate::model::KeyframeReason::Interaction => match event.map(|event| event.kind) {
            Some(TimelineKind::Navigate) => {
                let to = event
                    .and_then(|event| event.payload.get("to"))
                    .and_then(Value::as_str);
                match to {
                    Some(to) => format!("navigated to {to}"),
                    None => "navigated".to_owned(),
                }
            }
            Some(TimelineKind::Scroll) => "scrolled".to_owned(),
            Some(TimelineKind::Click) => {
                let prefix = target
                    .and_then(|target| target.role.as_ref())
                    .map_or_else(|| "clicked".to_owned(), |role| format!("clicked {role}"));
                match label {
                    Some(text) => format!("{prefix} {}", quote(&text)),
                    None => prefix,
                }
            }
            Some(TimelineKind::Input) => match label {
                Some(text) => format!("entered text in {}", quote(&text)),
                None => "entered text".to_owned(),
            },
            Some(TimelineKind::Change) => match label {
                Some(text) => format!("changed form field {}", quote(&text)),
                None => "changed a form field".to_owned(),
            },
            Some(TimelineKind::Submit) => match label {
                Some(text) => format!("submitted form {}", quote(&text)),
                None => "submitted a form".to_owned(),
            },
            _ => match label {
                Some(text) => format!("interacted with {}", quote(&text)),
                None => "interacted".to_owned(),
            },
        },
    }
}

fn docs_for_frame<'a>(frame: &CompiledKeyframe, docs_refs: &'a [DocsRef]) -> Option<&'a DocsRef> {
    frame.target_ids.iter().find_map(|target_id| {
        docs_refs
            .iter()
            .find(|reference| &reference.target_id == target_id)
    })
}

fn frame_reference(action: &ReportAction, keyframes: &[CompiledKeyframe]) -> String {
    if action.evidence.keyframe_ids.is_empty() {
        return String::new();
    }
    let indexes: Vec<String> = action
        .evidence
        .keyframe_ids
        .iter()
        .filter_map(|id| {
            keyframes
                .iter()
                .find(|keyframe| &keyframe.id == id)
                .map(|keyframe| format!("#{}", keyframe.index))
        })
        .collect();
    if indexes.is_empty() {
        return String::new();
    }
    let noun = if indexes.len() == 1 {
        "frame"
    } else {
        "frames"
    };
    let match_note = match action.evidence.frame_match {
        FrameMatch::Exact => "exact",
        FrameMatch::Temporal => "temporal",
        FrameMatch::None => "unlinked",
    };
    format!(" · {noun} {} ({match_note})", indexes.join(", "))
}

fn environment_line(report: &CaptureReport) -> Option<String> {
    let values: Vec<String> = report
        .environment
        .iter()
        .filter_map(|entry| {
            let value = plain_text(&entry.value);
            if value.is_empty() {
                return None;
            }
            Some(if entry.scope == "environment" {
                value
            } else {
                format!("{} {value}", entry.scope)
            })
        })
        .collect();
    (!values.is_empty()).then(|| values.join(" · "))
}

pub fn build_handoff_summary(
    manifest: &HighliteManifest,
    keyframes: &[CompiledKeyframe],
    transcript: &[TranscriptSegment],
    docs_refs: &[DocsRef],
    warnings: &[String],
    report: &CaptureReport,
) -> String {
    let title = if manifest.page.title.is_empty() {
        String::new()
    } else {
        format!(" {}", quote(&manifest.page.title))
    };
    let mut out = String::new();
    let _ = writeln!(
        out,
        "[highlite {} · {}{} · {}]",
        format_clock(manifest.duration_ms),
        safe_url(&manifest.page.initial_url),
        title,
        manifest.session_id
    );
    let _ = writeln!(out, "Page: {}", manifest.page.initial_url);
    if let Some(environment) = environment_line(report) {
        let _ = writeln!(out, "Environment: {environment}");
    }

    out.push_str("\n## Actions\n\n");
    if report.actions.is_empty() {
        out.push_str("No user-facing actions were captured.\n");
    } else {
        out.push_str(
            "Observed actions in capture order. Frame links marked exact use capture-time references; transcript links are approximate.\n\n",
        );
        for action in &report.actions {
            let said = action
                .evidence
                .said
                .as_ref()
                .map(|said| format!(" · {}", quote(said)))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "- {} — {}{}{}",
                format_clock(action.at_ms),
                plain_text(&action.action),
                frame_reference(action, keyframes),
                said
            );
        }
    }

    out.push_str("\n## Visual evidence\n\n");
    if keyframes.is_empty() {
        out.push_str("Visual evidence: unavailable. No keyframes were selected.\n");
    } else {
        for frame in keyframes {
            let action = describe_frame(frame, manifest);
            let said = frame
                .said
                .as_ref()
                .map(|said| format!(" {}", quote(said)))
                .unwrap_or_default();
            let cue = frame
                .cue
                .as_ref()
                .map(|cue| format!(" · cue {}", quote(cue)))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "- #{} ({}) [{}]{}{}",
                frame.index,
                format_clock(frame.at_ms),
                action,
                said,
                cue
            );
            if let Some(docs) = docs_for_frame(frame, docs_refs) {
                let _ = match &docs.url {
                    Some(url) => writeln!(out, "  docs: {} ({url})", docs.docs_id),
                    None => writeln!(out, "  docs: {}", docs.docs_id),
                };
            }
        }
    }

    out.push_str("\n## Narration\n\n");
    if transcript.is_empty() {
        out.push_str("Narration: no transcript was supplied.\n");
    } else {
        for segment in transcript {
            let _ = writeln!(
                out,
                "- {} — {}",
                format_clock(segment.start_ms),
                quote(&segment.text)
            );
        }
    }

    if !report.context.is_empty() {
        out.push_str("\n## Context\n\n");
        for entry in &report.context {
            let _ = writeln!(out, "- {} — {}", entry.scope, plain_text(&entry.value));
        }
    }

    if !report.notes.is_empty() {
        out.push_str("\n## Report notes\n\n");
        for note in &report.notes {
            let _ = writeln!(out, "- {}", plain_text(note));
        }
    }

    if !warnings.is_empty() {
        out.push_str("\n## Capture limitations\n\n");
        for warning in warnings {
            let _ = writeln!(out, "- {}", plain_text(warning));
        }
    }

    out
}
