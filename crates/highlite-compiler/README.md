# highlite-compiler (Rust)

The canonical Highlite compiler. It turns a raw capture into a compact, agent-readable
bundle: transcribed narration, selected keyframes with burned-in annotations, a contact
sheet, a handoff summary, machine-readable analysis, and an optional Scrawl v1 subset export.

`compile_capture` is pure: no I/O, no model calls, no platform APIs. The `bundle` command
and the transcription backends are explicit adapters around it, so the same compiler runs
in a browser-adjacent tool, a local CLI, CI, or a server.

## CLI

```sh
# Pure compiler: CompileInput JSON on stdin, CompiledBundle JSON on stdout.
highlite-compiler compile [--pretty] < input.json > bundle.json

# Scrawl v1 subset export.
highlite-compiler scrawl  [--pretty] < input.json > scrawl.json

# Full agent bundle from a capture directory (manifest.json + media).
highlite-compiler bundle <capture-dir> --out <bundle-dir>
```

`input.json` is a `CompileInput`:

```json
{
  "manifest": { "schemaVersion": "0.1.0", "...": "..." },
  "viewport": { "x": 0, "y": 0, "width": 1280, "height": 800 },
  "options": { "maxKeyframes": 8, "speechCues": true }
}
```

`frames` defaults to `manifest.keyframes`; `viewport` defaults to `manifest.viewport`.

### `bundle`

A capture directory contains `manifest.json` (or `input.json`) and the files the manifest
references, typically `frames/` and `audio.webm`. The command:

1. transcribes narration when `manifest.transcript` is empty and audio exists,
2. compiles keyframes and aligns the transcript,
3. crops each selected frame and burns its annotations into it,
4. writes the agent bundle.

Options:

```
--out <dir>                 required
--transcribe <mode>         auto (default), off, parakeet, whisper, command
--transcriber-command <cmd> program that prints transcript JSON; audio path is appended
--parakeet-model <path>     parakeet.cpp GGUF (or HIGHLITE_PARAKEET_MODEL)
--parakeet <path>           parakeet-cli binary (or HIGHLITE_PARAKEET_BIN)
--model <path>              whisper.cpp model (or HIGHLITE_WHISPER_MODEL)
--whisper <path>            whisper.cpp binary (or HIGHLITE_WHISPER_BIN)
--language <code>           ASR language hint
--max-keyframes <n>         override the duration-based budget
--no-crop                   keep full frames
--no-annotations            do not burn annotations into frames
--no-contact-sheet          skip contact-sheet.png
--contact-sheet-width <px>  default 1600
```

The bundle directory contains:

```
summary.md          paste-ready, time-aligned narration and actions
contact-sheet.png   every selected keyframe in one image
frames/frame-01.png cropped keyframes with annotations burned in
scrawl.json         Scrawl v1 subset
bundle.json         CompiledBundle
analysis.json       CaptureAnalysis
manifest.json       the compiled manifest (rewritten frame paths)
audio.webm          copied from the capture, when present
```

### Transcription

Narration is transcribed in the compiler, not the browser, so the same step works wherever
`bundle` runs. Both local backends decode audio to 16 kHz mono WAV with `ffmpeg`
(`HIGHLITE_FFMPEG` overrides the binary).

