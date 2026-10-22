mod common;

use common::{make_manifest, viewport};
use highlite_compiler::{
    CompileInput, CompileOptions, DocsRef, FrameCandidate, HighliteManifest, Target,
    compile_capture, compile_capture_with, keyframe_budget,
};

fn input() -> CompileInput {
    CompileInput {
        manifest: make_manifest(),
        frames: None,
        viewport: Some(viewport()),
        options: None,
    }
}

#[test]
fn budget_starts_at_six_and_caps_at_twelve() {
    assert_eq!(keyframe_budget(0), 6);
    assert_eq!(keyframe_budget(20_000), 6);
    assert_eq!(keyframe_budget(40_000), 7);
    assert_eq!(keyframe_budget(140_000), 12);
}

#[test]
fn pins_marks_and_annotations_dedupes_and_aligns_narration() {
    let compiled = compile_capture(&input());

    let ids: Vec<&str> = compiled
        .keyframes
        .iter()
        .map(|keyframe| keyframe.id.as_str())
        .collect();
    assert_eq!(ids, ["f1", "f3", "f4", "f5"]);
    assert_eq!(
        compiled
            .keyframes
            .iter()
            .map(|keyframe| keyframe.index)
            .collect::<Vec<_>>(),
        [1, 2, 3, 4]
    );
    assert_eq!(
        compiled
            .keyframes
            .iter()
            .map(|keyframe| keyframe.reason)
            .collect::<Vec<_>>(),
        [
            highlite_compiler::KeyframeReason::Interaction,
            highlite_compiler::KeyframeReason::Mark,
            highlite_compiler::KeyframeReason::Annotation,
            highlite_compiler::KeyframeReason::Interaction,
        ]
    );
    assert_eq!(
        compiled
            .keyframes
            .iter()
            .map(|keyframe| keyframe.said.as_deref())
            .collect::<Vec<_>>(),
        [
            Some("This is the filter that breaks the chart."),
            Some("And here the retention number drops."),
            Some("I am circling the number that moved."),
            None,
        ]
    );
    assert_eq!(
        compiled
            .keyframes
            .iter()
            .map(|keyframe| keyframe.transcript_segment_ids.clone())
            .collect::<Vec<_>>(),
        [
            vec!["s1".to_owned()],
            vec!["s2".to_owned()],
            vec!["s3".to_owned()],
            Vec::new(),
        ]
    );
    assert!(
        compiled.keyframes[0]
            .score_reasons
            .iter()
            .any(|reason| reason == "event:click")
    );
    assert!(
        compiled.keyframes[1]
            .score_reasons
            .iter()
            .any(|reason| reason == "event:mark")
    );
    assert_eq!(compiled.manifest.viewport, Some(viewport()));
}

#[test]
fn writes_the_handoff_summary() {
    let compiled = compile_capture(&input());

    assert!(
        compiled
            .summary
            .contains("[highlite 1:00 · app.example.com/analytics “Analytics” · session-1]")
    );
    assert!(compiled.summary.contains(
        "- #1 (0:04) [clicked button “Date range”] “This is the filter that breaks the chart.”"
    ));
    assert!(compiled.summary.contains("  docs: analytics.date-range"));
    assert!(compiled.summary.contains(
        "- #2 (0:12) [marked “Retention metric”] “And here the retention number drops.”"
    ));
    assert!(compiled.summary.contains("  docs: analytics.net-retention"));
    assert!(compiled.summary.contains(
        "- #3 (0:25) [annotated circle on “Retention metric”] “I am circling the number that moved.”"
    ));
    assert!(
        compiled
            .summary
            .contains("- #4 (0:40) [navigated to https://app.example.com/settings]")
    );
}

#[test]
fn derives_crops_from_targets_and_annotations() {
    let compiled = compile_capture(&input());
    let click = compiled.keyframes[0].crop.unwrap();
    let mark = compiled.keyframes[1].crop.unwrap();
    let annotation = compiled.keyframes[2].crop.unwrap();

    assert!((click.x - 0.0).abs() < 0.001);
    assert!((click.y - 0.05).abs() < 0.001);
    assert!((click.width - 0.4).abs() < 0.001);
    assert!((click.height - 0.4).abs() < 0.001);

    assert!((mark.x - 0.176).abs() < 0.001);
    assert!((mark.y - 0.3).abs() < 0.001);
    assert!((mark.width - 0.448).abs() < 0.001);
    assert!((mark.height - 0.4).abs() < 0.001);

    assert!((annotation.x - 0.176).abs() < 0.001);
    assert!((annotation.y - 0.2625).abs() < 0.001);
    assert!((annotation.width - 0.448).abs() < 0.001);
    assert!((annotation.height - 0.4).abs() < 0.001);

    assert!(compiled.keyframes[3].crop.is_none());
}

