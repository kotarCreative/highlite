# Implementation notes

## Milestone 0: constraints and compatibility

- Highlite will use its own proposed `0.1.0` manifest. The specification does not provide an upstream repository URL, license, sample `.scrawl` file, or processing contract to inspect; compatibility is therefore unvalidated and is not advertised.
- Browser DOM APIs cannot take a faithful screenshot of arbitrary rendered page content. Frame capture will only be reported when a user-approved frame provider supplies pixels; otherwise the bundle must state that visual evidence is unavailable.
- `getDisplayMedia()` requires an explicit user gesture and browser permission. Microphone and display capture can be denied independently and must stop cleanly.
- Cross-origin iframe contents, closed shadow roots, browser chrome, and sensitive pixels cannot be reliably inspected or automatically redacted by this SDK.
- MediaRecorder MIME types and permission UX vary by browser. The implementation must negotiate support instead of assuming WebM everywhere.

## Planned slices

1. Establish workspace, tooling, commit policy, and demo shell.
2. Implement the typed session core and embeddable lifecycle/audio/interaction capture.
3. Add annotations, explicit frame candidates, processing, and portable export.
4. Harden privacy, accessibility, browser coverage, and integration docs.
