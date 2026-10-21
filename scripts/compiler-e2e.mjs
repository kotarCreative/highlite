import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
import { chromium } from 'playwright-core';

const executablePath = process.env.CHROMIUM_PATH ?? '/usr/bin/chromium';
if (!existsSync(executablePath)) {
  throw new Error(
    `Chromium was not found at ${executablePath}. Set CHROMIUM_PATH to its location.`,
  );
}

const binaryName = process.platform === 'win32' ? 'highlite-compiler.exe' : 'highlite-compiler';
const compiler =
  process.env.HIGHLITE_COMPILER ??
  fileURLToPath(new URL(`../target/release/${binaryName}`, import.meta.url));
if (!existsSync(compiler)) {
  throw new Error(`The compiler binary was not found at ${compiler}. Run pnpm build:rust first.`);
}

const server = await createServer({
  configFile: false,
  root: fileURLToPath(new URL('../apps/demo/', import.meta.url)),
  logLevel: 'error',
  server: { host: '127.0.0.1', port: 0, strictPort: false },
});

let browser;
try {
  await server.listen();
  const address = server.httpServer?.address();
  if (!address || typeof address === 'string') throw new Error('Vite did not open a TCP port.');
  const baseUrl = `http://127.0.0.1:${address.port}`;

  browser = await chromium.launch({
    executablePath,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await page.addScriptTag({
    path: fileURLToPath(new URL('../packages/sdk/dist/highlite.iife.js', import.meta.url)),
  });

  const manifest = await page.evaluate(async () => {
    const frameProvider = {
      async start() {},
      async capture() {
        const canvas = document.createElement('canvas');
        canvas.width = 320;
        canvas.height = 200;
        const context = canvas.getContext('2d');
        context.fillStyle = '#5271ff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
      },
      async stop() {},
    };

    const capture = window.Highlite.createHighlite({
      ui: 'headless',
      capture: { microphone: false, frames: 'none', interactions: true },
      frameProvider,
    });
    capture.registerTarget('[data-context-id="net-retention"]', {
      id: 'metric.net-retention',
      docsId: 'analytics.net-retention',
    });

    await capture.start();
    document.querySelector('.metric-card.featured').click();
    await capture.mark('Retention checkpoint');
    const bundle = await capture.stop();
    await capture.destroy();
    return bundle.manifest;
  });

  assert.ok(manifest.sessionId, 'The SDK must produce a session id.');
  assert.ok(manifest.viewport, 'The SDK must record its viewport for the compiler.');
  assert.ok(manifest.viewport.width > 0 && manifest.viewport.height > 0);
  assert.ok(Number.isInteger(manifest.durationMs), 'SDK duration must be whole milliseconds.');
  assert.ok(
    manifest.timeline.every((event) => Number.isInteger(event.atMs)),
    'SDK event timestamps must be whole milliseconds.',
  );
  assert.ok(
    manifest.keyframes.every((keyframe) => Number.isInteger(keyframe.atMs)),
    'SDK keyframe timestamps must be whole milliseconds.',
  );
  assert.ok(manifest.keyframes.length > 0, 'The fake frame provider must produce keyframes.');
  assert.ok(
    manifest.timeline.some((event) => event.kind === 'click'),
    'The SDK must record the click.',
  );
  assert.ok(
    manifest.timeline.some((event) => event.kind === 'mark'),
    'The SDK must record the mark.',
  );
  assert.ok(
    manifest.targets.some((target) => target.metadata?.docsId === 'analytics.net-retention'),
    'The SDK must preserve registered target metadata.',
  );

  const endMs = Math.max(1_000, manifest.durationMs);
  const words = 'This is the retention metric I meant.'.split(' ');
  manifest.transcript = [
    {
      id: 'e2e-segment',
      startMs: 0,
      endMs,
      text: words.join(' '),
      wordTimings: words.map((text, index) => ({
        startMs: Math.round((index / words.length) * endMs),
        endMs: Math.round(((index + 1) / words.length) * endMs),
        text,
      })),
    },
  ];

  const input = JSON.stringify({ manifest });
  const compiled = JSON.parse(execFileSync(compiler, ['compile'], { input, encoding: 'utf8' }));

  assert.equal(compiled.schemaVersion, '0.1.0');
  assert.equal(compiled.manifest.sessionId, manifest.sessionId);
  assert.equal(compiled.manifest.viewport.width, manifest.viewport.width);
  assert.ok(compiled.keyframes.length > 0, 'The compiler must select keyframes.');
  assert.ok(
    compiled.keyframes.some((keyframe) => keyframe.said),
    'The compiler must align the injected transcript to a keyframe.',
  );
  assert.ok(
    compiled.analysis.docsRefs.some((reference) => reference.docsId === 'analytics.net-retention'),
    'The compiler must carry registered docs metadata through to analysis.',
  );
  assert.ok(compiled.summary.startsWith('[highlite '));
  assert.ok(compiled.summary.includes('  docs: analytics.net-retention'));
  assert.ok(compiled.summary.includes('- #1 ('));
  assert.equal(compiled.analysis.alignment.length, manifest.timeline.length);

  const scrawl = JSON.parse(execFileSync(compiler, ['scrawl'], { input, encoding: 'utf8' }));
  assert.equal(scrawl.version, 1);
  assert.equal(scrawl.id, manifest.sessionId);
  assert.equal(scrawl.keyframes.length, compiled.keyframes.length);
  assert.equal(scrawl.target.mode, 'window');
  assert.equal(scrawl.transcript.source, 'highlite');
  assert.equal(scrawl.contactSheet, 'contact-sheet.png');
  assert.ok(scrawl.events.length > 0, 'Scrawl events must include the SDK interactions.');

  assert.deepEqual(pageErrors, [], `Unexpected browser errors: ${pageErrors.join(', ')}`);
  process.stdout.write(
    'Compiler e2e passed: browser SDK manifest -> Rust compile and Scrawl export.\n',
  );
} finally {
  await browser?.close();
  await server.close();
}