#[test]
fn aligns_events_with_transcript_and_keyframes() {
    let compiled = compile_capture(&input());
    let find = |id: &str| {
        compiled
            .analysis
            .alignment
            .iter()
            .find(|alignment| alignment.event_id == id)
            .unwrap()
    };

    let click = find("event-click");
    assert_eq!(click.kind, highlite_compiler::TimelineKind::Click);
    assert_eq!(click.segment_ids, vec!["s1".to_owned()]);
    assert_eq!(click.keyframe_ids, vec!["f1".to_owned()]);
    assert!((click.confidence - 1.0).abs() < f64::EPSILON);

    let annotation = find("event-annotation");
    assert_eq!(annotation.segment_ids, vec!["s3".to_owned()]);
    assert_eq!(annotation.keyframe_ids, vec!["f4".to_owned()]);

    let navigate = find("event-navigate");
    assert!(navigate.segment_ids.is_empty());
    assert_eq!(navigate.keyframe_ids, vec!["f5".to_owned()]);
}

#[test]
fn collects_docs_refs_and_accepts_a_resolver() {
    let compiled = compile_capture(&input());
    assert_eq!(compiled.analysis.docs_refs.len(), 2);
    assert_eq!(compiled.analysis.docs_refs[0].target_id, "t1");
    assert_eq!(
        compiled.analysis.docs_refs[0].docs_id,
        "analytics.date-range"
    );
    assert_eq!(compiled.analysis.docs_refs[1].target_id, "t2");
    assert_eq!(
        compiled.analysis.docs_refs[1].docs_id,
        "analytics.net-retention"
    );

    let resolver = |target: &Target, _manifest: &HighliteManifest| -> Option<DocsRef> {
        (target.id == "t1").then(|| DocsRef {
            target_id: "t1".to_owned(),
            docs_id: "analytics.date-range".to_owned(),
            label: None,
            url: Some("https://docs.example.com/date-range".to_owned()),
            metadata: None,
        })
    };
    let resolved = compile_capture_with(&input(), Some(&resolver));
    let reference = resolved
        .analysis
        .docs_refs
        .iter()
        .find(|reference| reference.target_id == "t1")
        .unwrap();
    assert_eq!(reference.docs_id, "analytics.date-range");
    assert_eq!(
        reference.url.as_deref(),
        Some("https://docs.example.com/date-range")
    );
}

#[test]
fn respects_a_hard_budget_and_is_deterministic() {
    let mut first_input = input();
    first_input.options = Some(CompileOptions {
        max_keyframes: Some(2),
        ..CompileOptions::default()
    });

    let first = compile_capture(&first_input);
    let second = compile_capture(&first_input);

    let ids: Vec<&str> = first
        .keyframes
        .iter()
        .map(|keyframe| keyframe.id.as_str())
        .collect();
    assert_eq!(ids, ["f3", "f4"]);
    assert_eq!(first, second);
    assert_eq!(first.provenance.compiler.name, "highlite-compiler");
    assert_eq!(first.provenance.compiler.version, "0.1.0");
    assert_eq!(first.provenance.compiled_at, "2026-10-20T12:00:00.000Z");
    assert_eq!(first.provenance.options.max_keyframes, 2);
}

#[test]
fn deserializes_frame_candidates_with_optional_metadata() {
    let frame: FrameCandidate = serde_json::from_value(serde_json::json!({
        "id": "f1",
        "atMs": 1000,
        "imagePath": "frames/f1.png",
        "targetIds": [],
        "annotationIds": [],
        "transcriptSegmentIds": [],
        "reason": "interaction",
        "width": 10.0
    }))
    .expect("frame candidate");

    assert_eq!(frame.keyframe.id, "f1");
    assert_eq!(
        frame.keyframe.reason,
        highlite_compiler::KeyframeReason::Interaction
    );
    assert_eq!(frame.width, Some(10.0));
    assert_eq!(frame.signature, None);
}

