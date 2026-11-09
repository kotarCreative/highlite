import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer as httpServer } from 'node:http';
import { createRequire } from 'node:module';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { chromium } from 'playwright-core';

const require = createRequire(new URL('../packages/sdk/package.json', import.meta.url));
const JSZip = require('jszip');
const exec = promisify(execFile);
const root = await mkdtemp(
  join(existsSync('/tmp/opencode') ? '/tmp/opencode' : tmpdir(), 'highlite-recipes-'),
);
const configDir = join(root, 'config');
const binary = fileURLToPath(
  new URL(
    `../target/debug/highlite-relay${process.platform === 'win32' ? '.exe' : ''}`,
    import.meta.url,
  ),
);
let relay;
let browser;
let aiCalls = 0;
const issues = [];
let metadataFailure = false;
let connectionDelay = 0;
let issueTypeDelay = 0;
let issueTypeDelayProject = '';
let issueTypeFailure = false;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const remote = httpServer(async (request, response) => {
  if (request.method === 'GET') {
    response.setHeader('Content-Type', 'application/json');
    if (
      metadataFailure ||
      request.headers.authorization !==
        `Basic ${Buffer.from('tester@example.com:jira-smoke-secret').toString('base64')}`
    ) {
      response.statusCode = 401;
      response.end(JSON.stringify({ error: 'jira-smoke-secret must never be echoed' }));
      return;
    }
    const url = new URL(request.url, 'http://localhost');
    const issueTypes = url.pathname.startsWith('/rest/api/3/issue/createmeta/');
    if (!issueTypes && connectionDelay) await delay(connectionDelay);
    if (
      issueTypes &&
      issueTypeDelay &&
      (!issueTypeDelayProject || url.pathname.includes(`/createmeta/${issueTypeDelayProject}/`))
    )
      await delay(issueTypeDelay);
    if (issueTypes && issueTypeFailure) {
      response.statusCode = 502;
      response.end(JSON.stringify({ error: 'temporary Jira metadata failure' }));
      return;
    }
    if (url.pathname === '/rest/api/3/myself')
      response.end(
        JSON.stringify({ accountId: 'tester', active: true, displayName: 'Alex at Highlite' }),
      );
    else if (url.pathname === '/rest/api/3/project/search')
      response.end(
        JSON.stringify({
          isLast: true,
          values: [
            { key: 'TEAM', name: 'Product experience' },
            { key: 'WEB', name: 'Website' },
          ],
        }),
      );
    else if (url.pathname === '/rest/api/3/issue/createmeta/TEAM/issuetypes')
      response.end(
        JSON.stringify({
          total: 3,
          issueTypes: [
            { id: '10001', name: 'Bug', subtask: false },
            { id: '10002', name: 'Task', subtask: false },
            { id: '10003', name: 'Subtask', subtask: true },
          ],
        }),
      );
    else if (url.pathname === '/rest/api/3/issue/createmeta/WEB/issuetypes')
      response.end(
        JSON.stringify({ total: 1, issueTypes: [{ id: '10004', name: 'Story', subtask: false }] }),
      );
    else {
      response.statusCode = 404;
      response.end('{}');
    }
    return;
  }
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const input = JSON.parse(Buffer.concat(chunks).toString());
  response.setHeader('Content-Type', 'application/json');
  if (request.url === '/v1/chat/completions') {
    aiCalls += 1;
    assert.ok(input.messages[0].content.includes('Focus on usability defects'));
    assert.ok(!JSON.stringify(input).includes('jira-smoke-secret'));
    response.end(
      JSON.stringify({
        choices: [
          {
            finish_reason: 'stop',
            message: {
              content: JSON.stringify({
                summary: 'Captured usability defect',
                description:
                  'Observed: the action failed.\nEvidence: captured narration.\nExpected behavior is not evidenced.',
              }),
            },
          },
        ],
      }),
    );
  } else {
    assert.equal(request.url, '/rest/api/3/issue');
    assert.equal(
      request.headers.authorization,
      `Basic ${Buffer.from('tester@example.com:jira-smoke-secret').toString('base64')}`,
    );
    issues.push(input);
    response.statusCode = 201;
    response.end(JSON.stringify({ id: String(issues.length), key: `TEAM-${issues.length}` }));
  }
});

