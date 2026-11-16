//! Ordered, report-ready action list derived from the timeline.
//!
//! The report is deliberately observational: it repeats only what the capture recorded
//! and never invents expected/actual outcomes. Frame links marked `exact` come from
//! capture-time event references; transcript links remain temporal approximations.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::model::{
    CaptureReport, EventAlignment, FrameMatch, HighliteManifest, REPORT_SCHEMA_VERSION,
    ReportAction, ReportContext, ReportEvidence, ReportField, ReportNarration, ReportSubmit,
    ReportTarget, ReportValue, Target, TimelineEvent, TimelineKind, TranscriptMatch,
};

fn payload_str<'a>(event: &'a TimelineEvent, key: &str) -> Option<&'a str> {
    event.payload.get(key).and_then(Value::as_str)
}

fn payload_bool(event: &TimelineEvent, key: &str) -> Option<bool> {
    event.payload.get(key).and_then(Value::as_bool)
}

fn payload_number(event: &TimelineEvent, key: &str) -> Option<f64> {
    event.payload.get(key).and_then(Value::as_f64)
}

fn payload_strings(event: &TimelineEvent, key: &str) -> Option<Vec<String>> {
    event
        .payload
        .get(key)
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
}

fn quote(value: &str) -> String {
    format!("“{value}”")
}

/// Drop credentials, query strings, and fragments from action URLs before they enter
/// the report.
fn safe_url(href: &str) -> String {
    let (prefix, rest) = if let Some((_, rest)) = href.split_once("://") {
        ("", rest)
    } else if let Some(rest) = href.strip_prefix("//") {
        ("//", rest)
    } else {
        return href.split(['?', '#']).next().unwrap_or(href).to_owned();
    };
    let rest = rest.split(['?', '#']).next().unwrap_or(rest);
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, ""),
    };
    // Drop any user-info component so credentials cannot enter the report.
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    if path.is_empty() || path == "/" {
        format!("{prefix}{authority}")
    } else {
        format!("{prefix}{authority}{path}")
    }
}

fn target_for<'a>(manifest: &'a HighliteManifest, id: Option<&str>) -> Option<&'a Target> {
    id.and_then(|id| manifest.targets.iter().find(|target| target.id == id))
}

fn target_label(target: Option<&Target>) -> Option<String> {
    target.and_then(|target| target.label.clone().or_else(|| target.text_excerpt.clone()))
}

fn report_target(target: Option<&Target>) -> Option<ReportTarget> {
    target.map(|target| ReportTarget {
        id: target.id.clone(),
        tag: target.tag.clone(),
        role: target.role.clone(),
        label: target.label.clone().or_else(|| target.text_excerpt.clone()),
        selector: target.selector.clone(),
    })
}

fn field_label(kind: &str) -> &'static str {
    match kind {
        "textarea" => "multiline field",
        "checkbox" => "checkbox",
        "radio" => "radio option",
        _ => "field",
    }
}

fn subject(label: Option<&str>, field_kind: &str) -> String {
    match label {
        Some(label) => format!("{} {}", field_label(field_kind), quote(label)),
        None => field_label(field_kind).to_owned(),
    }
}

