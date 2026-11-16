mod common;

use common::{make_manifest, payload, read_fixture, viewport};
use highlite_compiler::{
    CompileInput, CompileOptions, FrameMatch, Keyframe, KeyframeReason, Target, TimelineEvent,
    TimelineKind, ViewportRect, compile_capture,
};
use serde_json::{Value, json};

fn compile_form_fixture() -> highlite_compiler::CompiledBundle {
    let input: CompileInput =
        serde_json::from_value(read_fixture("form-capture.json")).expect("form compile input");
    compile_capture(&input)
}

#[test]
fn matches_the_golden_action_report() {
    let compiled = compile_form_fixture();
    let mut actual = serde_json::to_value(&compiled.report).expect("report JSON");
    let mut expected = read_fixture("expected-report.json");
    common::normalize_numbers(&mut actual);
    common::normalize_numbers(&mut expected);
    assert_eq!(actual, expected);
}

#[test]
fn lists_ordered_user_actions_without_internal_target_rows() {
    let report = compile_form_fixture().report;

    assert_eq!(
        report
            .actions
            .iter()
            .map(|action| action.event_id.as_str())
            .collect::<Vec<_>>(),
        [
            "event-click",
            "event-input",
            "event-select",
            "event-multi",
            "event-check",
            "event-submit",
        ]
    );
    assert!(
        report
            .actions
            .iter()
            .all(|action| action.kind != TimelineKind::Target)
    );
    assert_eq!(report.environment.len(), 2);
    assert_eq!(report.environment[1].scope, "app.version");
    assert!(report.context.is_empty());
}

#[test]
fn keyframe_budget_does_not_truncate_the_action_list() {
    let mut input: CompileInput =
        serde_json::from_value(read_fixture("form-capture.json")).expect("form compile input");
    input.options = Some(CompileOptions {
        max_keyframes: Some(0),
        ..CompileOptions::default()
    });

    let compiled = compile_capture(&input);

    assert!(compiled.keyframes.is_empty());
    assert_eq!(compiled.report.actions.len(), 6);
    assert!(compiled.summary.contains("## Actions"));
    assert!(
        compiled
            .summary
            .contains("Entered “retention” in field “Search metrics”")
    );
    assert!(compiled.summary.contains("Visual evidence: unavailable"));
}

#[test]
fn carries_field_structure_and_only_explicit_values() {
    let report = compile_form_fixture().report;
    let action = |id: &str| {
        report
            .actions
            .iter()
            .find(|action| action.event_id == id)
            .unwrap()
    };

    let input = action("event-input");
    assert_eq!(input.field.as_ref().unwrap().kind, "text");
    assert_eq!(
        input.field.as_ref().unwrap().input_type.as_deref(),
        Some("search")
    );
    assert_eq!(
        input.value.as_ref().unwrap().text.as_deref(),
        Some("retention")
    );
    assert!(input.value.as_ref().unwrap().captured);

    let select = action("event-select");
    assert_eq!(
        select.value.as_ref().unwrap().option_label.as_deref(),
        Some("Last 30 days")
    );
    assert_eq!(
        select.action,
        "Selected “Last 30 days” in field “Date range”"
    );

    let multi = action("event-multi");
    assert_eq!(
        multi.action,
        "Selected “Retention”, “Churn” in field “Categories”"
    );
    assert_eq!(
        multi.value.as_ref().unwrap().option_labels.as_deref(),
        Some(["Retention".to_owned(), "Churn".to_owned()].as_slice())
    );

    let checkbox = action("event-check");
    assert!(!checkbox.value.as_ref().unwrap().captured);
    assert_eq!(checkbox.value.as_ref().unwrap().checked, Some(true));
    assert_eq!(checkbox.action, "Checked “Include archived”");

    let submit = action("event-submit");
    assert_eq!(
        submit.action,
        "Submitted form “Search filters” via “Apply filters”"
    );
    assert_eq!(
        submit.submit.as_ref().unwrap().action.as_deref(),
        Some("app.example.com/search"),
        "submit URLs must not keep query strings"
    );
}

#[test]
fn distinguishes_exact_event_links_from_temporal_frame_guesses() {
    let report = compile_form_fixture().report;
    let evidence = |id: &str| {
        report
            .actions
            .iter()
            .find(|action| action.event_id == id)
            .unwrap()
            .evidence
            .clone()
    };

    let click = evidence("event-click");
    assert_eq!(click.frame_match, FrameMatch::Exact);
    assert_eq!(click.keyframe_ids, vec!["f-click".to_owned()]);

    let input = evidence("event-input");
    assert_eq!(input.frame_match, FrameMatch::Temporal);
    assert_eq!(input.keyframe_ids, vec!["f-click".to_owned()]);

    let submit = evidence("event-submit");
    assert_eq!(submit.frame_match, FrameMatch::Exact);
    assert_eq!(submit.keyframe_ids, vec!["f-submit".to_owned()]);

    let summary = compile_form_fixture().summary;
    assert!(summary.contains("frame #1 (exact)"));
    assert!(summary.contains("frame #1 (temporal)"));
}

#[test]
fn does_not_expose_option_labels_without_capture_permission() {
    let mut input: CompileInput =
        serde_json::from_value(read_fixture("form-capture.json")).expect("form compile input");
    let event = input
        .manifest
        .timeline
        .iter_mut()
        .find(|event| event.id == "event-multi")
        .expect("multi event");
    event
        .payload
        .insert("valueCaptured".to_owned(), Value::Bool(false));
    event
        .payload
        .insert("optionLabels".to_owned(), json!(["Secret", "Private"]));
    event
        .payload
        .insert("value".to_owned(), Value::String("secret-value".to_owned()));

    let compiled = compile_capture(&input);
    let action = compiled
        .report
        .actions
        .iter()
        .find(|action| action.event_id == "event-multi")
        .expect("multi action");

    assert_eq!(action.action, "Changed selection in field “Categories”");
    let value = action.value.as_ref().expect("field value state");
    assert!(!value.captured);
    assert!(value.option_labels.is_none());
    assert!(value.option_label.is_none());
    assert!(value.text.is_none());
    assert!(
        !serde_json::to_string(&compiled.report)
            .unwrap()
            .contains("Secret")
    );
}

