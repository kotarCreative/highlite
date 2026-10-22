import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createServer as createHttpServer } from 'node:http';
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
    Object.defineProperty(navigator, 'permissions', {
      configurable: true,
      value: { query: async () => ({ state: 'prompt' }) },
    });
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
  const launcher = page.getByRole('button', { name: 'Open Highlite tools' });
  await launcher.waitFor({ state: 'visible' });
  await launcher.click();
  await page.getByRole('button', { name: 'Start Highlite' }).click();
  assert.ok(
    await page.getByRole('button', { name: 'Freehand annotation' }).isVisible(),
    'Session controls must stay visible while permissions are granted.',
  );
  assert.ok(
    await page.getByRole('button', { name: 'Stop Highlite' }).isVisible(),
    'The Stop control must stay visible while permissions are granted.',
  );
  await page.getByRole('dialog').getByRole('button', { name: 'Allow microphone' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Share this tab' }).click();
  await page
    .getByRole('button', { name: 'Mark a moment in Highlite' })
    .waitFor({ state: 'visible' });
  const dock = page.getByRole('toolbar', { name: 'Highlite session actions' });
  const dockBox = await dock.boundingBox();
  const viewport = page.viewportSize();
  assert.ok(dockBox && viewport, 'The capture session dock must be visible while recording.');
  assert.ok(
    Math.abs(dockBox.x + dockBox.width / 2 - viewport.width / 2) < 2,
    'The capture session dock must be centered horizontally.',
  );
  assert.ok(
    Math.abs(dockBox.y + dockBox.height - (viewport.height - 24)) < 2,
    'The capture session dock must sit above the bottom edge.',
  );
  const stopBox = await page.getByRole('button', { name: 'Stop Highlite' }).boundingBox();
  assert.ok(
    stopBox && Math.abs(dockBox.x + dockBox.width - (stopBox.x + stopBox.width)) < 10,
    'The Stop action must sit at the far right of the dock.',
  );

  const circleTool = page.getByRole('button', { name: 'Circle annotation' });
  assert.equal(await circleTool.getAttribute('aria-keyshortcuts'), 'Control+C');
  await page.keyboard.press('c');
  assert.equal(
    await circleTool.getAttribute('aria-pressed'),
    'false',
    'Session shortcuts must require the Control key.',
  );
  for (const [key, label] of [
    ['f', 'Freehand annotation'],
    ['c', 'Circle annotation'],
    ['a', 'Arrow annotation'],
    ['h', 'Highlight annotation'],
  ]) {
    await page.keyboard.press(`Control+${key}`);
    assert.equal(
      await page.getByRole('button', { name: label }).getAttribute('aria-pressed'),
      'true',
      `The Control+${key.toUpperCase()} shortcut must select the ${label}.`,
    );
  }
  await page.keyboard.press('Control+v');
  assert.equal(
    await circleTool.getAttribute('aria-pressed'),
    'false',
    'The Control+V shortcut must return to interact mode.',
  );

  const tooltipContent = await circleTool.evaluate(
    (element) => getComputedStyle(element, '::after').content,
  );
  assert.ok(
    tooltipContent.includes('drag to outline an area'),
    'Annotation tools must explain what they do in a tooltip.',
  );
  await circleTool.hover();
  await page.waitForTimeout(200);
  assert.equal(
    await circleTool.evaluate((element) => getComputedStyle(element, '::after').opacity),
    '1',
    'The annotation tooltip must appear on hover.',
  );
  await circleTool.click();
  assert.equal(
    await circleTool.getAttribute('aria-pressed'),
    'true',
    'The selected annotation tool must be marked as active.',
  );
  const metric = await page.locator('.metric-card.featured').boundingBox();
  const canvas = await page.locator('canvas').boundingBox();
  assert.ok(metric && canvas, 'The metric and annotation canvas must be visible.');
  await page.mouse.move(metric.x + metric.width * 0.2, metric.y + metric.height * 0.2);
  await page.mouse.down();
  await page.mouse.move(metric.x + metric.width * 0.8, metric.y + metric.height * 0.8, {
    steps: 5,
  });
  await page.mouse.up();
  const countInkPixels = () =>
    page.locator('canvas').evaluate((element) => {
      const context = element.getContext('2d');
      if (!context) return 0;
      const { data } = context.getImageData(0, 0, element.width, element.height);
      let ink = 0;
      for (let index = 3; index < data.length; index += 4) {
        if (data[index] > 0) ink += 1;
      }
      return ink;
    });
  assert.ok((await countInkPixels()) > 0, 'The annotation must be visible when drawn.');
  await page.keyboard.press('Escape');
  assert.equal(
    await circleTool.getAttribute('aria-pressed'),
    'false',
    'Escape must leave annotation mode.',
  );
  await page.waitForTimeout(2_600);
  assert.equal(
    await countInkPixels(),
    0,
    'Annotations must fade off the overlay after two seconds.',
  );

  await page.locator('.metric-card.featured').click();
  await page.locator('#date-range').click();
  await page.locator('#date-range').selectOption('7');
  assert.equal(await page.locator('#retention-value').textContent(), '108%');
  await page.keyboard.press('Control+f');
  assert.equal(
    await page.getByRole('button', { name: 'Freehand annotation' }).getAttribute('aria-pressed'),
    'false',
    'Shortcuts must not fire while typing in a page field.',
  );
  await page.locator('#page-title').click();
  await page.keyboard.press('Control+m');
  await page.keyboard.press('Control+s');
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
  const annotation = manifest.annotations.find((entry) => entry.kind === 'circle');
  assert.ok(annotation, 'The circle annotation must be in the manifest.');
  assert.equal(annotation.strokeWidth, 4, 'Annotations must record their CSS stroke width.');
  assert.equal(annotation.fadeAfterMs, 2_000, 'Annotations must record the fade delay.');
  assert.equal(annotation.fadeDurationMs, 400, 'Annotations must record the fade duration.');
  assert.ok(annotation.points.length >= 2, 'Annotations must keep the drawn points.');
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
    page.getByRole('button', { name: 'Download the Highlite bundle' }).click(),
  ]);
  const archivePath = await download.path();
  assert.ok(archivePath, 'The ZIP export should produce a downloadable archive.');
  const archive = await readFile(archivePath);
  assert.equal(
    archive.subarray(0, 2).toString(),
    'PK',
    'The exported artifact should be a ZIP file.',
  );

  await page.getByRole('button', { name: 'Start Highlite' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Allow microphone' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Share this tab' }).click();
  await page.getByRole('button', { name: 'Stop Highlite' }).waitFor({ state: 'visible' });
  await page.getByRole('button', { name: 'Stop Highlite' }).click();
  await page.waitForFunction((previousSessionId) => {
    const text = document.querySelector('#manifest-preview')?.textContent;
    if (!text) return false;
    try {
      return JSON.parse(text).sessionId !== previousSessionId;
    } catch {
      return false;
    }
  }, manifest.sessionId);
  const secondManifest = JSON.parse(
    (await page.locator('#manifest-preview').textContent()) ?? '{}',
  );
  assert.notEqual(
    secondManifest.sessionId,
    manifest.sessionId,
    'Recording again from the floating tray must start a fresh session.',
  );
  assert.equal(
    secondManifest.timeline.filter((event) => event.kind === 'annotation').length,
    0,
    'A new session must not inherit annotations from the previous one.',
  );
  assert.deepEqual(pageErrors, [], `Unexpected browser errors: ${pageErrors.join(', ')}`);

  const relayRequests = [];
  const relay = createHttpServer(async (request, response) => {
    const origin = request.headers.origin ?? '*';
    const cors = {
      'Access-Control-Allow-Origin': origin,
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    };
    if (request.method === 'OPTIONS') {
      response.writeHead(204, cors);
      response.end();
      return;
    }
    if (request.method !== 'POST' || request.url !== '/v1/sessions') {
      response.writeHead(404, cors);
      response.end();
      return;
    }
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    relayRequests.push({
      authorization: request.headers.authorization,
      contentType: request.headers['content-type'],
      zip: body.subarray(0, 2).toString(),
      bytes: body.length,
    });
    response.writeHead(201, { ...cors, 'Content-Type': 'application/json' });
    response.end(
      JSON.stringify({
        sessionId: `relay-${relayRequests.length}`,
        status: 'ready',
        statusUrl: `/v1/sessions/relay-${relayRequests.length}`,
        bundleUrl: `/v1/sessions/relay-${relayRequests.length}/bundle.zip`,
      }),
    );
  });
  await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve));
  const relayAddress = relay.address();
  assert.ok(relayAddress && typeof relayAddress === 'object');
  const relayEndpoint = `http://127.0.0.1:${relayAddress.port}/v1/sessions`;

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
  await iifePage.evaluate(async (endpoint) => {
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
      relay: { endpoint, token: 'ingest-test' },
      onComplete: (bundle) => (window.__iifeBundles ??= []).push(bundle),
    });
    await capture.start();
    await capture.mark('IIFE first session');
    await capture.stop();
    await capture.start();
    await capture.mark('IIFE second session');
    await capture.stop();
    await capture.destroy();
  }, relayEndpoint);
  const iifeBundles = await iifePage.evaluate(() =>
    (window.__iifeBundles ?? []).map((bundle) => ({
      manifest: bundle.manifest,
      filePaths: Object.keys(bundle.files),
    })),
  );
  assert.equal(iifeBundles.length, 2, 'One controller must support consecutive sessions.');
  assert.notEqual(
    iifeBundles[0].manifest.sessionId,
    iifeBundles[1].manifest.sessionId,
    'Each recording must get a fresh session id.',
  );
  for (const [index, markLabel] of ['IIFE first session', 'IIFE second session'].entries()) {
    const bundle = iifeBundles[index];
    assert.equal(bundle.manifest.keyframes.length, 2);
    assert.deepEqual(
      bundle.manifest.keyframes.map((frame) => frame.imagePath),
      ['frames/0001.png', 'frames/0002.png'],
    );
    assert.deepEqual(bundle.filePaths, ['frames/0001.png', 'frames/0002.png']);
    assert.deepEqual(
      bundle.manifest.timeline
        .filter((event) => event.kind === 'mark')
        .map((event) => event.payload.label),
      [markLabel],
      'Each session must keep only its own timeline events.',
    );
  }

  assert.equal(
    relayRequests.length,
    2,
    'Each completed session must be posted to the configured relay.',
  );
  for (const request of relayRequests) {
    assert.equal(request.authorization, 'Bearer ingest-test');
    assert.equal(request.contentType, 'application/zip');
    assert.equal(request.zip, 'PK', 'The relay must receive a ZIP archive.');
    assert.ok(request.bytes > 0, 'The relay upload must not be empty.');
  }
  await new Promise((resolve) => relay.close(resolve));

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
  await audioPage.getByRole('button', { name: 'Open Highlite tools' }).click();
  await audioPage.getByRole('button', { name: 'Start Highlite' }).click();
  assert.equal(
    await audioPage.getByRole('dialog').getByRole('button', { name: 'Allow microphone' }).count(),
    0,
    'An existing microphone grant must skip its permission step.',
  );
  await audioPage.getByRole('dialog').getByRole('button', { name: 'Share this tab' }).click();
  await audioPage.getByRole('status').filter({ hasText: 'Microphone on.' }).waitFor();
  await audioPage.waitForTimeout(1200);
  await audioPage.getByRole('button', { name: 'Stop Highlite' }).click();
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
    Object.defineProperty(navigator, 'permissions', {
      configurable: true,
      value: { query: async () => ({ state: 'prompt' }) },
    });
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
  await cancelPage.getByRole('button', { name: 'Open Highlite tools' }).click();
  await cancelPage.getByRole('button', { name: 'Start Highlite' }).click();
  await cancelPage.getByRole('dialog').getByRole('button', { name: 'Allow microphone' }).click();
  await cancelPage
    .getByRole('dialog')
    .getByRole('button', { name: 'Cancel Highlite and discard' })
    .click();
  await cancelPage
    .getByRole('status')
    .filter({ hasText: 'Highlite session discarded. No bundle was created.' })
    .waitFor();
  assert.equal(await cancelPage.locator('#preview-result').isVisible(), false);
  await cancelPage.evaluate(() => {
    window.__resolveMicrophone({
      getTracks: () => [{ stop: () => (window.__microphoneTrackStopped = true) }],
    });
  });
  await cancelPage.waitForFunction(() => window.__microphoneTrackStopped === true);

  const discardContext = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await discardContext.addInitScript(() => {
    Object.defineProperty(navigator, 'permissions', {
      configurable: true,
      value: { query: async () => ({ state: 'prompt' }) },
    });
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: async () => {
          throw new DOMException('Permission denied by smoke test.', 'NotAllowedError');
        },
        getDisplayMedia: async () => {
          throw new DOMException('Permission denied by smoke test.', 'NotAllowedError');
        },
      },
    });
  });
  const discardPage = await discardContext.newPage();
  await discardPage.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await discardPage.getByRole('button', { name: 'Open Highlite tools' }).click();
  await discardPage.getByRole('button', { name: 'Start Highlite' }).click();
  await discardPage
    .getByRole('dialog')
    .getByRole('button', { name: 'Continue without audio' })
    .click();
  await discardPage
    .getByRole('dialog')
    .getByRole('button', { name: 'Continue without screenshots' })
    .click();
  await discardPage.getByRole('button', { name: 'Mark a moment in Highlite' }).waitFor();

  const discardDialog = discardPage.getByRole('dialog');
  const discardButton = discardPage.getByRole('button', { name: 'Discard Highlite session' });
  await discardButton.click();
  await discardDialog.getByRole('heading', { name: 'Discard this Highlite session?' }).waitFor();
  await discardDialog.getByRole('button', { name: 'Keep recording' }).click();
  assert.equal(
    await discardDialog.isVisible(),
    false,
    'Keeping the capture must close the discard confirmation.',
  );
  await discardPage.getByRole('button', { name: 'Mark a moment in Highlite' }).waitFor();
  await discardPage.keyboard.press('Control+d');
  await discardDialog.getByRole('heading', { name: 'Discard this Highlite session?' }).waitFor();
  await discardPage.keyboard.press('Escape');
  assert.equal(
    await discardDialog.isVisible(),
    false,
    'Escape must close the discard confirmation.',
  );
  await discardPage.keyboard.press('Control+d');
  await discardDialog.getByRole('heading', { name: 'Discard this Highlite session?' }).waitFor();
  await discardDialog.getByRole('button', { name: 'Discard Highlite session' }).click();
  await discardPage
    .getByRole('status')
    .filter({ hasText: 'Highlite session discarded. No bundle was created.' })
    .waitFor();
  assert.equal(await discardPage.locator('#preview-result').isVisible(), false);
  await discardContext.close();

  await context.close();
  await pendingContext.close();
  process.stdout.write(
    'Browser smoke passed: ESM/IIFE builds, audio, frames, annotations, tooltips, keyboard shortcuts, interactions, export, discard confirmation, and cancel.\n',
  );
} finally {
  await browser?.close();
  await server.close();
}
