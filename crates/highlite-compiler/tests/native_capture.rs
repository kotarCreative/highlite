use std::fs;

use highlite_compiler::{
    BundleOptions, CompileInput, HighliteManifest, KeyframeReason, compile_capture, write_bundle,
};

// The Swift capture builder's committed fixture. Keeping the Rust compatibility
// test on the same file ensures a manifest-shape change cannot land without the
// canonical compiler reading it.
const MANIFEST: &str = include_str!(
    "../../../apps/macos/Tests/HighliteMenuBarCoreTests/Fixtures/native-capture-manifest.json"
);
const IMAGE: &[u8] = include_bytes!(
    "../../../apps/macos/Tests/HighliteMenuBarCoreTests/Fixtures/native-capture.png"
);

#[test]
fn native_macos_still_capture_fixture_compiles_into_a_bundle() {
    let manifest: HighliteManifest =
        serde_json::from_str(MANIFEST).expect("native capture manifest should deserialize");
    assert_eq!(manifest.schema_version, "0.1.0");
    assert_eq!(manifest.timeline.len(), 1);
    assert_eq!(manifest.annotations.len(), 1);
    assert_eq!(manifest.targets.len(), 1);
    assert_eq!(manifest.keyframes.len(), 1);
    assert!(
        manifest.artifacts.video.is_none(),
        "older native manifests must not require a video artifact"
    );

    let mut compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: None,
        options: None,
    });

    assert_eq!(compiled.keyframes.len(), 1);
    let keyframe = &compiled.keyframes[0];
    assert_eq!(keyframe.reason, KeyframeReason::Annotation);
    assert_eq!(keyframe.annotation_ids, vec!["native-highlight"]);
    assert_eq!(keyframe.target_ids, vec!["native-region"]);
    assert_eq!(keyframe.crop, None);
    assert!(
        compiled
            .summary
            .contains("annotated highlight on “Check the total before saving.”"),
        "summary should identify the note and highlight: {}",
        compiled.summary
    );

    let capture = tempfile::tempdir().expect("capture dir");
    let output = tempfile::tempdir().expect("output dir");
    fs::write(capture.path().join("manifest.json"), MANIFEST).expect("write manifest");
    fs::write(capture.path().join("capture.png"), IMAGE).expect("write image");

    let written = write_bundle(
        &mut compiled,
        capture.path(),
        output.path(),
        &BundleOptions::default(),
    )
    .expect("write native capture bundle");

    assert_eq!(written.keyframe_paths, vec!["frames/frame-01.png"]);
    assert!(output.path().join("summary.md").is_file());
    assert!(output.path().join("frames/frame-01.png").is_file());
    assert!(output.path().join("contact-sheet.png").is_file());
    let bundled: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(output.path().join("manifest.json")).expect("bundled manifest"),
    )
    .expect("parse bundled manifest");
    assert!(bundled["artifacts"].get("video").is_none());
    assert!(
        !output.path().join("recording.mp4").exists(),
        "a manifest without video must not invent a playback asset"
    );
}
