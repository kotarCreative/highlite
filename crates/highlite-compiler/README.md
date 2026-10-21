# highlite-compiler (Rust)

The canonical Highlite compiler. It turns a raw capture into a compact, agent-readable
bundle: selected keyframes, per-keyframe narration, a handoff summary, machine-readable
analysis, and an optional Scrawl v1 subset export.

The core is pure: no I/O, no model calls, no platform APIs. The CLI is a thin stdin/stdout
wrapper, so any language can use the compiler without a JavaScript runtime.

## CLI

```sh
highlite-compiler compile [--pretty] < input.json > bundle.json
highlite-compiler scrawl  [--pretty] < input.json > scrawl.json
```

`input.json` is a `CompileInput`:

```json
{
  "manifest": { "schemaVersion": "0.1.0", "...": "..." },
  "viewport": { "x": 0, "y": 0, "width": 1280, "height": 800 },
  "options": { "maxKeyframes": 8 }
}
```

`frames` defaults to `manifest.keyframes`; `viewport` defaults to `manifest.viewport`.

## Library

```rust
use highlite_compiler::{CompileInput, compile_capture};

let compiled = compile_capture(&input);
println!("{}", compiled.summary);
```

For a documentation resolver, use `compile_capture_with(&input, Some(&resolver))`.

## Contracts

The serde types in `src/model.rs` are the source of truth:

- `CompileInput` / `CompileOptions`
- `HighliteManifest` and its timeline, targets, annotations and transcript
- `CompiledBundle`, `CompiledKeyframe`, `CaptureAnalysis`, `DocsRef`, `EventAlignment`
- `ScrawlBundleV1` and related export types in `src/scrawl.rs`

Timestamps are integer milliseconds (`u64`).

The committed files in `fixtures/` are the language-neutral contract. `tests/golden.rs` checks
the Rust output against `expected-bundle.json` and `expected-scrawl.json`, and `tests/cli.rs`
checks the same path through the binary.

## Behavior

- Keyframe budget: 6 up to 20 s, one more per 20 s, capped at 12 (override up to 24).
- Marks and annotations are pinned; ordinary frames are scored and deduplicated.
- Narration is partitioned by clause and attached to keyframes in order.
- Crops come from annotation bounds first, then DOM target rects.
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

The binary is cross-compilable to Linux, macOS and Windows. A `wasm32` target can be added
without changing the core because it has no platform dependencies.
