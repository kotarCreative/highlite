import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
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
const remote = httpServer(async (request, response) => {
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
  page.on('pageerror', (error) => errors.push(error.message));
  async function openRecipes() {
    await page.getByRole('button', { name: 'Recipes', exact: true }).click();
    await page.waitForFunction(() => !document.getElementById('recipe-config-form').inert);
  }
  await page.goto(`http://${address}/#token=smoke-read`);
  await openRecipes();
  await page.getByLabel('Jira site URL').fill(remoteUrl);
  await page.getByLabel('Jira account email').fill('tester@example.com');
  await page.getByLabel('Jira API token').fill('jira-smoke-secret');
  await page.getByLabel('Project key').fill('TEAM');
  await page.getByLabel('Issue type ID').fill('10001');
  await page
    .getByLabel('Custom analysis prompt')
    .fill('Focus on usability defects and preserve evidence references.');
  await page.getByLabel('Enable this recipe').check();
  assert.equal(await page.getByLabel('After drafting').inputValue(), 'review');
  await page.getByLabel('After drafting').selectOption('review');
  await page.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await page
    .getByText('Recipe saved. Jira credentials have not been verified.', { exact: false })
    .waitFor();
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
  await page.getByLabel('After drafting').selectOption('automatic');
  assert.equal(await page.getByLabel('Jira API token').inputValue(), '');
  await page.getByRole('button', { name: 'Save recipe', exact: true }).click();
  await page
    .getByText('New sessions will draft and publish automatically.', { exact: false })
    .waitFor();
  assert.equal(await page.getByLabel('After drafting').inputValue(), 'automatic');
  await uploadSession('jira-auto-smoke');
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await page.locator('.session[data-id="jira-auto-smoke"]').click();
  await page.getByText('Jira recipe: published', { exact: true }).waitFor();
  await page.getByRole('link', { name: 'Open TEAM-2 in Jira', exact: true }).waitFor();
  assert.equal(aiCalls, 2);
  assert.equal(issues.length, 2);
  assert.equal(issues[1].fields.summary, 'Captured usability defect');
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
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