#[test]
fn accepts_explicit_frames_and_merges_matching_signatures() {
    let manifest = make_manifest();
    let frames = manifest
        .keyframes
        .iter()
        .cloned()
        .map(|keyframe| FrameCandidate {
            keyframe,
            width: Some(1_000.0),
            height: Some(800.0),
            signature: Some("identical".to_owned()),
        })
        .collect();

    let compiled = compile_capture(&CompileInput {
        manifest,
        frames: Some(frames),
        viewport: Some(viewport()),
        options: Some(CompileOptions {
            max_keyframes: Some(1),
            ..CompileOptions::default()
        }),
    });

    assert_eq!(compiled.keyframes.len(), 1);
    assert!(compiled.keyframes[0].score >= 100);
}

#[test]
fn reports_missing_visual_evidence_instead_of_inventing_frames() {
    let mut request = input();
    request.manifest.keyframes.clear();
    request.frames = Some(Vec::new());

    let compiled = compile_capture(&request);

    assert!(compiled.keyframes.is_empty());
    assert!(compiled.warnings.iter().any(|warning| {
        warning == "No frame candidates were supplied, so the bundle has no visual evidence."
    }));
    assert!(compiled.summary.contains("Visual evidence: unavailable"));
    assert!(compiled.summary.contains("## Narration"));
    assert!(
        compiled
            .summary
            .contains("- 0:03 — “This is the filter that breaks the chart.”")
    );
}

#[test]
fn a_strong_spoken_cue_promotes_a_nearby_frame() {
    let mut request = input();
    request.manifest.transcript = vec![highlite_compiler::TranscriptSegment {
        id: Some("cue".to_owned()),
        start_ms: 5_000,
        end_ms: 5_600,
        text: "look here".to_owned(),
        word_timings: common::words("look here", 5_000, 5_600),
    }];
    request.manifest.keyframes = vec![highlite_compiler::Keyframe {
        id: "cue-frame".to_owned(),
        at_ms: 5_200,
        image_path: "frames/cue.png".to_owned(),
        target_ids: Vec::new(),
        annotation_ids: Vec::new(),
        transcript_segment_ids: Vec::new(),
        reason: highlite_compiler::KeyframeReason::Interaction,
    }];
    request.options = Some(CompileOptions {
        max_keyframes: Some(1),
        ..CompileOptions::default()
    });

    let compiled = compile_capture(&request);
    assert_eq!(compiled.keyframes.len(), 1);
    assert_eq!(compiled.keyframes[0].cue.as_deref(), Some("look"));
    assert!(
        compiled.keyframes[0]
            .score_reasons
            .iter()
            .any(|reason| reason == "cue:look")
    );
    assert!(compiled.summary.contains("cue “look”"));
}

#[test]
fn weak_demonstratives_do_not_retarget_plain_interactions() {
    let mut request = input();
    request.manifest.transcript = vec![highlite_compiler::TranscriptSegment {
        id: Some("filler".to_owned()),
        start_ms: 4_100,
        end_ms: 4_400,
        text: "that".to_owned(),
        word_timings: common::words("that", 4_100, 4_400),
    }];
    request.manifest.keyframes.retain(|frame| frame.id == "f1");
    request.options = Some(CompileOptions {
        max_keyframes: Some(1),
        ..CompileOptions::default()
    });

    let compiled = compile_capture(&request);
    assert_eq!(compiled.keyframes.len(), 1);
    assert_eq!(compiled.keyframes[0].cue, None);
}

#[test]
fn warns_when_a_strong_cue_has_no_frame_nearby() {
    let mut request = input();
    request.manifest.transcript = vec![highlite_compiler::TranscriptSegment {
        id: Some("cue".to_owned()),
        start_ms: 5_000,
        end_ms: 5_400,
        text: "look".to_owned(),
        word_timings: common::words("look", 5_000, 5_400),
    }];
    request.manifest.keyframes.retain(|frame| frame.id == "f5");

    let compiled = compile_capture(&request);
    assert!(compiled.warnings.iter().any(|warning| {
        warning.contains("Speech cue “look”") && warning.contains("no captured frame nearby")
    }));
}
