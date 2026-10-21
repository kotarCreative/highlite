mod common;

use common::{make_manifest, viewport};
use highlite_compiler::{
    CompileInput, ScrawlEvent, ScrawlExportError, ScrawlExportOptions, ScrawlShape,
    compile_capture, to_scrawl_bundle,
};
use serde_json::Value;

fn compiled() -> highlite_compiler::CompiledBundle {
    compile_capture(&CompileInput {
        manifest: make_manifest(),
        frames: None,
        viewport: Some(viewport()),
        options: None,
    })
}

#[test]
fn maps_the_compiled_bundle_to_the_scrawl_v1_shape() {
    let bundle = to_scrawl_bundle(&compiled(), &ScrawlExportOptions::default()).unwrap();

    assert_eq!(bundle.version, 1);
    assert_eq!(bundle.id, "session-1");
    assert_eq!(bundle.duration_ms, 60_000);
    assert!(bundle.created_at_ms > 0);
    assert_eq!(
        bundle.target.mode,
        highlite_compiler::ScrawlCaptureMode::Window
    );
    assert_eq!(bundle.target.app.as_deref(), Some("Browser"));
    assert_eq!(bundle.target.window_title.as_deref(), Some("Analytics"));
    assert_eq!(bundle.target.frame.width, 1_000.0);
    assert_eq!(bundle.target.frame.height, 800.0);
    assert_eq!(bundle.transcript.source, "highlite");
    assert_eq!(
        bundle.transcript.text,
        "This is the filter that breaks the chart. And here the retention number drops. I am circling the number that moved."
    );
    assert_eq!(bundle.transcript.segments.len(), 3);
    assert!(!bundle.transcript.words.is_empty());
    assert_eq!(
        bundle
            .keyframes
            .iter()
            .map(|keyframe| keyframe.index)
            .collect::<Vec<_>>(),
        [1, 2, 3, 4]
    );
    assert_eq!(
        bundle
            .keyframes
            .iter()
            .map(|keyframe| keyframe.reason)
            .collect::<Vec<_>>(),
        [
            highlite_compiler::ScrawlKeyframeReason::Click,
            highlite_compiler::ScrawlKeyframeReason::Mark,
            highlite_compiler::ScrawlKeyframeReason::Mark,
            highlite_compiler::ScrawlKeyframeReason::Click,
        ]
    );
    assert_eq!(bundle.keyframes[2].index, 3);
    assert_eq!(bundle.keyframes[2].file, "frames/f4.png");
    assert_eq!(bundle.keyframes[2].mark_id.as_deref(), Some("m1"));
    assert_eq!(
        bundle.keyframes[2].said.as_deref(),
        Some("I am circling the number that moved.")
    );
    assert_eq!(bundle.contact_sheet, "contact-sheet.png");
    assert_eq!(bundle.source.as_deref(), Some("browser"));
    assert!(bundle.audio.is_none());
    assert!(bundle.video.is_none());
}

#[test]
fn maps_annotations_to_strokes_and_marks() {
    let bundle = to_scrawl_bundle(&compiled(), &ScrawlExportOptions::default()).unwrap();

    assert_eq!(bundle.strokes.len(), 1);
    assert_eq!(bundle.strokes[0].t0, 25_000);
    assert_eq!(bundle.strokes[0].t1, 25_000);
    assert_eq!(bundle.strokes[0].fw, 1_000.0);
    assert_eq!(bundle.strokes[0].fh, 800.0);
    assert!(!bundle.strokes[0].laser);
    assert_eq!(bundle.strokes[0].pts, [2_000, 3_000, 0, 4_000, 5_000, 0]);

    assert_eq!(bundle.marks.len(), 1);
    assert_eq!(bundle.marks[0].id, "m1");
    assert_eq!(bundle.marks[0].strokes, [0]);
    assert_eq!(bundle.marks[0].box_norm, [0.2, 0.3, 0.4, 0.5]);
    assert_eq!(bundle.marks[0].shape, ScrawlShape::Circle);
    assert_eq!(bundle.marks[0].description, "circle on “Retention metric”");
    assert_eq!(bundle.marks[0].frame.as_deref(), Some("frames/f4.png"));
}

#[test]
fn maps_interactions_and_route_changes() {
    let bundle = to_scrawl_bundle(&compiled(), &ScrawlExportOptions::default()).unwrap();

    match &bundle.events[0] {
        ScrawlEvent::Click {
            t,
            x,
            y,
            button,
            label,
            role,
        } => {
            assert_eq!(*t, 4_100);
            assert!((x - 0.1).abs() < f64::EPSILON);
            assert!((y - 0.25).abs() < f64::EPSILON);
            assert_eq!(button.as_deref(), Some("0"));
            assert_eq!(label.as_deref(), Some("Date range"));
            assert_eq!(role.as_deref(), Some("button"));
        }
        other => panic!("expected a click, got {other:?}"),
    }

    assert!(bundle.events.iter().any(|event| matches!(
        event,
        ScrawlEvent::AppEvent { t: 40_000, label } if label == "navigate to https://app.example.com/settings"
    )));

    let screens = bundle.screens.unwrap();
    assert_eq!(screens.len(), 2);
    assert_eq!(screens[0].t0, 0);
    assert_eq!(screens[0].t1, 40_000);
    assert_eq!(screens[0].name, "app.example.com/analytics");
    assert_eq!(screens[1].t0, 40_000);
    assert_eq!(screens[1].t1, 60_000);
    assert_eq!(screens[1].name, "app.example.com/settings");
}

#[test]
fn serializes_cleanly_and_refuses_to_guess_a_viewport() {
    let bundle = to_scrawl_bundle(&compiled(), &ScrawlExportOptions::default()).unwrap();
    let value: Value = serde_json::to_value(&bundle).unwrap();
    assert!(value.get("note").is_none());
    assert!(value.get("video").is_none());
    assert!(value.get("context").is_none());
    assert_eq!(value["keyframes"][0]["reason"], "click");
    assert_eq!(value["target"]["mode"], "window");

    let mut request = CompileInput {
        manifest: make_manifest(),
        frames: None,
        viewport: None,
        options: None,
    };
    request.manifest.viewport = None;
    let without_viewport = compile_capture(&request);
    assert_eq!(
        to_scrawl_bundle(&without_viewport, &ScrawlExportOptions::default()),
        Err(ScrawlExportError::MissingViewport)
    );
}
