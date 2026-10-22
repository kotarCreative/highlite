# Highlite

Highlite is an embeddable browser SDK for capturing narrated, visually contextual web interactions. It is an independent prototype; it does not claim compatibility with Kit Langton's Scrawl format.

## Status

The repository is being built in milestones. The current slice includes the typed timeline, a floating Shadow DOM toolbar with one-at-a-time permission prompts, microphone and permission-based frame capture, click/scroll/SPA-route context, DOM targets, four annotation tools that fade after two seconds, deterministic Markdown, ZIP export, an authenticated relay that compiles uploads, and an interactive analytics demo. The canonical compiler is the Rust crate [`crates/highlite-compiler`](crates/highlite-compiler); it selects keyframes, aligns narration by clause, plans DOM-target crops, transcribes audio in the compile step, burns annotations into cropped frames, renders a contact sheet, and writes an agent bundle next to the handoff summary. It is checked against shared golden fixtures in [`fixtures/`](fixtures). See [the implementation notes](docs/implementation-notes.md) for browser constraints and progress.

## Development

Requires Node.js 22 or newer, pnpm 12, and a Rust toolchain with Cargo. Install dependencies with `pnpm install`. The `prepare` script configures the local Git hooks.

- `pnpm dev` — build workspace packages and start the demo
- `pnpm check` — formatting, lint, typecheck, tests, and Rust checks
- `pnpm build` — build workspace packages in dependency order
- `pnpm build:rust` — build the compiler CLI in release mode
- `pnpm bundle <capture-dir> --out <bundle-dir>` — transcribe, render, and write an agent bundle
- `pnpm relay -- --env-file ./relay.env` — run the authenticated relay that accepts and compiles session ZIPs
- `pnpm test:e2e` — build and run the browser smoke test, then the SDK → Rust compiler e2e (`CHROMIUM_PATH` can override `/usr/bin/chromium`)
- `pnpm test:compiler:e2e` — build the SDK and compiler, then compile a real browser capture through the Rust CLI
- `pnpm test:parakeet` — opt-in: run a real Parakeet transcription through `bundle` (see below)

The compiler CLI reads a `CompileInput` JSON object on stdin:

```sh
cargo run -p highlite-compiler -- compile --pretty < fixtures/capture.json
cargo run -p highlite-compiler -- scrawl --pretty < fixtures/capture.json
```

To produce the folder an agent reads, point `bundle` at an unpacked capture. It transcribes
narration, crops and annotates frames, writes the contact sheet, and prints the handoff
summary:

```sh
# English-first: NVIDIA Parakeet through parakeet.cpp
cargo run -p highlite-compiler -- bundle ./capture --out ./capture-bundle \
  --transcribe parakeet --parakeet-model ./tdt_ctc-110m-q8_0.gguf

# Or Whisper via whisper.cpp
cargo run -p highlite-compiler -- bundle ./capture --out ./capture-bundle \
  --transcribe whisper --model ~/.local/share/whisper/ggml-base.en.bin
```

The bundle contains `summary.md`, `contact-sheet.png`, `frames/frame-XX.png`,
`scrawl.json`, `bundle.json`, `analysis.json`, and `manifest.json`. Use
`--transcribe off` when the manifest already has a transcript. See the
[compiler README](crates/highlite-compiler/README.md) for backends and options.

### macOS setup

