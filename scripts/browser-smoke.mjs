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
  const dockColors = await dock.evaluate((element) => {
    const style = getComputedStyle(element);
    return { background: style.backgroundColor, color: style.color };
  });
  assert.deepEqual(dockColors, {
    background: 'rgb(48, 35, 45)',
    color: 'rgb(255, 253, 245)',
  });

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
  const activeToolColors = await page
    .getByRole('button', { name: 'Highlight annotation' })
    .evaluate((element) => {
      const style = getComputedStyle(element);
      return { background: style.backgroundColor, color: style.color };
    });
  assert.deepEqual(activeToolColors, {
    background: 'rgb(239, 255, 61)',
    color: 'rgb(48, 35, 45)',
  });
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
  const selectChange = manifest.timeline.find(
    (event) => event.kind === 'change' && event.payload.fieldKind === 'select',
  );
  assert.ok(selectChange, 'Select changes must be recorded as semantic actions.');
  assert.equal(
    selectChange.payload.valueCaptured,
    false,
    'Field values must stay out of the manifest by default.',
  );
  assert.equal(
    selectChange.payload.optionLabel,
    undefined,
    'Select option labels must not be captured without opt-in.',
  );
  assert.equal(
    manifest.targets.find((target) => target.id === selectChange.targetId)?.label,
    'Date range',
    'A form field target must use its associated label.',
  );
  assert.ok(
    !manifest.timeline.some(
      (event) =>
        event.kind === 'click' &&
        manifest.targets.find((target) => target.id === event.targetId)?.tag === 'select',
    ),
    'A select click must not duplicate the change action.',
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
  assert.ok(
    (await page.locator('#summary-preview').textContent()).includes('Changed selection'),
    'The SDK summary must describe form changes.',
  );
  assert.deepEqual(pageErrors, [], `Unexpected browser errors: ${pageErrors.join(', ')}`);
  assert.equal(
    await page.getByRole('button', { name: 'Download the Highlite bundle' }).count(),
    0,
    'The web client must not expose a ZIP download button.',
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
    window.__iifeCapture = capture;
    await capture.start();
    await capture.mark('IIFE first session');
    await capture.stop();
    await capture.start();
    await capture.mark('IIFE second session');
    await capture.stop();
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

  const [download] = await Promise.all([
    iifePage.waitForEvent('download'),
    iifePage.evaluate(async () => {
      await window.__iifeCapture.export();
    }),
  ]);
  const archivePath = await download.path();
  assert.ok(archivePath, 'The programmatic ZIP export should produce a downloadable archive.');
  const archive = await readFile(archivePath);
  assert.equal(
    archive.subarray(0, 2).toString(),
    'PK',
    'The exported artifact should be a ZIP file.',
  );
  await iifePage.evaluate(() => window.__iifeCapture.destroy());
  await new Promise((resolve) => relay.close(resolve));

  await iifePage.evaluate(async () => {
    const form = document.createElement('form');
    form.id = 'smoke-form';
    form.setAttribute('aria-label', 'Bug report form');
    form.style.cssText =
      'position:fixed;top:0;left:0;z-index:2147483647;background:white;padding:8px;display:flex;flex-direction:column;gap:4px;max-height:100vh;overflow:auto;';
    form.innerHTML = `
      <label for="smoke-search">Search metrics</label>
      <input id="smoke-search" name="query" type="search" />
      <label for="smoke-range">Date range</label>
      <select id="smoke-range" name="range">
        <option value="30">Last 30 days</option>
        <option value="7">Last 7 days</option>
      </select>
      <label for="smoke-tags">Categories</label>
      <select id="smoke-tags" name="tags" multiple>
        <option value="retention">Retention</option>
        <option value="churn">Churn</option>
        <option value="activation">Activation</option>
      </select>
      <label><input id="smoke-archived" type="checkbox" name="archived" /> Include archived</label>
      <label for="smoke-required">Ticket id</label>
      <input id="smoke-required" name="ticket" required />
      <div id="smoke-note" contenteditable="plaintext-only" aria-label="Bug notes"></div>
      <div id="smoke-private-note" contenteditable="plaintext-only" aria-label="Private content"><span data-private>secret-note-value</span></div>
      <div id="smoke-card" aria-label="Order card" style="padding:8px">Order <span data-private>secret-customer-value</span><span hidden>hidden-order-value</span><span style="display:none">css-hidden-order-value</span></div>
      <label for="smoke-password">Password</label>
      <input id="smoke-password" name="password" type="password" autocomplete="current-password" />
      <label for="smoke-otp">Verification code</label>
      <input id="smoke-otp" name="code" autocomplete="one-time-code" />
      <div data-private><label for="smoke-private">Private note</label><input id="smoke-private" name="private-note" /></div>
      <div data-highlite-ignore><label for="smoke-ignored">Ignored note</label><input id="smoke-ignored" name="ignored-note" /></div>
      <button id="smoke-plain" type="button">Plain action</button>
      <button id="smoke-apply" type="submit">Apply <span data-private>secret-submit</span>report</button>
    `;
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      window.__smokeSubmitted = true;
    });
    document.body.prepend(form);

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
      capture: { microphone: false, frames: 'none', interactions: true, formValues: true },
      privacy: { disableSelectors: ['[data-highlite-ignore]'] },
      frameProvider,
    });
    window.__formCapture = capture;
    await capture.start();
  });
  await iifePage.locator('#smoke-search').pressSequentially('retention', { delay: 10 });
  await iifePage.locator('#smoke-range').selectOption('7');
  await iifePage.locator('#smoke-tags').selectOption(['retention', 'churn']);
  await iifePage.locator('#smoke-archived').check();
  await iifePage.locator('#smoke-note').fill('checkout fails');
  await iifePage.locator('#smoke-private-note').click();
  await iifePage.keyboard.type('public');
  await iifePage.locator('#smoke-card').click({ position: { x: 4, y: 4 } });
  await iifePage.locator('#smoke-plain').click();
  await iifePage.locator('#smoke-password').fill('must-not-be-captured');
  await iifePage.locator('#smoke-otp').fill('123456');
  await iifePage.locator('#smoke-private').fill('private-value');
  await iifePage.locator('#smoke-ignored').fill('ignored-value');
  // Native validation blocks this submit, so the click itself must remain in the timeline.
  await iifePage.locator('#smoke-apply').click();
  await iifePage.waitForTimeout(25);
  await iifePage.locator('#smoke-required').fill('HL-42');
  await iifePage.locator('#smoke-apply').click();
  await iifePage.waitForFunction(() => window.__smokeSubmitted === true);
  const formManifest = await iifePage.evaluate(async () => {
    const bundle = await window.__formCapture.stop();
    await window.__formCapture.destroy();
    return bundle.manifest;
  });

  const formEvent = (kind, label) =>
    formManifest.timeline.find(
      (event) =>
        event.kind === kind &&
        formManifest.targets.find((target) => target.id === event.targetId)?.label === label,
    );
  const inputEvent = formEvent('input', 'Search metrics');
  assert.ok(inputEvent, 'Opt-in text activity must be captured as one coalesced event.');
  assert.equal(inputEvent.payload.valueCaptured, true);
  assert.equal(inputEvent.payload.value, 'retention');
  assert.equal(
    formManifest.timeline.filter(
      (event) => event.kind === 'input' && event.targetId === inputEvent.targetId,
    ).length,
    1,
    'Typing must be coalesced, not recorded per keystroke.',
  );
  const rangeEvent = formEvent('change', 'Date range');
  assert.ok(rangeEvent, 'Select changes must be captured.');
  assert.equal(rangeEvent.payload.optionLabel, 'Last 7 days');
  const categoriesEvent = formEvent('change', 'Categories');
  assert.ok(categoriesEvent, 'Multiple-select changes must be captured.');
  assert.deepEqual(categoriesEvent.payload.optionLabels, ['Retention', 'Churn']);
  assert.equal(
    categoriesEvent.payload.optionLabel,
    undefined,
    'A multiple select must report all selections rather than one scalar label.',
  );
  const archivedEvent = formEvent('change', 'Include archived');
  assert.ok(archivedEvent, 'Checkbox changes must be captured.');
  assert.equal(archivedEvent.payload.checked, true);
  const noteEvent = formEvent('input', 'Bug notes');
  assert.ok(noteEvent, 'A plaintext-only contenteditable must be captured as a field.');
  assert.equal(noteEvent.payload.value, 'checkout fails');
  assert.equal(
    noteEvent.payload.valueCaptured,
    true,
    'Opt-in values must apply to supported contenteditable fields.',
  );
  const noteTarget = formManifest.targets.find((target) => target.id === noteEvent.targetId);
  assert.equal(
    noteTarget?.textExcerpt,
    undefined,
    'A contenteditable value must not also become a target excerpt.',
  );
  const privateNoteEvent = formEvent('input', 'Private content');
  assert.ok(privateNoteEvent, 'A contenteditable containing private content must keep its action.');
  assert.equal(
    privateNoteEvent.payload.valueCaptured,
    false,
    'A rich-text field containing a private region must not capture its value.',
  );
  assert.equal(privateNoteEvent.payload.value, undefined);
  const cardClick = formManifest.timeline.find(
    (event) =>
      event.kind === 'click' &&
      formManifest.targets.find((target) => target.id === event.targetId)?.label === 'Order card',
  );
  assert.ok(cardClick, 'A click target must keep its accessible label.');
  const cardTarget = formManifest.targets.find((target) => target.id === cardClick.targetId);
  assert.equal(
    cardTarget?.textExcerpt,
    'Order',
    'Private and hidden descendants must not enter a target excerpt.',
  );
  const plainButtonClick = formManifest.timeline.find(
    (event) =>
      event.kind === 'click' &&
      formManifest.targets.find((target) => target.id === event.targetId)?.label === 'Plain action',
  );
  assert.ok(
    plainButtonClick,
    'A non-submit button must keep its click rather than being treated as a field.',
  );
  const submitEvent = formEvent('submit', 'Bug report form');
  assert.ok(submitEvent, 'Form submits must be captured.');
  assert.equal(submitEvent.payload.submitterLabel, 'Apply report');
  assert.equal(
    formManifest.targets.find((target) => target.id === submitEvent.targetId)?.textExcerpt,
    undefined,
    'A form target must use its label, not an excerpt of its fields.',
  );
  const failedSubmitClick = formManifest.timeline.find(
    (event) =>
      event.kind === 'click' &&
      formManifest.targets.find((target) => target.id === event.targetId)?.label === 'Apply report',
  );
  assert.ok(
    failedSubmitClick,
    'A submit click blocked by native validation must still be captured.',
  );
  assert.equal(
    formManifest.timeline.filter(
      (event) =>
        event.kind === 'click' &&
        formManifest.targets.find((target) => target.id === event.targetId)?.label ===
          'Apply report',
    ).length,
    1,
    'A successful submit must consume its own click instead of recording a duplicate.',
  );
  assert.equal(
    formManifest.timeline.filter((event) => event.kind === 'submit').length,
    1,
    'A submit click must not duplicate the submit action.',
  );
  assert.ok(
    !formManifest.timeline.some(
      (event) =>
        event.kind === 'input' &&
        event.targetId === inputEvent.targetId &&
        event.payload.value === 'must-not-be-captured',
    ),
    'Password values must never be captured.',
  );
  for (const selector of ['#smoke-password', '#smoke-otp', '#smoke-private', '#smoke-ignored']) {
    assert.ok(
      !formManifest.targets.some((target) => target.selector === selector),
      `Excluded field ${selector} must not create a target.`,
    );
  }
  assert.ok(
    !JSON.stringify(formManifest).includes('must-not-be-captured'),
    'Password values must not leak into the manifest.',
  );
  assert.ok(
    !JSON.stringify(formManifest).includes('private-value') &&
      !JSON.stringify(formManifest).includes('ignored-value'),
    'Private and disabled fields must not leak values.',
  );
  assert.ok(
    !JSON.stringify(formManifest).includes('secret-customer-value') &&
      !JSON.stringify(formManifest).includes('hidden-order-value') &&
      !JSON.stringify(formManifest).includes('css-hidden-order-value') &&
      !JSON.stringify(formManifest).includes('secret-note-value') &&
      !JSON.stringify(formManifest).includes('secret-submit'),
    'Private and hidden descendants must not leak through an ancestor target, field value, or submitter label.',
  );
  const submitKeyframe = formManifest.keyframes.find((frame) =>
    frame.eventIds?.includes(submitEvent.id),
  );
  assert.ok(submitKeyframe, 'A frame captured for a submit must carry an exact event link.');

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
    'Browser smoke passed: ESM/IIFE builds, audio, frames, annotations, tooltips, keyboard shortcuts, interactions, programmatic ZIP export, discard confirmation, and cancel.\n',
  );
} finally {
  await browser?.close();
  await server.close();
}