- **Parakeet** (English-first) uses NVIDIA Parakeet models through
  [`parakeet.cpp`](https://github.com/mudler/parakeet.cpp). `parakeet-cli` is detected from
  `--parakeet`, `HIGHLITE_PARAKEET_BIN`, or `PATH`; a GGUF model is required via
  `--parakeet-model` or `HIGHLITE_PARAKEET_MODEL`. The compiler calls
  `parakeet-cli transcribe --json` and groups its per-word times into utterance segments.
  Download an English model from
  [`mudler/parakeet-cpp-gguf`](https://huggingface.co/mudler/parakeet-cpp-gguf):

  ```sh
  curl -LO https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt_ctc-110m-q8_0.gguf
  ```

- **whisper.cpp** is detected from `--whisper`, `HIGHLITE_WHISPER_BIN`, or `PATH`
  (`whisper-cli`, `whisper-cpp`, `whisper`). A model is required via `--model` or
  `HIGHLITE_WHISPER_MODEL`.
- **Generic command**: `--transcriber-command "python3 asr.py"` runs the program with the
  audio path appended and reads transcript JSON from stdout.
- **`--transcribe off`** compiles a capture with no narration.

`--transcribe auto` uses an explicit transcriber command first, then Parakeet when a
Parakeet model is configured, then Whisper. `--transcribe parakeet` / `whisper` force one
engine. Parakeet is English-first; `--language` is passed to it as `--lang` when set and is
mainly useful for the multilingual v3/Nemotron models.

Parakeet word times arrive in seconds; the compiler converts them to integer milliseconds
and applies `audioOffsetMs` exactly as it does for Whisper.

Generic command output (a bare array is also accepted):

```json
{
  "segments": [
    {
      "startMs": 0,
      "endMs": 1200,
      "text": "Look here, the retention metric.",
      "words": [{ "startMs": 0, "endMs": 300, "text": "Look" }]
    }
  ]
}
```

`words` (alias `wordTimings`) is optional. Timings are relative to the audio file; the
compiler shifts them by `manifest.audioOffsetMs` and clips them to `manifest.durationMs`.
Transcripts already present in the manifest are assumed to be on the session clock.

## Library

```rust
use highlite_compiler::{CompileInput, BundleOptions, compile_capture, write_bundle};

let mut compiled = compile_capture(&input);
println!("{}", compiled.summary);
write_bundle(&mut compiled, capture_dir, out_dir, &BundleOptions::default())?;
```

For a documentation resolver, use `compile_capture_with(&input, Some(&resolver))`.
For a custom ASR engine, implement `Transcriber` and call it before compiling, then pass the
segments through `shift_transcript`.

## Behavior

- Keyframe budget: 6 up to 20 s, one more per 20 s, capped at 12 (override up to 24).
- Marks and annotations are pinned; ordinary frames are scored and deduplicated.
- Narration is partitioned by clause and attached to keyframes in order.
- Crops come from annotation bounds first, then DOM target rects.
- Crops are applied to the stored frames when writing a bundle, not just reported.
- Annotations are drawn into each keyframe that references them, in the keyframe's cropped
  coordinate space.
- Spoken cues: “here”, “look”, “watch”, and “now” pin a nearby frame. “this”, “that”,
  “these”, “those”, “see”, and “there” only label an already-selected mark, annotation, or
  visual change. A strong cue with no captured frame nearby produces a warning instead of
  an invented frame.
- Docs refs come from target metadata (`docsId`, `docs`, `doc`, `documentation`, `docsPath`)
  or a `context:` target id.
- Timeline events are aligned to transcript segments and selected keyframes.

## Scrawl export

`scrawl` emits the `scrawl.json` v1 shape from `kitlangton/scrawl` (MIT). It is a browser
subset: no native window log, cursor stream or video unless the capture provided one. It is
not advertised as Scrawl-compatible until tested with Scrawl's own CLI.

## Testing

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all -- --check
```

The committed files in `fixtures/` are the language-neutral contract. `tests/golden.rs`
checks the Rust output against `expected-bundle.json` and `expected-scrawl.json`, and
`tests/cli.rs` checks the same path through the binary. `tests/bundle.rs` exercises the
full directory pipeline, including rendered PNGs and a transcribed capture.

A real engine is covered separately by the opt-in
[`scripts/parakeet-e2e.mjs`](../../scripts/parakeet-e2e.mjs). It runs `ffmpeg` and
`parakeet-cli` against a speech fixture through `bundle`, then checks the transcript,
timings, summary, frames and contact sheet. On macOS,
`bash scripts/setup-macos.sh --install-prereqs --verify` installs and runs it:

```sh
HIGHLITE_PARAKEET_BIN=/path/to/parakeet-cli \
HIGHLITE_PARAKEET_MODEL=/path/to/tdt_ctc-110m-q8_0.gguf \
pnpm test:parakeet
```

It skips when those variables are unset, and fails instead with
`HIGHLITE_REQUIRE_ASR=1`.

The binary is cross-compilable to Linux, macOS and Windows. A `wasm32` target can be added
without changing the pure compiler because only the adapters use platform APIs.
