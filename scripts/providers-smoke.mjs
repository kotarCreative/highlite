import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { chromium } from 'playwright-core';

const exec = promisify(execFile);
const tempRoot = existsSync('/tmp/opencode') ? '/tmp/opencode' : tmpdir();
const root = await mkdtemp(join(tempRoot, 'highlite-providers-'));
const configDir = join(root, 'config');
const binary = fileURLToPath(
  new URL(
    `../target/debug/highlite-relay${process.platform === 'win32' ? '.exe' : ''}`,
    import.meta.url,
  ),
);
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const { port } = reserve.address();
await new Promise((resolve) => reserve.close(resolve));
const address = `127.0.0.1:${port}`;
let relay;
let browser;

async function cli(...args) {
  return exec(binary, ['providers', ...args, '--config-dir', configDir]);
}

try {
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
        HIGHLITE_RELAY_ALLOWED_ORIGINS: '',
        HIGHLITE_RELAY_ALLOW_PIPELINES: 'false',
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    },
  );
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Relay startup timed out')), 15000);
    let diagnostics = '';
    relay.once('error', (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    relay.once('exit', (code) => {
      clearTimeout(timeout);
      reject(new Error(`Relay exited during startup: ${code}\n${diagnostics}`));
    });
    relay.stderr.on('data', (chunk) => {
      diagnostics += chunk.toString();
      if (chunk.toString().includes('listening on')) {
        clearTimeout(timeout);
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
  async function assertView(view) {
    await page.waitForFunction(
      (name) =>
        location.hash === `#${name}` &&
        document.querySelector(`[data-app-view="${name}"]`)?.hidden === false &&
        document.querySelector(`nav a[href="#${name}"]`)?.getAttribute('aria-current') === 'page',
      view,
    );
    assert.equal(new URL(page.url()).hash, `#${view}`);
    assert.equal(await page.locator('[data-app-view]:visible').count(), 1);
    assert.equal(await page.locator(`[data-app-view="${view}"]`).isVisible(), true);
    assert.equal(await page.locator(`nav a[href="#${view}"][aria-current="page"]`).count(), 1);
  }
  async function navigate(view) {
    await page
      .getByRole('link', { name: view[0].toUpperCase() + view.slice(1), exact: true })
      .click();
    await assertView(view);
  }
  await page.goto(`http://${address}/#token=smoke-read`);
  await assertView('sessions');
  assert.ok(!page.url().includes('smoke-read'));
  await navigate('providers');
  await page.getByText('No providers configured.').waitFor();
  await page.getByLabel('Connection name').fill('work');
  await page.getByLabel('Default model').fill('smoke-model');
  await page.getByLabel('API key', { exact: true }).fill('browser-secret-key');
  await page.getByRole('button', { name: 'Save connection' }).click();
  await page.getByText('Connection saved. Credentials have not been verified').waitFor();
  assert.equal(await page.getByLabel('API key', { exact: true }).inputValue(), '');
  let list = JSON.parse((await cli('list')).stdout);
  assert.equal(list.defaultProvider, 'work');
  assert.equal(list.providers[0].hasApiKey, true);
  assert.ok(!(await cli('list')).stdout.includes('browser-secret-key'));
  const row = page.locator('.provider-row').filter({ hasText: 'work' });
  await row.getByRole('button', { name: 'Edit', exact: true }).click();
  assert.equal(await page.getByLabel('API key', { exact: true }).inputValue(), '');
  await page.getByLabel('Default model').fill('updated-model');
  await page.getByRole('button', { name: 'Save connection' }).click();
  await row.getByText('updated-model', { exact: false }).waitFor();
  assert.ok(
    (await readFile(join(configDir, 'providers.json'), 'utf8')).includes('browser-secret-key'),
  );
  await cli(
    'connect',
    'local',
    '--kind',
    'openai-compatible',
    '--model',
    'local-model',
    '--base-url',
    'http://localhost:11434/v1',
    '--no-api-key',
    '--default',
  );
  await navigate('sessions');
  await navigate('providers');
  await page.getByText('local · Default', { exact: true }).waitFor();
  await row.getByRole('button', { name: 'Use by default' }).click();
  await page.getByText('Default provider updated.', { exact: true }).waitFor();
  list = JSON.parse((await cli('list')).stdout);
  assert.equal(list.defaultProvider, 'work');
  const storage = await page.evaluate(() =>
    JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }),
  );
  assert.ok(!storage.includes('browser-secret-key'));
  assert.ok(!(await page.locator('body').innerText()).includes('browser-secret-key'));
  page.once('dialog', (dialog) => dialog.accept());
  await row.getByRole('button', { name: 'Disconnect', exact: true }).click();
  await page.getByText('Connection removed.', { exact: true }).waitFor();
  assert.ok(
    !(await readFile(join(configDir, 'providers.json'), 'utf8')).includes('browser-secret-key'),
  );
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.getByRole('button', { name: 'Change token' }).click();
  assert.equal(await page.locator('[data-app-view]:visible').count(), 0);
  assert.equal(await page.locator('nav a[aria-current="page"]').count(), 0);
  assert.deepEqual(errors, []);
  process.stdout.write('Provider CLI/UI smoke test passed.\n');
} finally {
  await browser?.close();
  if (relay?.pid && relay.exitCode === null) {
    const exited = new Promise((resolve) => relay.once('exit', resolve));
    relay.kill('SIGTERM');
    await exited;
  }
  await rm(root, { recursive: true, force: true });
}
