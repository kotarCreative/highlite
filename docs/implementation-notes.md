# Implementation notes

## Milestone 0: constraints and compatibility

- Highlite uses its own proposed `0.1.0` manifest. Upstream Scrawl is public at `kitlangton/scrawl` under the MIT license; its `scrawl.json` v1 schema (`src/model.rs`) and keyframe/summary processing (`src/keyframes.rs`, `src/sketch.rs`) are inspectable. The compiler's Scrawl export is a browser subset and is not advertised as compatible until a contract test against a real Scrawl build passes.
- Browser DOM APIs cannot take a faithful screenshot of arbitrary rendered page content. Frame capture will only be reported when a user-approved frame provider supplies pixels; otherwise the bundle must state that visual evidence is unavailable.
- `getDisplayMedia()` requires an explicit user gesture and browser permission. The browser may offer a tab, window, or entire display rather than a guaranteed current-tab source. Microphone and display capture can be denied independently and must stop cleanly.
- The manifest records an approximate `audioOffsetMs` relative to the session clock when MediaRecorder starts. Browser chunk delivery is not treated as sample-accurate timing.
- Manifest timestamps are whole milliseconds: the monotonic clock is rounded before events, keyframes and durations are recorded, matching the compiler's `u64` millisecond contract.
- Cross-origin iframe contents, closed shadow roots, browser chrome, and sensitive pixels cannot be reliably inspected or automatically redacted by this SDK.
- MediaRecorder MIME types and permission UX vary by browser. The implementation must negotiate support instead of assuming WebM everywhere.

## Progress

- **Foundation complete:** pnpm workspace, Oxc tools, Git hooks and conventional commit enforcement, common-clock timeline, deterministic summary, ESM/IIFE builds, and a fake analytics demo.
- **Browser shell in progress:** Shadow DOM toolbar, mic recording, user-approved display-frame provider, click/scroll/route events, privacy-aware DOM target metadata, annotations, cancellation/cleanup, processor seam, and ZIP export are implemented. The Chromium smoke test covers annotation targeting, interactions, query-string stripping, denied-permission fallback, cancellation, and ZIP creation; actual OS display-picker behavior still needs manual browser testing.
- **Compiler core in progress:** the canonical compiler is the pure Rust crate `crates/highlite-compiler`. It defines the raw-capture and compiled-bundle contracts, pins marks and annotations, applies Scrawl's duration budget, aligns narration by clause, plans DOM-target crops, aligns timeline events to transcript and keyframes, collects docs refs, and emits a paste-ready handoff summary plus a Scrawl v1 export subset. The stdin/stdout CLI makes it usable from any language. `fixtures/` holds the shared golden input/output used by the golden and CLI tests, and `scripts/compiler-e2e.mjs` captures in Chromium then compiles the resulting SDK manifest through the Rust CLI. ASR, media rendering, HTTP, and storage adapters are separate.
- **Not implemented:** transcription adapter, reference processor HTTP server, image redaction, smart crops, contact sheet rendering, Scrawl CLI contract validation, preview polish, and browser compatibility matrix.

## Planned slices

1. Establish workspace, tooling, commit policy, and demo shell.
2. Implement the typed session core and embeddable lifecycle/audio/interaction capture.
3. Add annotations, explicit frame candidates, processing, and portable export.
4. Harden privacy, accessibility, browser coverage, and integration docs.
