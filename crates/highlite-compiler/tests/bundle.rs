mod common;

use std::fs;
use std::process::Command;

use common::make_manifest;
use highlite_compiler::{BundleOptions, CompileInput, compile_capture, write_bundle};
use image::{Rgba, RgbaImage};

fn capture_with_one_annotated_frame(directory: &std::path::Path) {
    let manifest = make_manifest();
    let mut manifest = manifest;
    manifest.keyframes.retain(|frame| frame.id == "f4");
    manifest.artifacts.audio = Some("audio.webm".to_owned());

    fs::create_dir_all(directory.join("frames")).expect("frames dir");
    let mut image = RgbaImage::from_pixel(1_000, 800, Rgba([32, 36, 48, 255]));
    for (x, y, pixel) in image.enumerate_pixels_mut() {
        if x > 200 && y > 300 {
            *pixel = Rgba([80, 120, 200, 255]);
        }
    }
    image
        .save(directory.join("frames/f4.png"))
        .expect("write frame");
    fs::write(directory.join("audio.webm"), b"not real audio").expect("write audio");
    fs::write(
        directory.join("manifest.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest JSON"),
    )
    .expect("write manifest");
}

#[test]
fn writes_an_agent_ready_bundle_with_rendered_frames_and_a_sheet() {
    let source = tempfile::tempdir().expect("capture dir");
    let output = tempfile::tempdir().expect("output dir");
    capture_with_one_annotated_frame(source.path());

    let manifest: highlite_compiler::HighliteManifest = serde_json::from_str(
        &fs::read_to_string(source.path().join("manifest.json")).expect("read manifest"),
    )
    .expect("parse manifest");
    let mut compiled = compile_capture(&CompileInput {
        manifest,
        frames: None,
        viewport: None,
        options: None,
    });

    let written = write_bundle(
        &mut compiled,
        source.path(),
        output.path(),
        &BundleOptions::default(),
    )
    .expect("write bundle");

    assert_eq!(written.keyframe_paths, vec!["frames/frame-01.png"]);
    assert_eq!(written.contact_sheet.as_deref(), Some("contact-sheet.png"));
    assert!(output.path().join("summary.md").is_file());
    assert!(output.path().join("bundle.json").is_file());
    assert!(output.path().join("analysis.json").is_file());
    assert!(output.path().join("contact-sheet.png").is_file());
    assert!(output.path().join("audio.webm").is_file());
    assert!(output.path().join("frames/frame-01.png").is_file());

    // The crop is applied to the stored frame, not only reported as numbers.
    let rendered = image::open(output.path().join("frames/frame-01.png"))
        .expect("rendered frame")
        .to_rgba8();
    assert!(rendered.width() < 1_000 && rendered.height() < 800);

    let scrawl: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(output.path().join("scrawl.json")).expect("scrawl JSON"),
    )
    .expect("parse scrawl");
    assert_eq!(scrawl["keyframes"][0]["file"], "frames/frame-01.png");
    assert_eq!(scrawl["contactSheet"], "contact-sheet.png");
    assert_eq!(scrawl["source"], "browser");

    let manifest: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(output.path().join("manifest.json")).expect("manifest JSON"),
    )
    .expect("parse manifest");
    assert_eq!(manifest["artifacts"]["contactSheet"], "contact-sheet.png");
    assert_eq!(manifest["keyframes"][0]["imagePath"], "frames/frame-01.png");
}

#[test]
fn the_bundle_command_compiles_a_capture_directory() {
    let source = tempfile::tempdir().expect("capture dir");
    let output = tempfile::tempdir().expect("output dir");
    capture_with_one_annotated_frame(source.path());

    let binary = env!("CARGO_BIN_EXE_highlite-compiler");
    let result = Command::new(binary)
        .arg("bundle")
        .arg(source.path())
        .arg("--out")
        .arg(output.path())
        .arg("--transcribe")
        .arg("off")
        .output()
        .expect("run compiler");

    assert!(
        result.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let stdout = String::from_utf8_lossy(&result.stdout);
    assert!(stdout.starts_with("[highlite "));
    assert!(output.path().join("summary.md").is_file());
    assert!(output.path().join("contact-sheet.png").is_file());
}

#[cfg(unix)]
#[test]
fn the_bundle_command_transcribes_audio_and_applies_the_audio_offset() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().expect("capture dir");
    let output = tempfile::tempdir().expect("output dir");
    capture_with_one_annotated_frame(source.path());

    let mut manifest: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(source.path().join("manifest.json")).expect("read manifest"),
    )
    .expect("parse manifest");
    manifest["transcript"] = serde_json::json!([]);
    manifest["audioOffsetMs"] = serde_json::json!(500);
    fs::write(
        source.path().join("manifest.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest JSON"),
    )
    .expect("write manifest");

    let transcriber = source.path().join("fake-asr.sh");
    fs::write(
        &transcriber,
        "#!/bin/sh\nprintf '%s' '{\"segments\":[{\"startMs\":0,\"endMs\":900,\"text\":\"Look here\",\"words\":[{\"startMs\":0,\"endMs\":300,\"text\":\"Look\"},{\"startMs\":300,\"endMs\":900,\"text\":\"here\"}]}]}'\n",
    )
    .expect("write transcriber");
    let mut permissions = fs::metadata(&transcriber).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&transcriber, permissions).expect("chmod");

    let binary = env!("CARGO_BIN_EXE_highlite-compiler");
    let result = Command::new(binary)
        .arg("bundle")
        .arg(source.path())
        .arg("--out")
        .arg(output.path())
        .arg("--transcriber-command")
        .arg(&transcriber)
        .output()
        .expect("run compiler");

    assert!(
        result.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stderr).contains("Transcribed 1 segment"));

    let written: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(output.path().join("manifest.json")).expect("manifest"),
    )
    .expect("parse manifest");
    assert_eq!(written["transcript"][0]["startMs"], 500);
    assert_eq!(written["transcript"][0]["endMs"], 1_400);
    assert!(output.path().join("summary.md").is_file());
}