fn describe_action(event: &TimelineEvent, target: Option<&Target>) -> String {
    let label = target_label(target);
    match event.kind {
        TimelineKind::Click => {
            let role = target
                .and_then(|target| target.role.as_deref().or(target.tag.as_deref()))
                .unwrap_or("element");
            match label {
                Some(label) => format!("Clicked {role} {}", quote(&label)),
                None => format!("Clicked {role}"),
            }
        }
        TimelineKind::Input => {
            let field_kind = payload_str(event, "fieldKind").unwrap_or("text");
            let subject = subject(label.as_deref(), field_kind);
            if payload_bool(event, "filled") == Some(false) {
                return format!("Cleared {subject}");
            }
            let text = payload_bool(event, "valueCaptured")
                .filter(|captured| *captured)
                .and_then(|_| payload_str(event, "value"));
            match text {
                Some(text) if !text.is_empty() => format!("Entered {} in {subject}", quote(text)),
                _ => format!("Entered text in {subject}"),
            }
        }
        TimelineKind::Change => {
            let field_kind = payload_str(event, "fieldKind").unwrap_or("select");
            if field_kind == "checkbox" || field_kind == "radio" {
                let action = if payload_bool(event, "checked") == Some(true) {
                    "Checked"
                } else {
                    "Unchecked"
                };
                return match label {
                    Some(label) => format!("{action} {}", quote(&label)),
                    None => action.to_owned(),
                };
            }
            let subject = subject(label.as_deref(), field_kind);
            let captured = payload_bool(event, "valueCaptured").unwrap_or(false);
            if captured && let Some(options) = payload_strings(event, "optionLabels") {
                let options: Vec<&str> = options
                    .iter()
                    .map(String::as_str)
                    .filter(|option| !option.is_empty())
                    .collect();
                if options.is_empty() {
                    return format!("Cleared selection in {subject}");
                }
                let quoted = options
                    .iter()
                    .map(|option| quote(option))
                    .collect::<Vec<_>>()
                    .join(", ");
                return format!("Selected {quoted} in {subject}");
            }
            let option = captured
                .then(|| payload_str(event, "optionLabel").or_else(|| payload_str(event, "value")))
                .flatten();
            match option {
                Some(option) if !option.is_empty() => {
                    format!("Selected {} in {subject}", quote(option))
                }
                _ => format!("Changed selection in {subject}"),
            }
        }
        TimelineKind::Submit => {
            let form = match label {
                Some(label) => format!("form {}", quote(&label)),
                None => "form".to_owned(),
            };
            let submitter = payload_str(event, "submitterLabel")
                .map(|label| format!(" via {}", quote(label)))
                .unwrap_or_default();
            format!("Submitted {form}{submitter}")
        }
        TimelineKind::Navigate => event.payload.get("to").and_then(Value::as_str).map_or_else(
            || "Navigated".to_owned(),
            |to| format!("Navigated to {}", safe_url(to)),
        ),
        TimelineKind::Scroll => {
            let x = payload_number(event, "x").unwrap_or(0.0);
            let y = payload_number(event, "y").unwrap_or(0.0);
            format!("Scrolled to x={x}, y={y}")
        }
        TimelineKind::Mark => payload_str(event, "label").map_or_else(
            || "Marked a moment".to_owned(),
            |label| format!("Marked {}", quote(label)),
        ),
        TimelineKind::Annotation => {
            let kind = payload_str(event, "annotationKind").unwrap_or("annotation");
            match label {
                Some(label) => format!("Added {kind} annotation on {}", quote(&label)),
                None => format!("Added {kind} annotation"),
            }
        }
        TimelineKind::Target | TimelineKind::Context => event.kind.as_str().to_owned(),
    }
}

fn evidence_for(alignment: Option<&EventAlignment>) -> ReportEvidence {
    match alignment {
        Some(alignment) => ReportEvidence {
            keyframe_ids: alignment.keyframe_ids.clone(),
            frame_match: alignment.frame_match,
            transcript_segment_ids: alignment.segment_ids.clone(),
            transcript_match: alignment.transcript_match,
            said: None,
            confidence: alignment.confidence,
        },
        None => ReportEvidence {
            keyframe_ids: Vec::new(),
            frame_match: FrameMatch::None,
            transcript_segment_ids: Vec::new(),
            transcript_match: TranscriptMatch::None,
            said: None,
            confidence: 0.0,
        },
    }
}