try {
  await new Promise((resolve) => remote.listen(0, '127.0.0.1', resolve));
  const remoteUrl = `http://127.0.0.1:${remote.address().port}`;
  const reserve = createServer();
  await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
  const address = `127.0.0.1:${reserve.address().port}`;
  await new Promise((resolve) => reserve.close(resolve));
  await exec(binary, [
    'providers',
    'connect',
    'local',
    '--kind',
    'openai-compatible',
    '--model',
    'test-model',
    '--base-url',
    `${remoteUrl}/v1`,
    '--no-api-key',
    '--config-dir',
    configDir,
  ]);
  relay = spawn(
    binary,
    ['--bind', address, '--data-dir', join(root, 'data'), '--config-dir', configDir, '--ui'],
    {
      env: {
        ...Object.fromEntries(
          Object.entries(process.env).filter(
            ([name]) => !name.startsWith('HIGHLITE_RELAY_') && name !== 'HIGHLITE_ASR_COMMAND',
          ),
        ),
        HIGHLITE_RELAY_INGEST_TOKEN: 'smoke-ingest',
        HIGHLITE_RELAY_READ_TOKEN: 'smoke-read',
        HIGHLITE_RELAY_ALLOWED_HOSTS: address,
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    },
  );
  await new Promise((resolve, reject) => {
    let diagnostics = '';
    const timer = setTimeout(() => reject(new Error('Relay startup timed out')), 15000);
    relay.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    relay.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Relay exited: ${code}\n${diagnostics}`));
    });
    relay.stderr.on('data', (chunk) => {
      diagnostics += chunk.toString();
      if (diagnostics.includes('listening on')) {
        clearTimeout(timer);
        resolve();
      }
    });
  });
  browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH ?? '/usr/bin/chromium',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
  const errors = [];
  const recipePosts = [];
  const screenshotDir = process.env.HIGHLITE_UI_SCREENSHOT_DIR;
  if (screenshotDir) await mkdir(screenshotDir, { recursive: true });
  async function checkpoint(name) {
    if (screenshotDir)
      await page.screenshot({
        path: join(screenshotDir, `${name}.png`),
        fullPage: true,
        animations: 'disabled',
      });
  }
  page.on('request', (request) => {
    if (request.method() === 'POST' && new URL(request.url()).pathname === '/v1/recipes/jira-issue')
      recipePosts.push(request.url());
  });
  page.on('pageerror', (error) => errors.push(error.message));
  async function assertView(target, view) {
    await target.waitForFunction(
      (name) =>
        location.hash === `#${name}` &&
        document.querySelector(`[data-app-view="${name}"]`)?.hidden === false &&
        document.querySelector(`nav a[href="#${name}"]`)?.getAttribute('aria-current') === 'page',
      view,
    );
    assert.equal(new URL(target.url()).hash, `#${view}`);
    assert.equal(await target.locator('[data-app-view]:visible').count(), 1);
    assert.equal(await target.locator(`[data-app-view="${view}"]`).isVisible(), true);
    assert.equal(await target.locator(`nav a[href="#${view}"][aria-current="page"]`).count(), 1);
  }
  async function openRecipes(target = page) {
    await target.getByRole('link', { name: 'Recipes', exact: true }).click();
    await assertView(target, 'recipes');
    await target.waitForFunction(() => !document.getElementById('recipe-config-form').inert);
  }
  async function openSessions(target = page) {
    await target.getByRole('link', { name: 'Sessions', exact: true }).click();
    await assertView(target, 'sessions');
  }
  async function openProviders(target = page) {
    await target.getByRole('link', { name: 'Providers', exact: true }).click();
    await assertView(target, 'providers');
  }
  async function isolatedPage() {
    const isolated = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
    isolated.on('pageerror', (error) => errors.push(error.message));
    await isolated.goto(`http://${address}/#token=smoke-read`);
    return isolated;
  }
  await page.goto(`http://${address}/#token=smoke-read`);
  await page.getByRole('link', { name: 'Sessions', exact: true }).waitFor();
  await assertView(page, 'sessions');
  assert.ok(!page.url().includes('smoke-read'));
  await openRecipes();
  const wizardSteps = page.locator('[data-wizard-step]');
  assert.equal(await wizardSteps.count(), 4);
  await page.getByRole('heading', { name: 'Connect Jira', exact: true }).waitFor();
  assert.equal(await wizardSteps.filter({ visible: true }).count(), 1);
  await checkpoint('recipe-setup-connect');
  const postCountBeforeValidation = recipePosts.length;
  const site = page.getByLabel('Jira site URL');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  assert.equal(
    await page.getByRole('heading', { name: 'Connect Jira', exact: true }).isVisible(),
    true,
  );
  assert.ok(await site.evaluate((node) => node === document.activeElement));
  assert.equal(recipePosts.length, postCountBeforeValidation);
  await site.fill(remoteUrl);
  await page.getByLabel('Jira account email').fill('tester@example.com');
  await page.getByLabel('Jira API token').fill('jira-smoke-secret');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByText('Test the connection before continuing.', { exact: true }).waitFor();
  metadataFailure = true;
  await page.getByRole('button', { name: 'Test connection', exact: true }).click();
  await page.getByText(/Jira rejected the credentials/).waitFor();
  assert.ok(!(await page.locator('body').innerText()).includes('jira-smoke-secret'));
  metadataFailure = false;
  await page.getByRole('button', { name: 'Test connection', exact: true }).click();
  await page.getByText(/Connected as Alex at Highlite/).waitFor();
  await checkpoint('recipe-setup-connections');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('heading', { name: 'Choose a destination', exact: true }).waitFor();
  await page.getByLabel('Jira project', { exact: true }).selectOption('TEAM');
  await page.getByLabel('Issue type', { exact: true }).selectOption({ label: 'Bug' });
  assert.equal(await page.getByLabel('Issue type', { exact: true }).locator('option').count(), 3);
  await checkpoint('recipe-setup-destination');
  assert.equal(recipePosts.length, postCountBeforeValidation);
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await page.getByRole('heading', { name: 'Connect Jira', exact: true }).waitFor();
  assert.equal(await site.inputValue(), remoteUrl);
  assert.equal(await page.getByLabel('Jira project', { exact: true }).inputValue(), 'TEAM');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByLabel('Jira project', { exact: true }).selectOption('WEB');
  await page.getByLabel('Issue type', { exact: true }).selectOption({ label: 'Story' });
  await page.getByLabel('Jira project', { exact: true }).selectOption('TEAM');
  assert.equal(await page.getByLabel('Issue type', { exact: true }).inputValue(), '');
  await page.getByLabel('Issue type', { exact: true }).selectOption({ label: 'Bug' });
  const advanced = page.locator('#advanced-fields');
  await advanced.locator('summary').click();
  const jsonField = advanced.locator('textarea');
  await jsonField.fill('{invalid json');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('heading', { name: 'Customize instructions', exact: true }).waitFor();
  await page
    .getByLabel('Custom analysis prompt')
    .fill('Focus on usability defects and preserve evidence references.');
  await page
    .locator('#recipe-provider-summary')
    .filter({ hasText: /local.*test-model/ })
    .waitFor();
  await checkpoint('recipe-setup-instructions');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('heading', { name: 'Review & activate', exact: true }).waitFor();
  assert.equal(await wizardSteps.filter({ visible: true }).count(), 1);
  await page
    .locator('#recipe-review-provider')
    .filter({ hasText: /local.*test-model/ })
    .waitFor();
  await checkpoint('recipe-setup-review');
  assert.equal(await page.getByLabel('After drafting').inputValue(), 'review');
  const autoDraft = page.getByLabel('Automatically draft new sessions');
  assert.equal(await autoDraft.isChecked(), false);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkpoint('recipe-setup-mobile-review');
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.setViewportSize({ width: 1280, height: 1000 });
  await page.getByLabel('Enable this recipe').check();
  await autoDraft.check();

  // Required fields in an earlier, hidden step must still block final submission.
  const project = page.getByLabel('Jira project', { exact: true });
  await project.evaluate((node) => {
    node.value = '';
    node.dispatchEvent(new Event('input', { bubbles: true }));
    node.dispatchEvent(new Event('change', { bubbles: true }));
  });
  const beforeHiddenRequired = recipePosts.length;
  await page.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await page.getByRole('heading', { name: 'Choose a destination', exact: true }).waitFor();
  assert.ok(await project.evaluate((node) => node === document.activeElement));
  assert.equal(recipePosts.length, beforeHiddenRequired);
  await project.selectOption('TEAM');
  await page.getByLabel('Issue type', { exact: true }).selectOption('10001');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('heading', { name: 'Review & activate', exact: true }).waitFor();

  const beforeInvalidJson = recipePosts.length;
  await page.getByRole('button', { name: 'Save recipe', exact: true }).click();
  assert.equal(recipePosts.length, beforeInvalidJson);
  assert.ok(await jsonField.evaluate((node) => node === document.activeElement));
  await jsonField.fill('{}');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  const reviewPosts = recipePosts.length;
  const saveRequest = page.waitForRequest(
    (request) =>
      request.method() === 'POST' && new URL(request.url()).pathname === '/v1/recipes/jira-issue',
  );
  await page.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await saveRequest;
  assert.equal(recipePosts.length, reviewPosts + 1);
  await page.getByText('Recipe saved.', { exact: false }).waitFor();
  assert.equal(await page.getByLabel('Jira API token').inputValue(), '');
  const fixture = JSON.parse(
    await readFile(new URL('../fixtures/capture.json', import.meta.url), 'utf8'),
  );
  async function uploadSession(sessionId) {
    const manifest = { ...fixture.manifest, sessionId, keyframes: [] };
    const zip = new JSZip();
    zip.file('manifest.json', JSON.stringify(manifest));
    const response = await fetch(`http://${address}/v1/sessions`, {
      method: 'POST',
      headers: { Authorization: 'Bearer smoke-ingest', 'Content-Type': 'application/zip' },
      body: await zip.generateAsync({ type: 'nodebuffer' }),
    });
    assert.equal(response.status, 201, await response.text());
  }
  await uploadSession('jira-browser-smoke');
  await openSessions();
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await page.locator('.session[data-id="jira-browser-smoke"]').click();
  await page.getByText('Jira recipe: draft', { exact: true }).waitFor();
  assert.equal(aiCalls, 1);
  assert.equal(issues.length, 0);
  await page.getByLabel('Issue summary', { exact: true }).fill('Reviewed usability defect');
  assert.equal(
    await page.getByRole('button', { name: 'Publish to Jira', exact: true }).isDisabled(),
    true,
  );
  await page.getByRole('button', { name: 'Save draft changes', exact: true }).click();
  await page.waitForFunction(() => !document.getElementById('recipe-publish').disabled);
  page.once('dialog', (dialog) => dialog.accept());
  await page.getByRole('button', { name: 'Publish to Jira', exact: true }).click();
  await page.getByRole('link', { name: 'Open TEAM-1 in Jira', exact: true }).waitFor();
  assert.equal(issues.length, 1);
  assert.equal(issues[0].fields.summary, 'Reviewed usability defect');
  assert.equal(issues[0].fields.description.type, 'doc');
  assert.equal(issues[0].fields.project.key, 'TEAM');
  const storage = await page.evaluate(() =>
    JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }),
  );
  assert.ok(!storage.includes('jira-smoke-secret'));
  assert.ok(!(await page.locator('body').innerText()).includes('jira-smoke-secret'));
  await page.reload();
  await page.locator('.session[data-id="jira-browser-smoke"]').click();
  await page.getByRole('link', { name: 'Open TEAM-1 in Jira', exact: true }).waitFor();
  assert.equal(aiCalls, 1);
  assert.equal(issues.length, 1);
  await openRecipes();
  await checkpoint('recipe-edit-desktop');
  await page.getByRole('heading', { name: 'Connect Jira', exact: true }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Continue', exact: true }).count(), 1);
  assert.equal(await wizardSteps.filter({ visible: true }).count(), 1);
  assert.equal(await page.getByLabel('Jira API token').inputValue(), '');
  assert.equal(await page.getByLabel('Jira site URL').inputValue(), remoteUrl);
  const email = page.getByLabel('Jira account email');
  const token = page.getByLabel('Jira API token');
  await email.fill('changed@example.com');
  assert.equal(await token.evaluate((node) => node.required), true);
  await email.fill('tester@example.com');
  assert.equal(await token.evaluate((node) => node.required), false);
  // Saved credentials can be tested without retrieving them or entering them again.
  await page.getByRole('button', { name: 'Test connection', exact: true }).click();
  await page.getByText(/Connected as Alex at Highlite/).waitFor();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.waitForFunction(() => document.getElementById('jira-issue-type').value === '10001');
  assert.equal(await page.getByLabel('Jira project', { exact: true }).inputValue(), 'TEAM');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByLabel('After drafting').selectOption('automatic');
  await page.locator('#recipe-auto-publish-warning').waitFor({ state: 'visible' });
  assert.equal(await page.getByLabel('Jira API token').inputValue(), '');
  await openSessions();
  await openRecipes();
  await assertView(page, 'recipes');
  assert.equal(await page.getByLabel('After drafting').inputValue(), 'automatic');
  assert.equal(await page.getByLabel('Jira site URL').inputValue(), remoteUrl);
  await page.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await page
    .locator('#recipe-config-message')
    .filter({ hasText: /Recipe saved\./ })
    .waitFor();
  await page
    .locator('#recipe-review-outcome')
    .filter({ hasText: /automatically/i })
    .waitFor();
  const savedResponse = await fetch(`http://${address}/v1/recipes/jira-issue`, {
    headers: { Authorization: 'Bearer smoke-read' },
  });
  assert.equal(savedResponse.status, 200);
  const saved = (await savedResponse.json()).recipe.settings;
  assert.equal(saved.publishMode, 'automatic');
  assert.equal(saved.autoDraft, true);
  assert.equal(saved.enabled, true);
  assert.equal(await page.getByLabel('After drafting').inputValue(), 'automatic');
  await page.waitForFunction(() => !document.getElementById('recipe-config-form').inert);
  await checkpoint('recipe-edit-after-save');
  await uploadSession('jira-auto-smoke');
  await openSessions();
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await page.locator('.session[data-id="jira-auto-smoke"]').click();
  await page.getByText('Jira recipe: published', { exact: true }).waitFor();
  await page.getByRole('link', { name: 'Open TEAM-2 in Jira', exact: true }).waitFor();
  assert.equal(aiCalls, 2);
  assert.equal(issues.length, 2);
  assert.equal(issues[1].fields.summary, 'Captured usability defect');
  await openRecipes();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('heading', { name: 'Review & activate', exact: true }).waitFor();
  await checkpoint('recipe-edit-mobile');
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await openProviders();
  await checkpoint('providers-mobile');
  await openSessions();
  await checkpoint('sessions-mobile');
  await page.setViewportSize({ width: 1280, height: 1000 });
  await checkpoint('sessions-desktop');
  await openProviders();
  await checkpoint('providers-desktop');

  const disabledPage = await isolatedPage();
  await disabledPage.route('**/v1/recipes/jira-issue', (route) =>
    route.fulfill({
      json: { managementEnabled: false, recipe: { settings: null, hasApiToken: false } },
    }),
  );
  await openRecipes(disabledPage);
  await disabledPage.locator('#recipe-config-disabled').waitFor({ state: 'visible' });
  assert.equal(
    await disabledPage
      .locator('#recipe-config-form')
      .isVisible()
      .catch(() => false),
    false,
  );
  assert.equal(
    await disabledPage.getByRole('button', { name: 'Save recipe', exact: true }).count(),
    0,
  );
  await disabledPage.close();

  const retryPage = await isolatedPage();
  let recipeGetFails = true;
  await retryPage.route('**/v1/recipes/jira-issue', (route) =>
    recipeGetFails
      ? route.fulfill({ status: 500, json: { error: 'unavailable' } })
      : route.fulfill({
          json: { managementEnabled: true, recipe: { settings: null, hasApiToken: false } },
        }),
  );
  await openRecipes(retryPage);
  await retryPage.locator('#recipe-config-retry').waitFor({ state: 'visible' });
  assert.equal(
    await retryPage
      .locator('#recipe-config-form')
      .isVisible()
      .catch(() => false),
    false,
  );
  assert.equal(
    await retryPage.getByRole('button', { name: 'Save recipe', exact: true }).count(),
    0,
  );
  recipeGetFails = false;
  await retryPage.getByRole('button', { name: 'Retry loading settings', exact: true }).click();
  await retryPage.getByRole('heading', { name: 'Connect Jira', exact: true }).waitFor();
  assert.equal(await retryPage.locator('#recipe-config-form').isVisible(), true);
  await retryPage.close();

  // Editing connection fields while a test is in flight must discard the late
  // success, and late issue-type responses must not overwrite a newer project.
  const racePage = await isolatedPage();
  await racePage.route('**/v1/recipes/jira-issue', (route) =>
    route.request().method() === 'GET'
      ? route.fulfill({
          json: { managementEnabled: true, recipe: { settings: null, hasApiToken: false } },
        })
      : route.continue(),
  );
  await openRecipes(racePage);
  await racePage.getByLabel('Jira site URL').fill(remoteUrl);
  await racePage.getByLabel('Jira account email').fill('tester@example.com');
  await racePage.getByLabel('Jira API token').fill('jira-smoke-secret');
  connectionDelay = 500;
  await racePage.getByRole('button', { name: 'Test connection', exact: true }).click();
  await racePage.getByRole('button', { name: 'Checking Jira…', exact: true }).waitFor();
  await racePage.getByLabel('Jira account email').fill('changed@example.com');
  await racePage
    .getByText('Test your connection to load projects from Jira.', { exact: true })
    .waitFor();
  await delay(700);
  assert.equal(await racePage.getByText(/Connected as/).count(), 0);
  assert.equal(
    await racePage.getByLabel('Jira project', { exact: true }).locator('option').count(),
    1,
  );
  assert.equal(await racePage.getByLabel('Jira project', { exact: true }).inputValue(), '');
  connectionDelay = 0;
  await racePage.getByLabel('Jira account email').fill('tester@example.com');
  await racePage.getByRole('button', { name: 'Test connection', exact: true }).click();
  await racePage.getByText(/Connected as Alex at Highlite/).waitFor();
  assert.equal(
    await racePage.getByLabel('Jira project', { exact: true }).locator('option').count(),
    3,
  );
  await racePage.getByRole('button', { name: 'Continue', exact: true }).click();
  await racePage.getByRole('heading', { name: 'Choose a destination', exact: true }).waitFor();
  issueTypeDelay = 500;
  issueTypeDelayProject = 'WEB';
  await racePage.getByLabel('Jira project', { exact: true }).selectOption('WEB');
  await racePage.getByLabel('Jira project', { exact: true }).selectOption('TEAM');
  await racePage.getByLabel('Issue type', { exact: true }).selectOption({ label: 'Bug' });
  await delay(700);
  assert.deepEqual(
    await racePage.getByLabel('Issue type', { exact: true }).locator('option').allTextContents(),
    ['Choose an issue type', 'Bug', 'Task'],
  );
  issueTypeDelay = 0;
  issueTypeDelayProject = '';
  issueTypeFailure = true;
  await racePage.getByLabel('Jira project', { exact: true }).selectOption('WEB');
  await racePage.getByText('Jira returned HTTP 502. Try again later.', { exact: true }).waitFor();
  issueTypeFailure = false;
  await racePage.getByRole('button', { name: 'Retry issue types', exact: true }).click();
  await racePage.getByLabel('Issue type', { exact: true }).selectOption({ label: 'Story' });
  assert.equal(await racePage.getByLabel('Issue type', { exact: true }).inputValue(), '10004');
  await racePage.getByRole('button', { name: 'Back', exact: true }).click();
  await racePage.getByRole('heading', { name: 'Connect Jira', exact: true }).waitFor();
  await racePage.getByLabel('Jira account email').fill('changed@example.com');
  assert.equal(
    await racePage.getByLabel('Jira project', { exact: true }).locator('option').count(),
    1,
  );
  assert.equal(
    await racePage.getByLabel('Issue type', { exact: true }).locator('option').count(),
    1,
  );
  assert.equal(
    await racePage.locator('#jira-connection-status').textContent(),
    'Test your connection to load projects from Jira.',
  );
  await racePage.close();

  // A failed save with a newly entered token must not leave the connection
  // verified: the token field was cleared and nothing was persisted.
  const saveFailurePage = await isolatedPage();
  await saveFailurePage.route('**/v1/recipes/jira-issue', (route) =>
    route.request().method() === 'POST'
      ? route.fulfill({ status: 500, json: { error: 'Could not save recipe settings.' } })
      : route.fulfill({
          json: { managementEnabled: true, recipe: { settings: null, hasApiToken: false } },
        }),
  );
  await openRecipes(saveFailurePage);
  await saveFailurePage.getByLabel('Jira site URL').fill(remoteUrl);
  await saveFailurePage.getByLabel('Jira account email').fill('tester@example.com');
  await saveFailurePage.getByLabel('Jira API token').fill('jira-smoke-secret');
  await saveFailurePage.getByRole('button', { name: 'Test connection', exact: true }).click();
  await saveFailurePage.getByText(/Connected as Alex at Highlite/).waitFor();
  await saveFailurePage.getByRole('button', { name: 'Continue', exact: true }).click();
  await saveFailurePage.getByLabel('Jira project', { exact: true }).selectOption('TEAM');
  await saveFailurePage.getByLabel('Issue type', { exact: true }).selectOption({ label: 'Bug' });
  await saveFailurePage.getByRole('button', { name: 'Continue', exact: true }).click();
  await saveFailurePage
    .getByRole('heading', { name: 'Customize instructions', exact: true })
    .waitFor();
  await saveFailurePage
    .getByLabel('Custom analysis prompt')
    .fill('Focus on usability defects and preserve evidence references.');
  await saveFailurePage.getByRole('button', { name: 'Continue', exact: true }).click();
  await saveFailurePage.getByRole('heading', { name: 'Review & activate', exact: true }).waitFor();
  await saveFailurePage.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await saveFailurePage
    .getByText('Could not save recipe settings. Test the connection again before saving.', {
      exact: true,
    })
    .waitFor();
  assert.equal(await saveFailurePage.getByLabel('Jira API token').inputValue(), '');
  assert.equal(
    await saveFailurePage.getByLabel('Jira project', { exact: true }).locator('option').count(),
    1,
  );
  assert.equal(
    await saveFailurePage.locator('#jira-connection-status').textContent(),
    'Test your connection to load projects from Jira.',
  );
  assert.equal(
    await saveFailurePage.locator('#recipe-review-destination').textContent(),
    `Project not set · Issue type not set — ${remoteUrl}`,
  );
  await saveFailurePage.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await saveFailurePage.getByRole('heading', { name: 'Connect Jira', exact: true }).waitFor();
  await saveFailurePage
    .getByText('Test the connection before continuing.', { exact: true })
    .waitFor();
  assert.ok(
    await saveFailurePage
      .getByRole('button', { name: 'Test connection', exact: true })
      .evaluate((node) => node === document.activeElement),
  );
  await saveFailurePage.close();

  const providerPage = await isolatedPage();
  await providerPage.route('**/v1/recipes/jira-issue', (route) =>
    route.fulfill({
      json: { managementEnabled: true, recipe: { settings: null, hasApiToken: false } },
    }),
  );
  await providerPage.route('**/v1/providers', (route) =>
    route.fulfill({ json: { enabled: true, providers: [], defaultProvider: null } }),
  );
  await openRecipes(providerPage);
  await providerPage.getByLabel('Jira site URL').fill(remoteUrl);
  await providerPage.getByLabel('Jira account email').fill('tester@example.com');
  await providerPage.getByLabel('Jira API token').fill('jira-smoke-secret');
  await providerPage.getByRole('button', { name: 'Test connection', exact: true }).click();
  await providerPage.getByText(/Connected as Alex at Highlite/).waitFor();
  await providerPage.getByRole('button', { name: 'Continue', exact: true }).click();
  await providerPage.getByLabel('Jira project', { exact: true }).selectOption('TEAM');
  await providerPage.getByLabel('Issue type', { exact: true }).selectOption('10001');
  await providerPage.getByRole('button', { name: 'Continue', exact: true }).click();
  await providerPage
    .getByRole('heading', { name: 'Customize instructions', exact: true })
    .waitFor();
  await providerPage
    .locator('#recipe-provider-summary')
    .filter({ hasText: /No default AI provider/i })
    .waitFor();
  assert.equal(await providerPage.locator('#recipes-panel .session').count(), 0);
  const providersAction = providerPage
    .locator('#recipes-panel')
    .getByRole('link', { name: 'Open Providers', exact: true });
  await providersAction.waitFor({ state: 'visible' });
  await providersAction.click();
  await assertView(providerPage, 'providers');
  assert.equal(await providerPage.locator('#providers-panel #recipes-panel').count(), 0);
  assert.equal(await providerPage.locator('#providers-panel .session').count(), 0);
  const returnAction = providerPage.getByRole('button', {
    name: 'Return to recipe instructions',
    exact: true,
  });
  await returnAction.waitFor({ state: 'visible' });
  await returnAction.click();
  await assertView(providerPage, 'recipes');
  await providerPage
    .getByRole('heading', { name: 'Customize instructions', exact: true })
    .waitFor();
  assert.equal(await providerPage.getByLabel('Jira site URL').inputValue(), remoteUrl);
  assert.equal(await providerPage.getByLabel('Jira project', { exact: true }).inputValue(), 'TEAM');
  assert.equal(await providerPage.getByLabel('Jira API token').inputValue(), 'jira-smoke-secret');
  await providerPage.close();

  // Main navigation uses exclusive views and browser history restores the cached wizard.
  const navPage = await isolatedPage();
  await navPage.route('**/v1/recipes/jira-issue', (route) =>
    route.fulfill({
      json: { managementEnabled: true, recipe: { settings: null, hasApiToken: false } },
    }),
  );
  await assertView(navPage, 'sessions');
  await openRecipes(navPage);
  await navPage.getByLabel('Jira site URL').fill('https://jira.example');
  await openProviders(navPage);
  await assertView(navPage, 'providers');
  await navPage.goBack();
  await assertView(navPage, 'recipes');
  assert.equal(await navPage.getByLabel('Jira site URL').inputValue(), 'https://jira.example');
  await navPage.goForward();
  await assertView(navPage, 'providers');
  await navPage.reload();
  await assertView(navPage, 'providers');
  await navPage.close();

  // Exercise the shared shell independently of Jira, including optional steps.
  const sharedWizard = await page.evaluate(() => {
    const root = document.createElement('div');
    root.innerHTML = `
      <ol class="wizard-progress"></ol>
      <section data-wizard-step data-step-label="First">
        <h2 tabindex="-1">First</h2><input id="shared-required" required value="valid">
        <input data-wizard-skip required>
      </section>
      <section data-wizard-step data-wizard-skip><input required></section>
      <section data-wizard-step data-step-label="Last"><h2 tabindex="-1">Last</h2></section>
      <section data-wizard-step data-wizard-skip><input required></section>
      <button type="button" data-wizard-action="back">Back</button>
      <button type="button" data-wizard-action="continue">Continue</button>
      <button type="button" data-wizard-save>Save</button>`;
    document.body.append(root);
    const wizard = window.HighliteUI.createWizard(root);
    const save = root.querySelector('[data-wizard-save]');
    const next = root.querySelector('[data-wizard-action="continue"]');
    const field = root.querySelector('#shared-required');
    const results = { activeSteps: wizard.activeSteps.length, saveInitiallyHidden: save.hidden };
    wizard.next();
    results.lastStep = wizard.isLast && !save.hidden && next.hidden;
    field.value = '';
    results.hiddenRequiredRejected =
      !wizard.validate(wizard.steps) && document.activeElement === field;
    field.value = 'valid';
    wizard.next();
    field.value = '';
    root.querySelector('.wizard-progress button').click();
    results.backWithoutValidation = wizard.isFirst;
    wizard.showAll();
    results.editShowsActiveOnly = [...root.querySelectorAll('[data-wizard-step]')].map(
      (step) => !step.hidden,
    );
    root.remove();
    return results;
  });
  assert.deepEqual(sharedWizard, {
    activeSteps: 2,
    saveInitiallyHidden: true,
    lastStep: true,
    hiddenRequiredRejected: true,
    backWithoutValidation: true,
    editShowsActiveOnly: [true, false, true, false],
  });

  assert.deepEqual(errors, []);
  process.stdout.write('Jira recipe browser smoke test passed.\n');
} finally {
  await browser?.close();
  if (relay?.pid && relay.exitCode === null) {
    const exited = new Promise((resolve) => relay.once('exit', resolve));
    relay.kill('SIGTERM');
    await exited;
  }
  await new Promise((resolve) => remote.close(resolve));
  await rm(root, { recursive: true, force: true });
}
