# Highlite

Highlite is an embeddable browser SDK for capturing narrated, visually contextual web interactions. It is an independent prototype; it does not claim compatibility with Kit Langton's Scrawl format.

## Status

The repository is being built in milestones. The current slice includes the typed timeline, a floating Shadow DOM toolbar, microphone and permission-based frame capture, click/scroll/SPA-route context, DOM targets, four annotation tools, deterministic Markdown, ZIP export, and an interactive analytics demo. The canonical compiler is the pure Rust crate [`crates/highlite-compiler`](crates/highlite-compiler); it selects keyframes, aligns narration by clause, plans DOM-target crops, emits an agent handoff summary, and exposes a JSON stdin/stdout CLI. It is checked against shared golden fixtures in [`fixtures/`](fixtures). Transcription, image rendering, server processing, contact sheets, and automatic frame scoring are not implemented yet. See [the implementation notes](docs/implementation-notes.md) for browser constraints and progress.

## Development

Requires Node.js 22 or newer, pnpm 12, and a Rust toolchain with Cargo. Install dependencies with `pnpm install`. The `prepare` script configures the local Git hooks.

- `pnpm dev` — build workspace packages and start the demo
- `pnpm check` — formatting, lint, typecheck, tests, and Rust checks
- `pnpm build` — build workspace packages in dependency order
- `pnpm build:rust` — build the compiler CLI in release mode
- `pnpm test:e2e` — build and run the browser smoke test, then the SDK → Rust compiler e2e (`CHROMIUM_PATH` can override `/usr/bin/chromium`)
- `pnpm test:compiler:e2e` — build the SDK and compiler, then compile a real browser capture through the Rust CLI

The compiler CLI reads a `CompileInput` JSON object on stdin:

```sh
cargo run -p highlite-compiler -- compile --pretty < fixtures/capture.json
cargo run -p highlite-compiler -- scrawl --pretty < fixtures/capture.json
```

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
- This prototype includes narration audio but does not yet transcribe it. No data is uploaded by default.

Commit messages are checked against Conventional Commits, and the pre-commit hook runs `pnpm check`.