#[test]
fn strips_credentials_query_and_fragment_from_submit_actions() {
    let mut input: CompileInput =
        serde_json::from_value(read_fixture("form-capture.json")).expect("form compile input");
    let event = input
        .manifest
        .timeline
        .iter_mut()
        .find(|event| event.id == "event-submit")
        .expect("submit event");
    event.payload.insert(
        "action".to_owned(),
        Value::String(
            "https://user:secret@app.example.com/search?token=must-not-leak#result".to_owned(),
        ),
    );

    let compiled = compile_capture(&input);
    let action = compiled
        .report
        .actions
        .iter()
        .find(|action| action.event_id == "event-submit")
        .expect("submit action");
    assert_eq!(
        action.submit.as_ref().unwrap().action.as_deref(),
        Some("app.example.com/search")
    );
    let json = serde_json::to_string(&compiled.report).unwrap();
    assert!(!json.contains("secret"));
    assert!(!json.contains("must-not-leak"));
    assert!(!json.contains("#result"));
}

#[test]
fn report_notes_do_not_invent_outcomes() {
    let report = compile_form_fixture().report;
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("expected and actual outcomes are not inferred"))
    );
    let json = serde_json::to_string(&report).unwrap();
    assert!(!json.contains("expectedOutcome"));
    assert!(!json.contains("actualOutcome"));
}

#[test]
fn unions_event_links_when_nearby_frames_merge() {
    let mut manifest = make_manifest();
    manifest.transcript.clear();
    manifest.annotations.clear();
    manifest.targets = vec![Target {
        id: "t1".to_owned(),
        tag: Some("input".to_owned()),
        role: Some("textbox".to_owned()),
        label: Some("Search metrics".to_owned()),
        text_excerpt: None,
        selector: Some("#metric-search".to_owned()),
        rect: ViewportRect {
            x: 10.0,
            y: 10.0,
            width: 100.0,
            height: 30.0,
        },
        page_url: "https://app.example.com/search".to_owned(),
        metadata: None,
    }];
    manifest.timeline = vec![
        TimelineEvent {
            id: "event-a".to_owned(),
            seq: 0,
            at_ms: 1_000,
            kind: TimelineKind::Input,
            target_id: Some("t1".to_owned()),
            payload: payload(&[
                ("fieldKind", Value::String("text".to_owned())),
                ("fieldType", Value::String("search".to_owned())),
                ("valueCaptured", Value::Bool(false)),
            ]),
        },
        TimelineEvent {
            id: "event-b".to_owned(),
            seq: 1,
            at_ms: 1_100,
            kind: TimelineKind::Change,
            target_id: Some("t1".to_owned()),
            payload: payload(&[
                ("fieldKind", Value::String("select".to_owned())),
                ("valueCaptured", Value::Bool(false)),
            ]),
        },
    ];
    manifest.keyframes = vec![
        Keyframe {
            id: "k1".to_owned(),
            at_ms: 1_000,
            image_path: "frames/k1.png".to_owned(),
            target_ids: vec!["t1".to_owned()],
            annotation_ids: Vec::new(),
            transcript_segment_ids: Vec::new(),
            reason: KeyframeReason::Interaction,
            event_ids: vec!["event-a".to_owned()],
        },
        Keyframe {
            id: "k2".to_owned(),
            at_ms: 1_100,
            image_path: "frames/k2.png".to_owned(),
            target_ids: vec!["t1".to_owned()],
            annotation_ids: Vec::new(),
            transcript_segment_ids: Vec::new(),
            reason: KeyframeReason::Interaction,
            event_ids: vec!["event-b".to_owned()],
        },
    ];

    let compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: Some(viewport()),
        options: Some(CompileOptions {
            max_keyframes: Some(4),
            ..CompileOptions::default()
        }),
    });

    assert_eq!(compiled.keyframes.len(), 1);
    assert_eq!(
        compiled.keyframes[0].event_ids,
        vec!["event-a".to_owned(), "event-b".to_owned()]
    );
    for event in ["event-a", "event-b"] {
        let alignment = compiled
            .analysis
            .alignment
            .iter()
            .find(|alignment| alignment.event_id == event)
            .unwrap();
        assert_eq!(alignment.frame_match, FrameMatch::Exact);
        assert_eq!(
            alignment.keyframe_ids,
            vec![compiled.keyframes[0].id.clone()]
        );
    }
}

#[test]
fn accepts_the_legacy_fixture_without_event_links() {
    let input: CompileInput =
        serde_json::from_value(read_fixture("capture.json")).expect("legacy compile input");
    let compiled = compile_capture(&input);

    assert!(
        compiled
            .keyframes
            .iter()
            .all(|keyframe| keyframe.event_ids.is_empty())
    );
    assert_eq!(
        compiled.report.actions.len(),
        compiled
            .manifest
            .timeline
            .iter()
            .filter(|event| {
                event.kind != TimelineKind::Target && event.kind != TimelineKind::Context
            })
            .count()
    );
    assert!(
        compiled
            .report
            .actions
            .iter()
            .all(|action| action.evidence.frame_match != FrameMatch::Exact)
    );
}
