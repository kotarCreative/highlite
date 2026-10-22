mod common;

use std::collections::BTreeMap;
use std::fs;

use common::{make_manifest, viewport};
use highlite_compiler::{
    Annotation, AnnotationKind, BundleOptions, CompileInput, CompileOptions, CoordinateSpace,
    HighliteManifest, Keyframe, KeyframeReason, Point, TimelineEvent, TimelineKind,
    compile_capture, write_bundle,
};
use image::{Rgba, RgbaImage};

fn annotation(id: &str, at_ms: u64, kind: AnnotationKind, points: Vec<(f64, f64)>) -> Annotation {
    Annotation {
        id: id.to_owned(),
        at_ms,
        kind,
        points: points.into_iter().map(|(x, y)| Point { x, y }).collect(),
        coordinate_space: CoordinateSpace::ViewportNormalized,
        stroke_width: Some(4.0),
        fade_after_ms: None,
        fade_duration_ms: None,
        target_id: None,
    }
}

fn annotation_event(id: &str, at_ms: u64, annotation_id: &str) -> TimelineEvent {
    let mut payload = BTreeMap::new();
    payload.insert(
        "annotationId".to_owned(),
        serde_json::Value::String(annotation_id.to_owned()),
    );
    TimelineEvent {
        id: id.to_owned(),
        seq: at_ms / 1_000,
        at_ms,
        kind: TimelineKind::Annotation,
        target_id: None,
        payload,
    }
}

fn keyframe(id: &str, at_ms: u64, reason: KeyframeReason, annotation_ids: &[&str]) -> Keyframe {
    Keyframe {
        id: id.to_owned(),
        at_ms,
        image_path: format!("frames/{id}.png"),
        target_ids: Vec::new(),
        annotation_ids: annotation_ids.iter().map(|id| (*id).to_owned()).collect(),
        transcript_segment_ids: Vec::new(),
        reason,
    }
}

fn annotations_manifest() -> HighliteManifest {
    let mut manifest = make_manifest();
    manifest.transcript.clear();
    manifest.targets.clear();
    manifest.annotations = vec![
        annotation(
            "a1",
            10_000,
            AnnotationKind::Circle,
            vec![(0.1, 0.4), (0.2, 0.5)],
        ),
        annotation(
            "a2",
            12_000,
            AnnotationKind::Arrow,
            vec![(0.6, 0.4), (0.8, 0.5)],
        ),
    ];
    manifest.timeline = vec![
        annotation_event("event-annotation-1", 10_000, "a1"),
        annotation_event("event-annotation-2", 12_000, "a2"),
    ];
    manifest.keyframes = vec![
        keyframe("f1", 9_200, KeyframeReason::Interaction, &[]),
        keyframe("f2", 10_100, KeyframeReason::Annotation, &["a1"]),
        keyframe("f3", 12_100, KeyframeReason::Annotation, &["a2"]),
    ];
    manifest
}

fn with_fade(mut annotation: Annotation, after_ms: u64, duration_ms: u64) -> Annotation {
    annotation.fade_after_ms = Some(after_ms);
    annotation.fade_duration_ms = Some(duration_ms);
    annotation
}

#[test]
fn opacity_holds_for_four_seconds_then_fades_out() {
    let annotation = with_fade(
        annotation(
            "a1",
            10_000,
            AnnotationKind::Freehand,
            vec![(0.1, 0.1), (0.2, 0.2)],
        ),
        4_000,
        500,
    );

    assert_eq!(annotation.opacity_at(10_000), 1.0);
    assert_eq!(annotation.opacity_at(14_000), 1.0);
    assert!((annotation.opacity_at(14_250) - 0.5).abs() < f64::EPSILON);
    assert_eq!(annotation.opacity_at(14_500), 0.0);
    assert_eq!(annotation.opacity_at(20_000), 0.0);
}

#[test]
fn annotations_leave_keyframes_when_their_fade_finishes() {
    let mut manifest = annotations_manifest();
    manifest.annotations = vec![with_fade(
        annotation(
            "a1",
            10_000,
            AnnotationKind::Circle,
            vec![(0.2, 0.2), (0.3, 0.3)],
        ),
        4_000,
        500,
    )];
    manifest.timeline = vec![annotation_event("event-annotation-1", 10_000, "a1")];
    manifest.keyframes = vec![
        keyframe("f2", 10_100, KeyframeReason::Annotation, &["a1"]),
        keyframe("f3", 14_100, KeyframeReason::Interaction, &[]),
        keyframe("f4", 14_600, KeyframeReason::Interaction, &[]),
    ];

    let compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: Some(viewport()),
        options: None,
    });

    let ids = |id: &str| {
        compiled
            .keyframes
            .iter()
            .find(|keyframe| keyframe.id == id)
            .unwrap_or_else(|| panic!("{id} keyframe"))
            .annotation_ids
            .clone()
    };
    assert_eq!(ids("f2"), vec!["a1".to_owned()]);
    assert_eq!(
        ids("f3"),
        vec!["a1".to_owned()],
        "mid-fade annotations are still partially visible"
    );
    assert!(
        ids("f4").is_empty(),
        "fully faded annotations must not be burned into later keyframes"
    );
}