On macOS, the setup script installs missing Homebrew/Rust prerequisites (including
`cmake` for the relay's TLS stack), builds the SDK, compiler, and relay, downloads
`parakeet-cli` and an English Parakeet model, and optionally runs the real ASR e2e:

```sh
bash scripts/setup-macos.sh --install-prereqs --verify
```

Use `--model 0.6b` for the larger `tdt-0.6b-v2` model, `--skip-build` to reuse existing
builds, and `--force` to re-download the engine/model. Homebrew and the Xcode command
line tools must already be installed; the script prints the Homebrew command if it is
missing. Downloads are cached under `~/.cache/highlite/parakeet`.

### Parakeet e2e

`pnpm test:parakeet` runs a real Parakeet model through the whole pipeline:
capture manifest → `ffmpeg` → `parakeet-cli` → transcript alignment → cropped and
annotated frames → contact sheet. It needs a local binary and model:

```sh
export HIGHLITE_PARAKEET_BIN=/path/to/parakeet-cli
export HIGHLITE_PARAKEET_MODEL=/path/to/tdt_ctc-110m-q8_0.gguf
pnpm test:parakeet
```

The script downloads the small parakeet.cpp speech fixture on first use and caches it
under `~/.cache/highlite/asr/`. Set `HIGHLITE_ASR_AUDIO` to use your own WAV, or
`HIGHLITE_REQUIRE_ASR=1` to make missing configuration fail instead of skipping. This is
deliberately outside the default `pnpm check` and `pnpm test:e2e`; no model is required for
normal development.

## Embed

```ts
import { createHighlite } from '@highlite/sdk';

const capture = createHighlite({
  ui: 'floating',
  capture: { microphone: true, frames: 'prompt', interactions: true },
  privacy: { redactSelectors: ['[data-private]', 'input[type="password"]'] },
  onComplete: async (bundle) => {
    console.log(bundle.manifest, bundle.summary);
  },
});

// Call from a user gesture. Permissions are requested one at a time; the
// browser's share picker opens with the current tab preselected.
await capture.start();
capture.mark('Retention metric selected');
const bundle = await capture.stop();
await capture.export(); // Downloads a ZIP with manifest, summary, context and media.
await capture.destroy();
```

`capture.frames` defaults to `'prompt'`; use `'none'` to avoid requesting display capture or inject a `FrameProvider`. Permission denial is non-fatal, but the bundle will clearly report unavailable visual evidence. `ui: 'headless'` omits the toolbar and sends permission requests directly; with the floating UI each permission gets its own modal and browser prompt before recording begins. If microphone access was already granted for the origin, the microphone step is skipped and recording starts with audio as soon as the remaining steps are confirmed. A controller can record consecutive sessions by calling `start()` again after `stop()` or `cancel()`; each session gets a fresh id and its own timeline, annotations, targets, and files, while `export()` returns the most recently completed bundle. The generated IIFE is `packages/sdk/dist/highlite.iife.js` and exposes the explicit `window.Highlite` namespace.

For a script-tag integration, serve that built file from your own static asset host:

```html
<script defer src="/assets/highlite.iife.js"></script>
<script>
  window.addEventListener('load', () => {
    window.Highlite.createHighlite({
      ui: 'floating',
      capture: { microphone: true, frames: 'prompt', interactions: true },
      onComplete: (bundle) => console.log('Capture ready', bundle),
    });
  });
</script>
```

The asset URL above is an example path, not a published CDN endpoint.

## Relay server

`crates/highlite-relay` accepts a session ZIP, compiles it with the canonical compiler,
and exposes the resulting bundle instead of requiring a browser download. It separates
ingest and read bearer tokens, checks optional `Host`/`Origin` allowlists, bounds upload
and extraction sizes, rejects unsafe ZIP paths, and limits compile concurrency.

```sh
cp crates/highlite-relay/relay.env.example relay.env
chmod 600 relay.env
# edit relay.env
pnpm relay -- --env-file ./relay.env
```

All settings live in the env file. `--env-file` can be repeated, process environment
variables override the file, and `--bind` / `--data-dir` remain as operational
overrides. Compiler behavior is env-backed too: keyframe budget and gaps, crop and
coverage selection, spoken cues, annotation burning, and contact-sheet output.

Point the SDK at the ingest endpoint:

```ts
const capture = createHighlite({
  relay: {
    endpoint: 'https://relay.example.com/v1/sessions',
    token: import.meta.env.VITE_HIGHLITE_INGEST_TOKEN,
  },
});
```

The uploaded ZIP is compiled synchronously. `POST /v1/sessions` returns the session
metadata; `GET /v1/sessions/{id}` returns status and summary; and
`GET /v1/sessions/{id}/bundle.zip` serves the compiled bundle. Read endpoints require
the read token and are intentionally not exposed to the browser. Set
`HIGHLITE_RELAY_WEBHOOK_URL` and `HIGHLITE_RELAY_WEBHOOK_SECRET` to send signed
`session.ready` / `session.failed` webhooks to a consumer, or poll the status endpoint
instead. See the [relay README](crates/highlite-relay/README.md) for payloads, signature
verification, and deployment details.

The demo reads `VITE_HIGHLITE_RELAY_URL` and `VITE_HIGHLITE_RELAY_TOKEN` from `.env`
(copy `.env.example`) and uploads automatically when they are set.

Add `--ui` (or set `HIGHLITE_RELAY_UI=true`) to serve a local sessions browser at `/`.
It lists ingested sessions, shows their summaries, and runs pipelines defined in
`<data-dir>/pipelines.json` when `HIGHLITE_RELAY_ALLOW_PIPELINES=true`; pipelines require
a loopback bind and receive the compiled bundle paths in their environment. Startup
prints a URL with the read token in the fragment. See the
[relay README](crates/highlite-relay/README.md) for the pipeline format and run states.

Run `pnpm dev` and open the demo to try the analytics walkthrough. Its local preview shows the exact manifest and summary assembled by the SDK; it does not upload captures.

## Keyboard shortcuts

While a Highlite session is recording, hold **Ctrl** (Control on macOS) and press one of these keys. Requiring Ctrl means ordinary typing never triggers a session action. Shortcuts are ignored inside inputs, textareas, selects, and contenteditable fields.

| Key      | Action                                                  |
| -------- | ------------------------------------------------------- |
| `Ctrl+V` | Interact with the page                                  |
| `Ctrl+F` | Freehand annotation                                     |
| `Ctrl+C` | Circle annotation                                       |
| `Ctrl+A` | Arrow annotation                                        |
| `Ctrl+H` | Highlight annotation                                    |
| `Ctrl+M` | Mark the current moment                                 |
| `Ctrl+D` | Discard the Highlite session (asks for confirmation)    |
| `Ctrl+S` | Stop and assemble the bundle                            |
| `Esc`    | Leave annotation mode or close the discard confirmation |

`Esc` does not require a modifier. Note that several Ctrl combinations overlap browser shortcuts (copy, select all, find, save, bookmark, history), which Highlite consumes while a session is recording; browser-reserved ones such as Ctrl+H History may never reach the page.

## Capture limitations

- Screenshots only exist when a user-approved frame provider supplies actual pixels. Ordinary page DOM APIs are not treated as screenshots.
- Browsers cannot skip their own screen-share picker. Highlite preselects the current tab and hides monitor/window options where Chromium supports it, but the user still confirms the share in the browser prompt.
- Captured pixels are **not automatically redacted**. Review the shared surface and avoid capturing sensitive content.
- Highlite does not record raw keystrokes or form values; query strings are omitted from URLs unless explicitly enabled.
- Cross-origin iframes, closed shadow roots, and browser chrome are outside ordinary DOM inspection.
- The browser records narration audio; transcription happens in the compiler step. With the
  local whisper.cpp backend no capture data leaves the machine. A configured custom or hosted
  transcriber is responsible for its own network behavior.

Commit messages are checked against Conventional Commits, and the pre-commit hook runs `pnpm check`.
