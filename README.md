# Highlite

Highlite is an embeddable browser SDK for capturing narrated, visually contextual web interactions. It is an independent prototype; it does not claim compatibility with Kit Langton's Scrawl format.

## Status

The repository is being built in milestones. The current slice includes the typed timeline, a floating Shadow DOM toolbar, microphone and permission-based frame capture, click/scroll/SPA-route context, DOM targets, four annotation tools, deterministic Markdown, ZIP export, and an interactive analytics demo. The canonical compiler is the Rust crate [`crates/highlite-compiler`](crates/highlite-compiler); it selects keyframes, aligns narration by clause, plans DOM-target crops, transcribes audio in the compile step, burns annotations into cropped frames, renders a contact sheet, and writes an agent bundle next to the handoff summary. It is checked against shared golden fixtures in [`fixtures/`](fixtures). See [the implementation notes](docs/implementation-notes.md) for browser constraints and progress.

## Development

Requires Node.js 22 or newer, pnpm 12, and a Rust toolchain with Cargo. Install dependencies with `pnpm install`. The `prepare` script configures the local Git hooks.

- `pnpm dev` — build workspace packages and start the demo
- `pnpm check` — formatting, lint, typecheck, tests, and Rust checks
- `pnpm build` — build workspace packages in dependency order
- `pnpm build:rust` — build the compiler CLI in release mode
- `pnpm bundle <capture-dir> --out <bundle-dir>` — transcribe, render, and write an agent bundle
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

// Call from a user gesture. Screen sharing, when enabled, opens a browser prompt.
await capture.start();
capture.mark('Retention metric selected');
const bundle = await capture.stop();
await capture.export(); // Downloads a ZIP with manifest, summary, context and media.
await capture.destroy();
```

`capture.frames` defaults to `'prompt'`; use `'none'` to avoid requesting display capture or inject a `FrameProvider`. Permission denial is non-fatal, but the bundle will clearly report unavailable visual evidence. `ui: 'headless'` omits the toolbar while retaining the same API. The generated IIFE is `packages/sdk/dist/highlite.iife.js` and exposes the explicit `window.Highlite` namespace.

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

Run `pnpm dev` and open the demo to try the analytics walkthrough. Its local preview shows the exact manifest and summary assembled by the SDK; it does not upload captures.

## Capture limitations

- Screenshots only exist when a user-approved frame provider supplies actual pixels. Ordinary page DOM APIs are not treated as screenshots.
- Captured pixels are **not automatically redacted**. Review the shared surface and avoid capturing sensitive content.
- Highlite does not record raw keystrokes or form values; query strings are omitted from URLs unless explicitly enabled.
- Cross-origin iframes, closed shadow roots, and browser chrome are outside ordinary DOM inspection.
- The browser records narration audio; transcription happens in the compiler step. With the
  local whisper.cpp backend no capture data leaves the machine. A configured custom or hosted
  transcriber is responsible for its own network behavior.

Commit messages are checked against Conventional Commits, and the pre-commit hook runs `pnpm check`.