#[cfg(unix)]
#[test]
fn the_bundle_command_uses_the_parakeet_backend() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().expect("capture dir");
    let output = tempfile::tempdir().expect("output dir");
    capture_with_one_annotated_frame(source.path());

    let mut manifest: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(source.path().join("manifest.json")).expect("read manifest"),
    )
    .expect("parse manifest");
    manifest["transcript"] = serde_json::json!([]);
    manifest["audioOffsetMs"] = serde_json::json!(200);
    manifest["artifacts"]["audio"] = serde_json::json!("audio.wav");
    fs::write(
        source.path().join("manifest.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest JSON"),
    )
    .expect("write manifest");

    // Parakeet goes through ffmpeg, so give it a decodable file even though the
    // fake CLI ignores the audio contents.
    let samples: u32 = 1_600;
    let mut wav = Vec::new();
    wav.extend(b"RIFF");
    wav.extend((36 + samples * 2).to_le_bytes());
    wav.extend(b"WAVEfmt ");
    wav.extend(16_u32.to_le_bytes());
    wav.extend(1_u16.to_le_bytes());
    wav.extend(1_u16.to_le_bytes());
    wav.extend(16_000_u32.to_le_bytes());
    wav.extend(32_000_u32.to_le_bytes());
    wav.extend(2_u16.to_le_bytes());
    wav.extend(16_u16.to_le_bytes());
    wav.extend(b"data");
    wav.extend((samples * 2).to_le_bytes());
    wav.extend(vec![0_u8; samples as usize * 2]);
    fs::write(source.path().join("audio.wav"), &wav).expect("write wav");

    let parakeet = source.path().join("fake-parakeet-cli");
    fs::write(
        &parakeet,
        "#!/bin/sh\nprintf '%s' '{\"text\":\"Look here. This is the chart.\",\"words\":[{\"w\":\"Look\",\"start\":0.1,\"end\":0.3,\"conf\":0.99},{\"w\":\"here.\",\"start\":0.3,\"end\":0.6,\"conf\":0.98},{\"w\":\"This\",\"start\":1.5,\"end\":1.7,\"conf\":0.97},{\"w\":\"chart.\",\"start\":1.7,\"end\":2.2,\"conf\":0.99}]}'\n",
    )
    .expect("write parakeet");
    let mut permissions = fs::metadata(&parakeet).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&parakeet, permissions).expect("chmod");

    let model = source.path().join("parakeet.gguf");
    fs::write(&model, b"fake gguf").expect("write model");

    let binary = env!("CARGO_BIN_EXE_highlite-compiler");
    let result = Command::new(binary)
        .arg("bundle")
        .arg(source.path())
        .arg("--out")
        .arg(output.path())
        .arg("--transcribe")
        .arg("parakeet")
        .arg("--parakeet")
        .arg(&parakeet)
        .arg("--parakeet-model")
        .arg(&model)
        .output()
        .expect("run compiler");

    assert!(
        result.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stderr).contains("Transcribing with parakeet-cli"));

    let written: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(output.path().join("manifest.json")).expect("manifest"),
    )
    .expect("parse manifest");
    assert_eq!(written["transcript"][0]["text"], "Look here.");
    assert_eq!(written["transcript"][0]["startMs"], 300);
    assert_eq!(written["transcript"][0]["endMs"], 800);
    assert_eq!(written["transcript"][1]["text"], "This chart.");
    assert_eq!(written["transcript"][1]["startMs"], 1_700);
}
