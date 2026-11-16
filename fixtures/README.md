# Shared compiler fixtures

These files are the language-neutral contract for the compiler.

- `capture.json` — a legacy `CompileInput` example: manifest plus viewport. It intentionally has
  no form events or capture-time event links so legacy input stays covered.
- `form-capture.json` — a `CompileInput` with semantic form actions, environment context, and
  exact event-to-frame links.
- `expected-report.json` — the golden report-ready action list for `form-capture.json`.
- `expected-bundle.json` — the golden `CompiledBundle` output.
- `expected-scrawl.json` — the golden Scrawl v1 subset output.

The golden files were originally produced by the TypeScript reference implementation before it
was removed. They are now committed regression fixtures, not generated artifacts. The Rust crate
checks them in `tests/golden.rs`, `tests/report.rs`, and `tests/cli.rs`. Any future port should
compile `capture.json` and match the expected JSON, with numbers compared as f64 (`1` and `1.0`
are equivalent).

When the contract changes, update `capture.json`, run the compiler, review the output diff
carefully, and commit the new golden files deliberately.