fn report_value(event: &TimelineEvent, field_kind: Option<&str>) -> Option<ReportValue> {
    let captured = payload_bool(event, "valueCaptured").unwrap_or(false);
    let text = captured
        .then(|| payload_str(event, "value"))
        .flatten()
        .map(str::to_owned);
    let option_label = captured
        .then(|| payload_str(event, "optionLabel"))
        .flatten()
        .map(str::to_owned);
    let option_labels = captured
        .then(|| payload_strings(event, "optionLabels"))
        .flatten();
    let checked = payload_bool(event, "checked");
    let filled = payload_bool(event, "filled");
    if text.is_none()
        && option_label.is_none()
        && option_labels.is_none()
        && checked.is_none()
        && filled.is_none()
        && field_kind.is_none()
    {
        return None;
    }
    (event.kind == TimelineKind::Input || event.kind == TimelineKind::Change).then_some(
        ReportValue {
            captured,
            text,
            option_label,
            option_labels,
            checked,
            filled,
        },
    )
}

fn report_submit(event: &TimelineEvent) -> Option<ReportSubmit> {
    if event.kind != TimelineKind::Submit {
        return None;
    }
    Some(ReportSubmit {
        method: payload_str(event, "method").map(str::to_owned),
        action: payload_str(event, "action").map(safe_url),
        submitter_label: payload_str(event, "submitterLabel").map(str::to_owned),
    })
}

fn is_environment_scope(scope: &str) -> bool {
    scope == "environment" || scope == "app" || scope == "app.version"
}

pub fn build_capture_report(
    manifest: &HighliteManifest,
    keyframes: &[crate::model::CompiledKeyframe],
    alignment: &[EventAlignment],
    warnings: &[String],
) -> CaptureReport {
    let by_event: BTreeMap<&str, &EventAlignment> = alignment
        .iter()
        .map(|alignment| (alignment.event_id.as_str(), alignment))
        .collect();
    let mut environment = Vec::new();
    let mut context = Vec::new();
    let mut actions = Vec::new();

    for event in &manifest.timeline {
        match event.kind {
            TimelineKind::Target => continue,
            TimelineKind::Context => {
                let scope = payload_str(event, "scope").unwrap_or("page").to_owned();
                let value = payload_str(event, "value").unwrap_or_default().to_owned();
                let entry = ReportContext {
                    scope: scope.clone(),
                    value,
                };
                if is_environment_scope(&scope) {
                    environment.push(entry);
                } else {
                    context.push(entry);
                }
                continue;
            }
            _ => {}
        }

        let target = target_for(manifest, event.target_id.as_deref());
        let field_kind = payload_str(event, "fieldKind");
        let field = field_kind.map(|kind| ReportField {
            kind: kind.to_owned(),
            input_type: payload_str(event, "fieldType").map(str::to_owned),
        });
        let mut evidence = evidence_for(by_event.get(event.id.as_str()).copied());
        if let Some(keyframe) = evidence
            .keyframe_ids
            .iter()
            .find_map(|id| keyframes.iter().find(|keyframe| &keyframe.id == id))
        {
            evidence.said = keyframe.said.clone();
        }
        actions.push(ReportAction {
            event_id: event.id.clone(),
            seq: event.seq,
            at_ms: event.at_ms,
            kind: event.kind,
            action: describe_action(event, target),
            target: report_target(target),
            field,
            value: report_value(event, field_kind),
            submit: report_submit(event),
            evidence,
        });
    }

    let narration = manifest
        .transcript
        .iter()
        .enumerate()
        .map(|(index, segment)| ReportNarration {
            id: segment
                .id
                .clone()
                .unwrap_or_else(|| format!("segment-{}", index + 1)),
            start_ms: segment.start_ms,
            end_ms: segment.end_ms,
            text: segment.text.clone(),
        })
        .collect();

    CaptureReport {
        schema_version: REPORT_SCHEMA_VERSION.to_owned(),
        session_id: manifest.session_id.clone(),
        page: manifest.page.clone(),
        viewport: manifest.viewport,
        environment,
        actions,
        narration,
        context,
        notes: vec![
            "Observed actions only: expected and actual outcomes are not inferred.".to_owned(),
            "Frame links marked exact come from capture-time event references; transcript links are temporal approximations.".to_owned(),
            "Field values are included only when the capture explicitly enabled form values and the field passed exclusion rules.".to_owned(),
            "Actions are listed independently of keyframe selection.".to_owned(),
        ],
        limitations: warnings.to_vec(),
    }
}