#[test]
fn every_annotation_still_on_screen_is_attached_to_the_keyframe() {
    let compiled = compile_capture(&CompileInput {
        manifest: annotations_manifest(),
        frames: None,
        viewport: Some(viewport()),
        options: None,
    });

    let ids: Vec<(&str, Vec<String>)> = compiled
        .keyframes
        .iter()
        .map(|keyframe| (keyframe.id.as_str(), keyframe.annotation_ids.clone()))
        .collect();
    assert_eq!(
        ids,
        [
            ("f1", Vec::<String>::new()),
            ("f2", vec!["a1".to_owned()]),
            // Drawing the arrow must not make the earlier circle disappear.
            ("f3", vec!["a1".to_owned(), "a2".to_owned()]),
        ]
    );
    assert!(
        compiled.summary.contains("[annotated arrow]"),
        "the summary must describe the newest stroke, not the inherited one:\n{}",
        compiled.summary
    );
}

#[test]
fn scrolling_clears_annotations_from_later_keyframes() {
    let mut manifest = annotations_manifest();
    manifest.timeline.push(TimelineEvent {
        id: "event-scroll".to_owned(),
        seq: 13,
        at_ms: 13_000,
        kind: TimelineKind::Scroll,
        target_id: None,
        payload: BTreeMap::new(),
    });
    manifest
        .keyframes
        .push(keyframe("f4", 13_200, KeyframeReason::Interaction, &[]));

    let compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: Some(viewport()),
        options: None,
    });

    let after_scroll = compiled
        .keyframes
        .iter()
        .find(|keyframe| keyframe.id == "f4")
        .expect("scroll keyframe");
    assert!(
        after_scroll.annotation_ids.is_empty(),
        "the SDK clears its overlay on scroll, so stale strokes must not be burned in"
    );
}

#[test]
fn route_changes_clear_annotations_from_later_keyframes() {
    let mut manifest = annotations_manifest();
    manifest.timeline.push(TimelineEvent {
        id: "event-navigate".to_owned(),
        seq: 13,
        at_ms: 13_000,
        kind: TimelineKind::Navigate,
        target_id: None,
        payload: BTreeMap::new(),
    });
    manifest
        .keyframes
        .push(keyframe("f4", 13_400, KeyframeReason::Interaction, &[]));

    let compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: Some(viewport()),
        options: None,
    });

    let after_route = compiled
        .keyframes
        .iter()
        .find(|keyframe| keyframe.id == "f4")
        .expect("route keyframe");
    assert!(
        after_route.annotation_ids.is_empty(),
        "viewport-normalized strokes cannot be carried across a route change"
    );
}

#[test]
fn crop_covers_every_annotation_burned_into_the_frame() {
    let compiled = compile_capture(&CompileInput {
        manifest: annotations_manifest(),
        frames: None,
        viewport: Some(viewport()),
        options: None,
    });

    let frame = compiled
        .keyframes
        .iter()
        .find(|keyframe| keyframe.id == "f3")
        .expect("annotated keyframe");
    let crop = frame.crop.expect("crop");

    assert!(
        crop.x <= 0.1 && crop.x + crop.width >= 0.8,
        "crop {crop:?} must include both annotations horizontally"
    );
    assert!(
        crop.y <= 0.4 && crop.y + crop.height >= 0.5,
        "crop {crop:?} must include both annotations vertically"
    );
}

fn has_ink_near(image: &RgbaImage, x: u32, y: u32, radius: u32) -> bool {
    let background = Rgba([20, 20, 24, 255]);
    let min_x = x.saturating_sub(radius);
    let min_y = y.saturating_sub(radius);
    let max_x = (x + radius).min(image.width().saturating_sub(1));
    let max_y = (y + radius).min(image.height().saturating_sub(1));
    (min_y..=max_y).any(|py| (min_x..=max_x).any(|px| *image.get_pixel(px, py) != background))
}

#[test]
fn the_bundle_burns_all_annotations_visible_on_a_keyframe() {
    let source = tempfile::tempdir().expect("capture dir");
    let output = tempfile::tempdir().expect("output dir");
    fs::create_dir_all(source.path().join("frames")).expect("frames dir");
    for frame in ["f1", "f2", "f3"] {
        RgbaImage::from_pixel(1_000, 800, Rgba([20, 20, 24, 255]))
            .save(source.path().join(format!("frames/{frame}.png")))
            .expect("write frame");
    }

    let manifest = annotations_manifest();
    let mut compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: Some(viewport()),
        options: Some(CompileOptions {
            crop: Some(false),
            ..CompileOptions::default()
        }),
    });
    let position = compiled
        .keyframes
        .iter()
        .position(|keyframe| keyframe.annotation_ids.len() == 2)
        .expect("keyframe with both annotations");

    let written = write_bundle(
        &mut compiled,
        source.path(),
        output.path(),
        &BundleOptions {
            annotations: true,
            contact_sheet: false,
            contact_sheet_width: 1_600,
        },
    )
    .expect("write bundle");
    let image = image::open(output.path().join(&written.keyframe_paths[position]))
        .expect("rendered frame")
        .to_rgba8();

    assert!(
        has_ink_near(&image, 150, 400, 6),
        "the circle drawn first must still be in the frame"
    );
    assert!(
        has_ink_near(&image, 700, 360, 6),
        "the arrow drawn second must be in the frame"
    );
}
