import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createServer } from 'vite';
import { chromium } from 'playwright-core';
import { fileURLToPath } from 'node:url';

const executablePath = process.env.CHROMIUM_PATH ?? '/usr/bin/chromium';
if (!existsSync(executablePath)) {
  throw new Error(
    `Chromium was not found at ${executablePath}. Set CHROMIUM_PATH to its location.`,
  );
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
    args: [
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--use-fake-device-for-media-stream',
      '--use-fake-ui-for-media-stream',
    ],
  });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: async () => {
          throw new DOMException('Permission denied by browser smoke test.', 'NotAllowedError');
        },
        getDisplayMedia: async () => {
          throw new DOMException('Permission denied by browser smoke test.', 'NotAllowedError');
        },
      },
    });
  });

  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.goto(`${baseUrl}/?access_token=must-not-be-exported`, {
    waitUntil: 'domcontentloaded',
  });
  const launcher = page.getByRole('button', { name: 'Open Highlite capture tools' });
  await launcher.waitFor({ state: 'visible' });
  await launcher.click();
  await page.getByRole('button', { name: 'Start capture' }).click();
  await page.getByRole('button', { name: 'Capture a marked moment' }).waitFor({ state: 'visible' });

  await page.getByRole('button', { name: 'Enter annotation mode' }).click();
  await page.getByLabel('Annotation shape').selectOption('circle');
  const metric = await page.locator('.metric-card.featured').boundingBox();
  const canvas = await page.locator('canvas').boundingBox();
  assert.ok(metric && canvas, 'The metric and annotation canvas must be visible.');
  await page.mouse.move(metric.x + metric.width * 0.2, metric.y + metric.height * 0.2);
  await page.mouse.down();
  await page.mouse.move(metric.x + metric.width * 0.8, metric.y + metric.height * 0.8, {
    steps: 5,
  });
  await page.mouse.up();
  await page.getByRole('button', { name: 'Return to interact mode' }).click();

  await page.locator('.metric-card.featured').click();
  await page.locator('#date-range').click();
  await page.locator('#date-range').selectOption('7');
  assert.equal(await page.locator('#retention-value').textContent(), '108%');
  await page.getByRole('button', { name: 'Capture a marked moment' }).click();
  await page.getByRole('button', { name: 'Stop capture' }).click();
  await page.locator('#preview-result').waitFor({ state: 'visible' });

  const manifest = JSON.parse((await page.locator('#manifest-preview').textContent()) ?? '{}');
  assert.ok(
    manifest.timeline.some((event) => event.kind === 'click'),
    'Clicks must be in the timeline.',
  );
  assert.ok(
    manifest.timeline.some((event) => event.kind === 'mark'),
    'Marks must be in the timeline.',
  );
  assert.ok(manifest.annotations.some((annotation) => annotation.kind === 'circle'));
  assert.ok(manifest.targets.some((target) => target.metadata?.id === 'metric.net-retention'));
  assert.ok(manifest.targets.some((target) => target.metadata?.id === 'filter.date-range'));
  assert.equal(
    manifest.keyframes.length,
    0,
    'Denied display capture must not invent screenshot frames.',
  );
  assert.ok(
    manifest.captureWarnings.some((warning) => warning.includes('Visual evidence unavailable')),
  );
  assert.ok(!JSON.stringify(manifest).includes('must-not-be-exported'));
  assert.ok(
    (await page.locator('#summary-preview').textContent()).includes('Visual evidence: unavailable'),
  );
  assert.deepEqual(pageErrors, [], `Unexpected browser errors: ${pageErrors.join(', ')}`);

  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('button', { name: 'Download the capture bundle' }).click(),
  ]);
  const archivePath = await download.path();
  assert.ok(archivePath, 'The ZIP export should produce a downloadable archive.');
  const archive = await readFile(archivePath);
  assert.equal(
    archive.subarray(0, 2).toString(),
    'PK',
    'The exported artifact should be a ZIP file.',
  );

  const iifePage = await context.newPage();
  await iifePage.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await iifePage.addScriptTag({
    path: fileURLToPath(new URL('../packages/sdk/dist/highlite.iife.js', import.meta.url)),
  });
  assert.equal(
    await iifePage.evaluate(() => typeof window.Highlite?.createHighlite),
    'function',
    'The IIFE build should expose the documented global namespace.',
  );
  await iifePage.evaluate(async () => {
    const frameProvider = {
      async start() {},
      async capture() {
        const canvas = document.createElement('canvas');
        canvas.width = 64;
        canvas.height = 40;
        const context = canvas.getContext('2d');
        context.fillStyle = '#5271ff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
      },
      async stop() {},
    };
    const capture = window.Highlite.createHighlite({
      ui: 'headless',
      capture: { microphone: false, frames: 'none', interactions: false },
      frameProvider,
      onComplete: (bundle) => (window.__iifeBundle = bundle),
    });
    await capture.start();
    await capture.mark('IIFE checkpoint');
    await capture.stop();
    await capture.destroy();
  });
  const iifeBundle = await iifePage.evaluate(() => ({
    manifest: window.__iifeBundle.manifest,
    filePaths: Object.keys(window.__iifeBundle.files),
  }));
  assert.equal(iifeBundle.manifest.keyframes.length, 2);
  assert.deepEqual(
    iifeBundle.manifest.keyframes.map((frame) => frame.imagePath),
    ['frames/0001.png', 'frames/0002.png'],
  );
  assert.deepEqual(iifeBundle.filePaths, ['frames/0001.png', 'frames/0002.png']);

  const audioContext = await browser.newContext({
    permissions: ['microphone'],
    viewport: { width: 1440, height: 1000 },
  });
  await audioContext.addInitScript(() => {
    const devices = navigator.mediaDevices;
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: devices.getUserMedia.bind(devices),
        getDisplayMedia: async () => {
          throw new DOMException('Display capture disabled by smoke test.', 'NotAllowedError');
        },
      },
    });
  });
  const audioPage = await audioContext.newPage();
  await audioPage.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await audioPage.getByRole('button', { name: 'Open Highlite capture tools' }).click();
  await audioPage.getByRole('button', { name: 'Start capture' }).click();
  await audioPage.getByRole('status').filter({ hasText: 'Microphone on.' }).waitFor();
  await audioPage.waitForTimeout(1200);
  await audioPage.getByRole('button', { name: 'Stop capture' }).click();
  await audioPage.locator('#preview-result').waitFor({ state: 'visible' });
  const audioManifest = JSON.parse(
    (await audioPage.locator('#manifest-preview').textContent()) ?? '{}',
  );
  assert.ok(
    audioManifest.artifacts.audio,
    'A granted microphone should produce an audio artifact.',
  );
  assert.equal(typeof audioManifest.audioOffsetMs, 'number');
  assert.equal(await audioPage.locator('#audio-status').textContent(), 'Audio included');
  await audioContext.close();

  const pendingContext = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await pendingContext.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: () =>
          new Promise((resolve) => {
            window.__resolveMicrophone = resolve;
          }),
        getDisplayMedia: () =>
          new Promise((_, reject) => {
            window.__rejectDisplay = reject;
          }),
      },
    });
  });
  const cancelPage = await pendingContext.newPage();
  await cancelPage.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await cancelPage.getByRole('button', { name: 'Open Highlite capture tools' }).click();
  await cancelPage.getByRole('button', { name: 'Start capture' }).click();
  await cancelPage.getByRole('button', { name: 'Discard capture' }).waitFor({ state: 'visible' });
  await cancelPage.getByRole('button', { name: 'Discard capture' }).click();
  await cancelPage
    .getByRole('status')
    .filter({ hasText: 'Capture discarded. No bundle was created.' })
    .waitFor();
  assert.equal(await cancelPage.locator('#preview-result').isVisible(), false);
  await cancelPage.evaluate(() => {
    window.__resolveMicrophone({
      getTracks: () => [{ stop: () => (window.__microphoneTrackStopped = true) }],
    });
    window.__rejectDisplay(new DOMException('Cancelled by test.', 'NotAllowedError'));
  });
  await cancelPage.waitForFunction(() => window.__microphoneTrackStopped === true);

  await context.close();
  await pendingContext.close();
  process.stdout.write(
    'Browser smoke passed: ESM/IIFE builds, audio, frames, annotations, interactions, export, and cancel.\n',
  );
} finally {
  await browser?.close();
  await server.close();
}
