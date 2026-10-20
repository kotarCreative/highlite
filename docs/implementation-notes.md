# Implementation notes

## Milestone 0: constraints and compatibility

- Highlite will use its own proposed `0.1.0` manifest. The specification does not provide an upstream repository URL, license, sample `.scrawl` file, or processing contract to inspect; compatibility is therefore unvalidated and is not advertised.
- Browser DOM APIs cannot take a faithful screenshot of arbitrary rendered page content. Frame capture will only be reported when a user-approved frame provider supplies pixels; otherwise the bundle must state that visual evidence is unavailable.
- `getDisplayMedia()` requires an explicit user gesture and browser permission. The browser may offer a tab, window, or entire display rather than a guaranteed current-tab source. Microphone and display capture can be denied independently and must stop cleanly.
- The manifest records an approximate `audioOffsetMs` relative to the session clock when MediaRecorder starts. Browser chunk delivery is not treated as sample-accurate timing.
- Cross-origin iframe contents, closed shadow roots, browser chrome, and sensitive pixels cannot be reliably inspected or automatically redacted by this SDK.
- MediaRecorder MIME types and permission UX vary by browser. The implementation must negotiate support instead of assuming WebM everywhere.

## Progress

- **Foundation complete:** pnpm workspace, Oxc tools, Git hooks and conventional commit enforcement, common-clock timeline, deterministic summary, ESM/IIFE builds, and a fake analytics demo.
- **Browser shell in progress:** Shadow DOM toolbar, mic recording, user-approved display-frame provider, click/scroll/route events, privacy-aware DOM target metadata, annotations, cancellation/cleanup, processor seam, and ZIP export are implemented. The Chromium smoke test covers annotation targeting, interactions, query-string stripping, denied-permission fallback, cancellation, and ZIP creation; actual OS display-picker behavior still needs manual browser testing.
- **Not implemented:** transcription adapter, reference processor HTTP server, image redaction, smart crops, keyframe ranking/deduplication, contact sheet, preview polish, and browser compatibility matrix.

## Planned slices

1. Establish workspace, tooling, commit policy, and demo shell.
2. Implement the typed session core and embeddable lifecycle/audio/interaction capture.
3. Add annotations, explicit frame candidates, processing, and portable export.
4. Harden privacy, accessibility, browser coverage, and integration docs.
