#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use highlite_compiler::{
    Annotation, AnnotationKind, Artifacts, CoordinateSpace, HighliteManifest, Keyframe,
    KeyframeReason, Page, Point, Target, TimelineEvent, TimelineKind, TranscriptSegment,
    ViewportRect, WordTiming,
};
use serde_json::Value;

pub fn viewport() -> ViewportRect {
    ViewportRect {
        x: 0.0,
        y: 0.0,
        width: 1_000.0,
        height: 800.0,
    }
}

pub fn payload(entries: &[(&str, Value)]) -> BTreeMap<String, Value> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_owned(), value.clone()))
        .collect()
}

pub fn words(text: &str, start_ms: u64, end_ms: u64) -> Vec<WordTiming> {
    let tokens: Vec<&str> = text.split_whitespace().collect();
    let step = (end_ms - start_ms) as f64 / tokens.len() as f64;
    tokens
        .iter()
        .enumerate()
        .map(|(index, token)| WordTiming {
            start_ms: start_ms + (index as f64 * step).round() as u64,
            end_ms: start_ms + ((index + 1) as f64 * step).round() as u64,
            text: (*token).to_owned(),
        })
        .collect()
}

pub fn make_manifest() -> HighliteManifest {
    HighliteManifest {
        schema_version: "0.1.0".to_owned(),
        session_id: "session-1".to_owned(),
        created_at: "2026-10-20T12:00:00.000Z".to_owned(),
        page: Page {
            initial_url: "https://app.example.com/analytics".to_owned(),
            title: "Analytics".to_owned(),
        },
        viewport: Some(viewport()),
        duration_ms: 60_000,
        timeline: vec![
            TimelineEvent {
                id: "event-target".to_owned(),
                seq: 0,
                at_ms: 4_000,
                kind: TimelineKind::Target,
                target_id: Some("t1".to_owned()),
                payload: payload(&[("role", Value::String("button".to_owned()))]),
            },
            TimelineEvent {
                id: "event-click".to_owned(),
                seq: 1,
                at_ms: 4_100,
                kind: TimelineKind::Click,
                target_id: Some("t1".to_owned()),
                payload: payload(&[
                    ("button", Value::from(0)),
                    ("x", Value::from(100)),
                    ("y", Value::from(200)),
                ]),
            },
            TimelineEvent {
                id: "event-mark".to_owned(),
                seq: 2,
                at_ms: 12_000,
                kind: TimelineKind::Mark,
                target_id: Some("t2".to_owned()),
                payload: payload(&[("label", Value::String("Retention dropped".to_owned()))]),
            },
            TimelineEvent {
                id: "event-annotation".to_owned(),
                seq: 3,
                at_ms: 25_000,
                kind: TimelineKind::Annotation,
                target_id: Some("t2".to_owned()),
                payload: payload(&[
                    ("annotationId", Value::String("a1".to_owned())),
                    ("annotationKind", Value::String("circle".to_owned())),
                    ("x", Value::from(300)),
                    ("y", Value::from(400)),
                ]),
            },
            TimelineEvent {
                id: "event-navigate".to_owned(),
                seq: 4,
                at_ms: 40_000,
                kind: TimelineKind::Navigate,
                target_id: None,
                payload: payload(&[
                    (
                        "from",
                        Value::String("https://app.example.com/analytics".to_owned()),
                    ),
                    (
                        "to",
                        Value::String("https://app.example.com/settings".to_owned()),
                    ),
                    ("source", Value::String("pushState".to_owned())),
                ]),
            },
        ],
        targets: vec![
            Target {
                id: "t1".to_owned(),
                tag: Some("button".to_owned()),
                role: Some("button".to_owned()),
                label: Some("Date range".to_owned()),
                text_excerpt: None,
                selector: Some("#date-range".to_owned()),
                rect: ViewportRect {
                    x: 80.0,
                    y: 180.0,
                    width: 160.0,
                    height: 40.0,
                },
                page_url: "https://app.example.com/analytics".to_owned(),
                metadata: Some(payload(&[
                    ("docsId", Value::String("analytics.date-range".to_owned())),
                    ("component", Value::String("DateRange".to_owned())),
                ])),
            },
            Target {
                id: "t2".to_owned(),
                tag: Some("div".to_owned()),
                role: Some("img".to_owned()),
                label: Some("Retention metric".to_owned()),
                text_excerpt: None,
                selector: Some("#retention".to_owned()),
                rect: ViewportRect {
                    x: 200.0,
                    y: 300.0,
                    width: 400.0,
                    height: 200.0,
                },
                page_url: "https://app.example.com/analytics".to_owned(),
                metadata: Some(payload(&[(
                    "docsId",
                    Value::String("analytics.net-retention".to_owned()),
                )])),
            },
        ],
        annotations: vec![Annotation {
            id: "a1".to_owned(),
            at_ms: 25_000,
            kind: AnnotationKind::Circle,
            points: vec![Point { x: 0.2, y: 0.3 }, Point { x: 0.4, y: 0.5 }],
            coordinate_space: CoordinateSpace::ViewportNormalized,
            target_id: Some("t2".to_owned()),
        }],
        transcript: vec![
            TranscriptSegment {
                id: Some("s1".to_owned()),
                start_ms: 3_000,
                end_ms: 6_000,
                text: "This is the filter that breaks the chart.".to_owned(),
                word_timings: words("This is the filter that breaks the chart.", 3_000, 6_000),
            },
            TranscriptSegment {
                id: Some("s2".to_owned()),
                start_ms: 10_000,
                end_ms: 14_000,
                text: "And here the retention number drops.".to_owned(),
                word_timings: words("And here the retention number drops.", 10_000, 14_000),
            },
            TranscriptSegment {
                id: Some("s3".to_owned()),
                start_ms: 23_000,
                end_ms: 27_000,
                text: "I am circling the number that moved.".to_owned(),
                word_timings: words("I am circling the number that moved.", 23_000, 27_000),
            },
        ],
        keyframes: vec![
            Keyframe {
                id: "f1".to_owned(),
                at_ms: 4_100,
                image_path: "frames/f1.png".to_owned(),
                target_ids: vec!["t1".to_owned()],
                annotation_ids: Vec::new(),
                transcript_segment_ids: Vec::new(),
                reason: KeyframeReason::Interaction,
            },
            Keyframe {
                id: "f2".to_owned(),
                at_ms: 4_500,
                image_path: "frames/f2.png".to_owned(),
                target_ids: vec!["t1".to_owned()],
                annotation_ids: Vec::new(),
                transcript_segment_ids: Vec::new(),
                reason: KeyframeReason::Interaction,
            },
            Keyframe {
                id: "f3".to_owned(),
                at_ms: 12_000,
                image_path: "frames/f3.png".to_owned(),
                target_ids: vec!["t2".to_owned()],
                annotation_ids: Vec::new(),
                transcript_segment_ids: Vec::new(),
                reason: KeyframeReason::Mark,
            },
            Keyframe {
                id: "f4".to_owned(),
                at_ms: 25_100,
                image_path: "frames/f4.png".to_owned(),
                target_ids: vec!["t2".to_owned()],
                annotation_ids: vec!["a1".to_owned()],
                transcript_segment_ids: Vec::new(),
                reason: KeyframeReason::Annotation,
            },
            Keyframe {
                id: "f5".to_owned(),
                at_ms: 40_400,
                image_path: "frames/f5.png".to_owned(),
                target_ids: Vec::new(),
                annotation_ids: Vec::new(),
                transcript_segment_ids: Vec::new(),
                reason: KeyframeReason::Interaction,
            },
        ],
        artifacts: Artifacts::default(),
        audio_offset_ms: None,
        capture_warnings: Vec::new(),
    }
}

pub fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures")
}

pub fn read_fixture(name: &str) -> Value {
    let path = fixtures_dir().join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("could not read {}: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("could not parse {}: {error}", path.display()))
}

/// JSON numbers are compared as f64 so `1` and `1.0` are equivalent.
pub fn normalize_numbers(value: &mut Value) {
    match value {
        Value::Number(number) => {
            if let Some(number) = number.as_f64().and_then(serde_json::Number::from_f64) {
                *value = Value::Number(number);
            }
        }
        Value::Array(values) => values.iter_mut().for_each(normalize_numbers),
        Value::Object(values) => values.values_mut().for_each(normalize_numbers),
        _ => {}
    }
}
