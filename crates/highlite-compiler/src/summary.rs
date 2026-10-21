use std::fmt::Write as _;

use serde_json::Value;

use crate::model::{
    Annotation, CompiledKeyframe, DocsRef, HighliteManifest, Target, TimelineEvent, TimelineKind,
    TranscriptSegment,
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

fn describe_frame(frame: &CompiledKeyframe, manifest: &HighliteManifest) -> String {
    let target: Option<&Target> = frame
        .target_ids
        .iter()
        .find_map(|id| manifest.targets.iter().find(|target| &target.id == id));
    let annotation: Option<&Annotation> = frame.annotation_ids.iter().find_map(|id| {
        manifest
            .annotations
            .iter()
            .find(|annotation| &annotation.id == id)
    });
    let event = nearest_event(&manifest.timeline, frame.at_ms, 1_500);
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

pub fn build_handoff_summary(
    manifest: &HighliteManifest,
    keyframes: &[CompiledKeyframe],
    transcript: &[TranscriptSegment],
    docs_refs: &[DocsRef],
    warnings: &[String],
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

    if keyframes.is_empty() {
        out.push('\n');
        out.push_str("Visual evidence: unavailable. No keyframes were selected.\n");
        if !transcript.is_empty() {
            out.push('\n');
            out.push_str("## Narration\n\n");
            for segment in transcript {
                let _ = writeln!(
                    out,
                    "- {} — {}",
                    format_clock(segment.start_ms),
                    quote(&segment.text)
                );
            }
        }
    } else {
        for frame in keyframes {
            let action = describe_frame(frame, manifest);
            let said = frame
                .said
                .as_ref()
                .map(|said| format!(" {}", quote(said)))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "- #{} ({}){}{}",
                frame.index,
                format_clock(frame.at_ms),
                if action.is_empty() {
                    String::new()
                } else {
                    format!(" [{action}]")
                },
                said
            );
            if let Some(docs) = docs_for_frame(frame, docs_refs) {
                let _ = match &docs.url {
                    Some(url) => writeln!(out, "  docs: {} ({url})", docs.docs_id),
                    None => writeln!(out, "  docs: {}", docs.docs_id),
                };
            }
        }
    }

    if transcript.is_empty() {
        out.push('\n');
        out.push_str("Narration: no transcript was supplied.\n");
    }

    if !warnings.is_empty() {
        out.push('\n');
        out.push_str("## Capture limitations\n\n");
        for warning in warnings {
            let _ = writeln!(out, "- {}", plain_text(warning));
        }
    }

    out
}
