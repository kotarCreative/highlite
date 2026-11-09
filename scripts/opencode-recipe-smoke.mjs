import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer as httpServer } from 'node:http';
import { createRequire } from 'node:module';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const require = createRequire(new URL('../packages/sdk/package.json', import.meta.url));
const JSZip = require('jszip');
const execFileAsync = promisify(execFile);

const READ_TOKEN = 'smoke-read';
const INGEST_TOKEN = 'smoke-ingest';
const BROWSER_ORIGIN = 'http://localhost:5173';
const TRUSTED_PROMPT = 'Route this capture to the matching checkout session. TRUSTED_PROMPT_MARKER';
const PROMPT_SECRET = 'PROMPT_SECRET_DO_NOT_LEAK';
const SUMMARY_MARKER_A = 'CAPTURE_MARKER_ALPHA';
const SUMMARY_TAIL_A = 'AI_TAIL_MUST_NOT_REACH_ROUTING';
const SUMMARY_MARKER_D = 'CAPTURE_MARKER_LARGE';
const SUMMARY_TAIL_D = 'LARGE_SUMMARY_TAIL_MUST_BE_TRUNCATED';
const RAW_STDOUT_SECRET = 'RAW_CLI_STDOUT_SECRET';
const RAW_STDERR_SECRET = 'RAW_CLI_STDERR_SECRET';

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const root = await mkdtemp(
  join(existsSync('/tmp/opencode') ? '/tmp/opencode' : tmpdir(), 'highlite-opencode-'),
);
const configDir = join(root, 'config');
const dataDir = join(root, 'data');
const projectDir = join(root, 'project');
const otherProjectDir = join(root, 'other-project');
const emptyProjectDir = join(root, 'empty-project');
const fakeStatePath = join(root, 'opencode-state.json');
const fakePromptLog = join(root, 'prompt-calls.jsonl');
const fakeCallLog = join(root, 'cli-calls.jsonl');
const fakeModeFile = join(root, 'prompt-mode.txt');
const binary = fileURLToPath(
  new URL(
    `../target/debug/highlite-relay${process.platform === 'win32' ? '.exe' : ''}`,
    import.meta.url,
  ),
);
const fixture = JSON.parse(
  await readFile(new URL('../fixtures/capture.json', import.meta.url), 'utf8'),
);

await mkdir(projectDir, { recursive: true });
await mkdir(otherProjectDir, { recursive: true });
await mkdir(emptyProjectDir, { recursive: true });
await mkdir(configDir, { recursive: true });
await chmod(configDir, 0o700);
await writeFile(fakeModeFile, 'ok');

const fakeState = {
  version: '2.0.32',
  projects: [
    {
      id: 'prj_project',
      canonical: projectDir,
      name: 'highlite-smoke',
      time: { created: 1760000000, updated: 1760000100, active: 1760000100 },
    },
    {
      id: 'prj_other',
      canonical: otherProjectDir,
      name: 'other-project',
      time: { created: 1760000000, updated: 1760000000, active: 1760000000 },
    },
  ],
  sessions: [
    {
      id: 'ses_target',
      projectID: 'prj_project',
      title: 'Checkout bug',
      location: { directory: projectDir },
      time: { created: 1760000000, updated: 1760002000 },
    },
    {
      id: 'ses_second',
      projectID: 'prj_project',
      title: 'Checkout follow-up',
      location: { directory: projectDir },
      time: { created: 1760000001, updated: 1760001500 },
    },
    {
      id: 'ses_child',
      parentID: 'ses_target',
      projectID: 'prj_project',
      title: 'Child subagent',
      location: { directory: projectDir },
      time: { created: 1760000002, updated: 1760001800 },
    },
    {
      id: 'ses_archived',
      projectID: 'prj_project',
      title: 'Archived checkout',
      location: { directory: projectDir },
      time: { created: 1760000003, updated: 1760003000, archived: 1760003000 },
    },
    {
      id: 'ses_other',
      projectID: 'prj_other',
      title: 'Other project checkout',
      location: { directory: otherProjectDir },
      time: { created: 1760000004, updated: 1760004000 },
    },
    {
      id: 'ses_subdir',
      projectID: 'prj_project',
      title: 'Nested checkout',
      location: { directory: `${projectDir}/sub` },
      time: { created: 1760000005, updated: 1760005000 },
    },
  ],
};

async function persistFakeState() {
  await writeFile(fakeStatePath, JSON.stringify(fakeState, null, 2));
}

await persistFakeState();

const fakeCli = `#!/usr/bin/env node
import { appendFileSync, readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const command = args[1];
const rest = args.slice(2);
const callLog = process.env.HIGHLITE_FAKE_CALL_LOG;

function writeJson(value) {
  process.stdout.write(JSON.stringify(value) + '\\n');
}

function fail(code, stdoutSecret, stderrSecret) {
  if (stdoutSecret) {
    process.stdout.write(JSON.stringify({ error: stdoutSecret }) + '\\n');
  }
  process.stderr.write('HTTP ' + code + (stderrSecret ? ' ' + stderrSecret : '') + '\\n');
  process.exit(1);
}

function param(name) {
  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index + 1];
    if (rest[index] === '--param' && typeof value === 'string' && value.startsWith(name + '=')) {
      return value.slice(name.length + 1);
    }
  }
  return undefined;
}

function body() {
  const index = rest.indexOf('--data');
  if (index < 0 || typeof rest[index + 1] !== 'string') return null;
  return JSON.parse(rest[index + 1]);
}

if (callLog) {
  appendFileSync(
    callLog,
    JSON.stringify({
      command,
      args: rest,
      noColor: process.env.NO_COLOR,
      env: Object.keys(process.env)
        .filter((name) => name.startsWith('HIGHLITE_'))
        .sort(),
    }) + '\\n',
  );
}

if (process.env.NO_COLOR !== '1') fail(500);
if (process.env.HIGHLITE_FAKE_AUTH !== 'fake-opencode-authenticated') fail(401);

const state = JSON.parse(readFileSync(process.env.HIGHLITE_FAKE_STATE, 'utf8'));
const sessions = state.sessions
  .slice()
  .sort((left, right) => (right.time.updated ?? 0) - (left.time.updated ?? 0));

if (command === 'server.info') {
  const info = {
    version: state.version,
    pid: process.pid,
    urls: { web: 'http://127.0.0.1:4096' },
    paths: { tmp: process.env.HIGHLITE_FAKE_TMP ?? '/tmp' },
  };
  writeJson(info);
  process.exit(0);
}

if (command === 'session.list') {
  writeJson({
    data: sessions,
    cursor: { previous: null, next: null },
  });
  process.exit(0);
}

if (command === 'project.list') {
  writeJson(state.projects);
  process.exit(0);
}

if (command === 'session.get') {
  const session = sessions.find((candidate) => candidate.id === param('sessionID'));
  if (!session) fail(404);
  writeJson(session);
  process.exit(0);
}

if (command === 'session.prompt') {
  const payload = body();
  if (!payload) fail(400);
  const target = param('sessionID');
  // OpenCode may allocate a different message ID from the requested one.
  const actualId = 'msg_actual_' + process.pid + '_' + Date.now();
  appendFileSync(
    process.env.HIGHLITE_FAKE_PROMPT_LOG,
    JSON.stringify({ ...payload, target, responseId: actualId }) + '\\n',
  );
  const mode = readFileSync(process.env.HIGHLITE_FAKE_MODE_FILE, 'utf8').trim();
  if (mode === 'reject400') fail(400, '${RAW_STDOUT_SECRET}', '${RAW_STDERR_SECRET}');
  if (mode === 'reject401') fail(401, null, '${RAW_STDERR_SECRET}');
  if (mode === 'reject404') fail(404, null, '${RAW_STDERR_SECRET}');
  if (mode === 'unknown409') fail(409, null, '${RAW_STDERR_SECRET}');
  if (mode === 'unknown500') fail(500, null, '${RAW_STDERR_SECRET}');
  if (mode === 'invalid') {
    writeJson({ data: {} });
    process.exit(0);
  }
  writeJson({ data: { id: actualId, sessionID: target, role: 'user' } });
  process.exit(0);
}

fail(404);
`;

const fakeBin = join(root, 'fake-opencode.mjs');
await writeFile(fakeBin, fakeCli);
await chmod(fakeBin, 0o755);

let aiCalls = 0;
let aiTarget = 'ses_target';
let aiMode = 'valid';
let lastAiText = '';
const aiServer = httpServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const input = JSON.parse(Buffer.concat(chunks).toString());
  response.setHeader('Content-Type', 'application/json');
  if (request.url !== '/v1/chat/completions') {
    response.statusCode = 404;
    response.end(JSON.stringify({ error: 'not found' }));
    return;
  }
  aiCalls += 1;
  const content = input.messages?.[1]?.content;
  lastAiText = Array.isArray(content)
    ? content
        .filter((part) => part?.type === 'text')
        .map((part) => part.text)
        .join('')
    : String(content ?? '');
  if (aiMode === 'fail') {
    response.statusCode = 500;
    response.end(JSON.stringify({ error: 'fake AI failure' }));
    return;
  }
  const sessionId = aiMode === 'hallucinated' ? 'ses_hallucinated' : aiTarget;
  const suggestion = {
    sessionId,
    confidence: aiMode === 'hallucinated' ? 'medium' : 'high',
    reason: 'The capture describes the checkout flow in the candidate session.',
  };
  const payload = JSON.stringify(suggestion);
  // Exercise JSON code-fence stripping on the first response.
  const text = aiCalls === 1 ? `\`\`\`json\n${payload}\n\`\`\`` : payload;
  response.end(
    JSON.stringify({
      choices: [
        {
          finish_reason: 'stop',
          message: { content: text, refusal: null },
        },
      ],
    }),
  );
});

const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const address = `127.0.0.1:${reserve.address().port}`;
await new Promise((resolve) => reserve.close(resolve));

let relay;
try {
  await new Promise((resolve) => aiServer.listen(0, '127.0.0.1', resolve));
  const aiUrl = `http://127.0.0.1:${aiServer.address().port}`;
  await execFileAsync(binary, [
    'providers',
    'connect',
    'local',
    '--kind',
    'openai-compatible',
    '--model',
    'smoke-model',
    '--base-url',
    `${aiUrl}/v1`,
    '--no-api-key',
    '--config-dir',
    configDir,
  ]);

  relay = spawn(binary, ['--bind', address, '--data-dir', dataDir, '--config-dir', configDir], {
    env: {
      ...Object.fromEntries(
        Object.entries(process.env).filter(
          ([name]) =>
            !name.startsWith('HIGHLITE_RELAY_') &&
            name !== 'HIGHLITE_CONFIG_DIR' &&
            name !== 'HIGHLITE_ASR_COMMAND',
        ),
      ),
      HIGHLITE_RELAY_INGEST_TOKEN: INGEST_TOKEN,
      HIGHLITE_RELAY_READ_TOKEN: READ_TOKEN,
      HIGHLITE_RELAY_ALLOWED_HOSTS: address,
      // The native app starts the relay with the local demo origins allowlisted.
      HIGHLITE_RELAY_ALLOWED_ORIGINS: `${BROWSER_ORIGIN},http://127.0.0.1:5173`,
      HIGHLITE_FAKE_AUTH: 'fake-opencode-authenticated',
      HIGHLITE_FAKE_STATE: fakeStatePath,
      HIGHLITE_FAKE_PROMPT_LOG: fakePromptLog,
      HIGHLITE_FAKE_CALL_LOG: fakeCallLog,
      HIGHLITE_FAKE_MODE_FILE: fakeModeFile,
      HIGHLITE_FAKE_TMP: root,
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  await new Promise((resolve, reject) => {
    let diagnostics = '';
    const timer = setTimeout(() => reject(new Error('Relay startup timed out')), 15000);
    relay.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    relay.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`Relay exited during startup: ${code}\n${diagnostics}`));
    });
    relay.stderr.on('data', (chunk) => {
      diagnostics += chunk.toString();
      if (diagnostics.includes('listening on')) {
        clearTimeout(timer);
        resolve();
      }
    });
  });

  const baseUrl = `http://${address}`;

  async function api(path, { method = 'GET', token = READ_TOKEN, body, headers = {} } = {}) {
    const requestHeaders = {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...headers,
    };
    const response =
      method === 'POST'
        ? await fetch(`${baseUrl}${path}`, {
            method: 'POST',
            headers: requestHeaders,
            ...(body === undefined ? {} : { body: JSON.stringify(body) }),
          })
        : await fetch(`${baseUrl}${path}`, { method: 'GET', headers: requestHeaders });
    const text = await response.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      json = undefined;
    }
    return { status: response.status, json, text };
  }

  async function readJsonLines(path) {
    if (!existsSync(path)) return [];
    const text = await readFile(path, 'utf8');
    return text
      .split('\n')
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  }

  async function waitForSessionReady(sessionId) {
    const started = Date.now();
    for (;;) {
      const response = await api(`/v1/sessions/${encodeURIComponent(sessionId)}`);
      assert.equal(response.status, 200, response.text);
      if (response.json.status === 'ready') return response.json;
      if (response.json.status === 'failed') {
        throw new Error(`Session ${sessionId} failed to compile: ${response.json.error ?? ''}`);
      }
      if (Date.now() - started > 30000) {
        throw new Error(`Session ${sessionId} did not become ready in time`);
      }
      await delay(100);
    }
  }

  async function uploadSession(frame) {
    const manifest = {
      ...fixture.manifest,
      sessionId: frame.sessionId,
      page: { ...fixture.manifest.page, title: frame.title },
      keyframes: [],
      transcript: [
        {
          id: `tr_${frame.sessionId}`,
          startMs: 0,
          endMs: Math.min(60000, Math.ceil(frame.text.length / 100)),
          text: frame.text,
        },
      ],
    };
    const zip = new JSZip();
    zip.file('manifest.json', JSON.stringify(manifest));
    const response = await fetch(`${baseUrl}/v1/sessions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${INGEST_TOKEN}`,
        'Content-Type': 'application/zip',
        Origin: frame.origin ?? BROWSER_ORIGIN,
      },
      body: await zip.generateAsync({ type: 'nodebuffer' }),
    });
    assert.equal(response.status, 201, await response.text());
    return waitForSessionReady(frame.sessionId);
  }

  async function getRun(sessionId) {
    const response = await api(`/v1/sessions/${encodeURIComponent(sessionId)}/recipes/opencode`);
    assert.equal(response.status, 200, response.text);
    return response.json.run;
  }

  async function waitForRun(sessionId, statuses, label = 'run') {
    const started = Date.now();
    const terminal = ['failed', 'submitted', 'submit-unknown'];
    for (;;) {
      const run = await getRun(sessionId);
      if (run && statuses.includes(run.status)) return run;
      if (run && terminal.includes(run.status)) {
        throw new Error(`${label} reached unexpected terminal status ${run.status}`);
      }
      if (Date.now() - started > 45000) {
        throw new Error(
          `${label} did not reach ${statuses.join('/')} in time (last: ${run?.status})`,
        );
      }
      await delay(150);
    }
  }

  async function startRun(sessionId) {
    const response = await api(`/v1/sessions/${encodeURIComponent(sessionId)}/recipes/opencode`, {
      method: 'POST',
    });
    assert.equal(response.status, 202, response.text);
    return response.json;
  }

  async function submit(sessionId, body) {
    return api(`/v1/sessions/${encodeURIComponent(sessionId)}/recipes/opencode/submit`, {
      method: 'POST',
      body,
    });
  }

  async function saveSettings(overrides = {}) {
    const settings = {
      enabled: true,
      autoDraft: true,
      directory: projectDir,
      prompt: `${TRUSTED_PROMPT} ${PROMPT_SECRET}`,
      opencodePath: fakeBin,
      maxCandidates: 30,
      ...overrides,
    };
    const response = await api('/v1/recipes/opencode', {
      method: 'POST',
      body: { settings },
    });
    assert.equal(response.status, 200, response.text);
    assert.deepEqual(response.json.settings, settings);
    return response.json;
  }

  function assertSafe(text, label) {
    const value = String(text ?? '');
    for (const secret of [
      PROMPT_SECRET,
      SUMMARY_MARKER_A,
      SUMMARY_MARKER_D,
      SUMMARY_TAIL_A,
      SUMMARY_TAIL_D,
      RAW_STDOUT_SECRET,
      RAW_STDERR_SECRET,
    ]) {
      assert.ok(!value.includes(secret), `${label} leaked ${secret}`);
    }
  }

  function deterministicMessageId(highliteSessionId, revision, opencodeSessionId) {
    return `msg_${createHash('sha256')
      .update(`highlite\0${highliteSessionId}\0${revision}\0${opencodeSessionId}`)
      .digest('hex')
      .slice(0, 32)}`;
  }

  async function assertRevalidatedBeforePrompt(target, label) {
    const calls = await readJsonLines(fakeCallLog);
    let promptIndex = -1;
    for (let index = 0; index < calls.length; index += 1) {
      if (calls[index].command === 'session.prompt') promptIndex = index;
    }
    assert.ok(promptIndex >= 0, `${label}: expected a session.prompt call`);
    let previousPromptIndex = -1;
    for (let index = 0; index < promptIndex; index += 1) {
      if (calls[index].command === 'session.prompt') previousPromptIndex = index;
    }
    let revalidationIndex = -1;
    for (let index = previousPromptIndex + 1; index < promptIndex; index += 1) {
      const call = calls[index];
      if (call.command === 'session.get' && call.args.includes(`sessionID=${target}`)) {
        revalidationIndex = index;
      }
    }
    assert.ok(
      revalidationIndex > previousPromptIndex && revalidationIndex < promptIndex,
      `${label}: session.get must revalidate the target before session.prompt`,
    );
  }

  function assertPromptHasNoLocalPaths(preview, label) {
    for (const local of [
      dataDir,
      projectDir,
      join(dataDir, 'bundles'),
      'bundle.json',
      'summary.md',
    ]) {
      assert.ok(
        !preview.includes(local),
        `${label} must not contain local path/reference ${local}`,
      );
    }
  }

  const initialConfig = await api('/v1/recipes/opencode');
  if (initialConfig.status === 404) {
    throw new Error(
      'The relay does not expose /v1/recipes/opencode yet; wait for the backend worker, then rerun pnpm test:opencode.',
    );
  }
  assert.equal(initialConfig.status, 200, initialConfig.text);
  assert.equal(initialConfig.json.managementEnabled, true);
  assert.equal(initialConfig.json.recipe.id, 'opencode');
  assert.equal(initialConfig.json.recipe.version, '1.0.0');
  assert.equal(initialConfig.json.recipe.settings, null);

  const unauthorised = await api('/v1/recipes/opencode', { token: null });
  assert.equal(unauthorised.status, 401, unauthorised.text);

  const relativeDirectory = await api('/v1/recipes/opencode', {
    method: 'POST',
    body: {
      settings: {
        enabled: true,
        autoDraft: false,
        directory: 'relative/project',
        prompt: TRUSTED_PROMPT,
        opencodePath: null,
        maxCandidates: 30,
      },
    },
  });
  assert.ok(
    [400, 422].includes(relativeDirectory.status),
    `relative directory should be rejected: ${relativeDirectory.status} ${relativeDirectory.text}`,
  );

  await saveSettings({ autoDraft: true });

  const discover = await api('/v1/recipes/opencode/discover', {
    method: 'POST',
    body: { opencodePath: fakeBin },
  });
  assert.equal(discover.status, 200, discover.text);
  assert.equal(discover.json.opencode.version, '2.0.32');
  assert.equal(discover.json.directory, projectDir);
  assert.deepEqual(
    discover.json.sessions.map((candidate) => candidate.sessionId),
    ['ses_target', 'ses_second'],
  );
  assert.deepEqual(
    discover.json.projects.map((project) => project.projectId),
    ['prj_project'],
  );
  const discoveredTarget = discover.json.sessions.find(
    (candidate) => candidate.sessionId === 'ses_target',
  );
  assert.equal(discoveredTarget.title, 'Checkout bug');
  assert.equal(discoveredTarget.directory, projectDir);
  assert.equal(discoveredTarget.projectName, 'highlite-smoke');
  assert.equal(discoveredTarget.createdAtMs, 1760000000000);
  assert.equal(discoveredTarget.updatedAtMs, 1760002000000);
  for (const candidate of discover.json.sessions) {
    assert.ok(!('parentID' in candidate), 'candidate output must not include parentID');
    assert.ok(!('time' in candidate), 'candidate output must use normalized timestamps');
    assert.ok(!('messages' in candidate), 'candidate output must be metadata only');
  }

  fakeState.version = '1.0.0';
  await persistFakeState();
  const versionMismatch = await api('/v1/recipes/opencode/discover', {
    method: 'POST',
    body: { opencodePath: fakeBin },
  });
  fakeState.version = '2.0.32';
  await persistFakeState();
  assert.equal(versionMismatch.status, 502, versionMismatch.text);
  assert.match(versionMismatch.text, /major version/);

  const extraSessions = Array.from({ length: 6 }, (_, index) => ({
    id: `ses_extra_${index}`,
    projectID: 'prj_project',
    title: `Extra checkout ${index}`,
    location: { directory: projectDir },
    time: { created: 1760000100 + index, updated: 1760002500 + index * 100 },
  }));
  fakeState.sessions.push(...extraSessions);
  await persistFakeState();
  await saveSettings({ autoDraft: true, maxCandidates: 5 });
  const capped = await api('/v1/recipes/opencode/discover', {
    method: 'POST',
    body: { opencodePath: fakeBin },
  });
  assert.equal(capped.status, 200, capped.text);
  assert.deepEqual(
    capped.json.sessions.map((candidate) => candidate.sessionId),
    ['ses_extra_5', 'ses_extra_4', 'ses_extra_3', 'ses_extra_2', 'ses_extra_1'],
  );
  fakeState.sessions = fakeState.sessions.filter((session) => !session.id.startsWith('ses_extra_'));
  await persistFakeState();
  await saveSettings({ autoDraft: true, maxCandidates: 30 });

  // A: automatic suggestion must not submit anything.
  await uploadSession({
    sessionId: 'hl-opencode-a',
    title: 'Checkout page A',
    text: `${SUMMARY_MARKER_A} ${'x'.repeat(5000)} ${SUMMARY_TAIL_A}`,
  });
  const runA = await waitForRun('hl-opencode-a', ['suggested'], 'auto suggestion A');
  assert.equal(runA.recipe, 'opencode');
  assert.equal(runA.recipeVersion, '1.0.0');
  assert.equal(runA.status, 'suggested');
  assert.equal(runA.revision, 1);
  assert.equal(runA.settings.directory, projectDir);
  assert.equal(runA.provider.id, 'local');
  assert.deepEqual(runA.eligibleSessionIds, ['ses_target', 'ses_second']);
  assert.deepEqual(
    runA.candidates.map((candidate) => candidate.sessionId),
    ['ses_target', 'ses_second'],
  );
  assert.equal(runA.suggestion.sessionId, 'ses_target');
  assert.equal(runA.suggestion.confidence, 'high');
  assert.ok(runA.promptPreview.includes(TRUSTED_PROMPT));
  assert.ok(runA.promptPreview.includes(SUMMARY_MARKER_A));
  assert.ok(runA.promptPreview.includes(SUMMARY_TAIL_A));
  assert.ok(Buffer.byteLength(runA.promptPreview, 'utf8') <= 64 * 1024);
  assertPromptHasNoLocalPaths(runA.promptPreview, 'preview A');
  assert.equal(runA.opencodeSessionId, null);
  assert.equal(runA.submittedAtMs, null);
  assert.equal(aiCalls, 1);
  assert.ok(lastAiText.includes(SUMMARY_MARKER_A));
  assert.ok(
    !lastAiText.includes(SUMMARY_TAIL_A),
    'AI routing must receive only the bounded 4 KiB summary excerpt',
  );
  assert.equal((await readJsonLines(fakePromptLog)).length, 0, 'auto-suggestion must not submit');
  await delay(500);
  assert.equal((await readJsonLines(fakePromptLog)).length, 0, 'no delayed automatic submit');
  const runAAgain = await getRun('hl-opencode-a');
  assert.equal(runAAgain.promptPreview, runA.promptPreview, 'promptPreview must be immutable');

  const submitA = await submit('hl-opencode-a', {
    revision: runA.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(submitA.status, 202, submitA.text);
  const submittedA = await waitForRun('hl-opencode-a', ['submitted'], 'submit A');
  const promptCallsA = await readJsonLines(fakePromptLog);
  assert.equal(promptCallsA.length, 1);
  assert.equal(promptCallsA[0].target, 'ses_target');
  assert.equal(promptCallsA[0].text, runA.promptPreview);
  assert.equal(promptCallsA[0].delivery, 'queue');
  assert.equal(
    promptCallsA[0].id,
    deterministicMessageId('hl-opencode-a', runA.revision, 'ses_target'),
  );
  assert.equal(submittedA.messageId, promptCallsA[0].responseId);
  await assertRevalidatedBeforePrompt('ses_target', 'submit A');

  await saveSettings({ autoDraft: false });

  // B: invalid AI IDs become a null suggestion; confirmation and revision guards apply.
  aiMode = 'hallucinated';
  await uploadSession({
    sessionId: 'hl-opencode-b',
    title: 'Checkout page B',
    text: `CAPTURE_MARKER_BETA ${'b'.repeat(600)}`,
    origin: 'http://127.0.0.1:5173',
  });
  await startRun('hl-opencode-b');
  const runB = await waitForRun('hl-opencode-b', ['suggested'], 'manual suggestion B');
  assert.equal(runB.suggestion, null, 'a hallucinated session ID must not become a suggestion');
  assert.ok(runB.promptPreview.includes('CAPTURE_MARKER_BETA'));
  assertPromptHasNoLocalPaths(runB.promptPreview, 'preview B');
  assert.equal((await readJsonLines(fakePromptLog)).length, 1);
  aiMode = 'valid';

  const notConfirmed = await submit('hl-opencode-b', {
    revision: runB.revision,
    sessionId: 'ses_target',
    confirm: false,
  });
  assert.equal(notConfirmed.status, 400, notConfirmed.text);
  const staleRevision = await submit('hl-opencode-b', {
    revision: runB.revision + 10,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(staleRevision.status, 409, staleRevision.text);
  const ineligible = await submit('hl-opencode-b', {
    revision: runB.revision,
    sessionId: 'ses_child',
    confirm: true,
  });
  assert.ok([400, 409].includes(ineligible.status), ineligible.text);

  const targetSession = fakeState.sessions.find((session) => session.id === 'ses_target');
  const originalTargetDirectory = targetSession.location.directory;
  targetSession.location.directory = otherProjectDir;
  await writeFile(fakeStatePath, JSON.stringify(fakeState, null, 2));
  const revalidation = await submit('hl-opencode-b', {
    revision: runB.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  targetSession.location.directory = originalTargetDirectory;
  await writeFile(fakeStatePath, JSON.stringify(fakeState, null, 2));
  assert.equal(revalidation.status, 409, revalidation.text);
  assert.match(revalidation.json.error.toLowerCase(), /eligible|refresh|directory/);
  assert.equal((await readJsonLines(fakePromptLog)).length, 1);

  await saveSettings({ autoDraft: false, directory: otherProjectDir });
  const changedDirectory = await submit('hl-opencode-b', {
    revision: runB.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(changedDirectory.status, 409, changedDirectory.text);
  assert.match(changedDirectory.json.error.toLowerCase(), /directory/);
  assert.equal((await readJsonLines(fakePromptLog)).length, 1);
  await saveSettings({ autoDraft: false });

  const submitB = await submit('hl-opencode-b', {
    revision: runB.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(submitB.status, 202, submitB.text);
  const submittedB = await waitForRun('hl-opencode-b', ['submitted'], 'submit B');
  assert.equal(submittedB.opencodeSessionId, 'ses_target');
  assert.equal(submittedB.opencodeTitle, 'Checkout bug');
  assert.ok(submittedB.submittedAtMs > 0);
  const promptCallsB = await readJsonLines(fakePromptLog);
  assert.equal(promptCallsB.length, 2);
  assert.equal(
    promptCallsB[1].text,
    runB.promptPreview,
    'sent prompt must equal the stored preview',
  );
  assert.equal(promptCallsB[1].delivery, 'queue');
  assert.equal(
    promptCallsB[1].id,
    deterministicMessageId('hl-opencode-b', runB.revision, 'ses_target'),
  );
  assert.equal(submittedB.messageId, promptCallsB[1].responseId);
  await assertRevalidatedBeforePrompt('ses_target', 'submit B');
  const resubmitB = await submit('hl-opencode-b', {
    revision: runB.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(resubmitB.status, 202, resubmitB.text);
  assert.equal((await readJsonLines(fakePromptLog)).length, 2, 'submitted runs must not resend');

  // C: HTTP 400/401/404 rejections are failed and retryable with the same revision.
  await uploadSession({
    sessionId: 'hl-opencode-c',
    title: 'Checkout page C',
    text: 'CAPTURE_MARKER_GAMMA',
  });
  await startRun('hl-opencode-c');
  const runC = await waitForRun('hl-opencode-c', ['suggested'], 'suggestion C');
  assertPromptHasNoLocalPaths(runC.promptPreview, 'preview C');
  let expectedPromptCount = 2;
  let previousRequestId;
  for (const rejection of [
    { mode: 'reject400', label: 'HTTP 400' },
    { mode: 'reject401', label: 'HTTP 401' },
    { mode: 'reject404', label: 'HTTP 404' },
  ]) {
    await writeFile(fakeModeFile, rejection.mode);
    const rejected = await submit('hl-opencode-c', {
      revision: runC.revision,
      sessionId: 'ses_target',
      confirm: true,
    });
    assert.equal(rejected.status, 202, rejected.text);
    const failed = await waitForRun(
      'hl-opencode-c',
      ['failed'],
      `clear rejection C ${rejection.label}`,
    );
    assert.ok(failed.error);
    assertSafe(failed.error, `run error after ${rejection.label}`);
    expectedPromptCount += 1;
    const calls = await readJsonLines(fakePromptLog);
    assert.equal(calls.length, expectedPromptCount);
    const call = calls[expectedPromptCount - 1];
    assert.equal(call.text, runC.promptPreview);
    assert.equal(call.id, deterministicMessageId('hl-opencode-c', runC.revision, 'ses_target'));
    if (previousRequestId) assert.equal(call.id, previousRequestId);
    previousRequestId = call.id;
  }

  await writeFile(fakeModeFile, 'ok');
  const retryC = await submit('hl-opencode-c', {
    revision: runC.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(retryC.status, 202, retryC.text);
  const submittedC = await waitForRun('hl-opencode-c', ['submitted'], 'retry C');
  assert.equal(submittedC.opencodeSessionId, 'ses_target');
  const promptCallsC2 = await readJsonLines(fakePromptLog);
  assert.equal(promptCallsC2.length, 6, 'retry must issue exactly one new prompt');
  assert.equal(promptCallsC2[5].id, previousRequestId);
  assert.equal(submittedC.messageId, promptCallsC2[5].responseId);
  await assertRevalidatedBeforePrompt('ses_target', 'retry C');

  // D: ambiguous failures are submit-unknown and are never retried automatically.
  await uploadSession({
    sessionId: 'hl-opencode-d',
    title: 'Checkout page D',
    text: `${SUMMARY_MARKER_D} ${'y'.repeat(60000)} ${SUMMARY_TAIL_D}`,
  });
  await startRun('hl-opencode-d');
  const runD = await waitForRun('hl-opencode-d', ['suggested'], 'suggestion D');
  assert.ok(runD.promptPreview.includes(SUMMARY_MARKER_D));
  assert.ok(
    !runD.promptPreview.includes(SUMMARY_TAIL_D),
    'the prompt excerpt must be bounded before the 60 KiB tail marker',
  );
  assert.ok(Buffer.byteLength(runD.promptPreview, 'utf8') <= 64 * 1024);
  assert.ok(!lastAiText.includes(SUMMARY_TAIL_D), 'AI routing excerpt must stay bounded');
  assertPromptHasNoLocalPaths(runD.promptPreview, 'preview D');

  await writeFile(fakeModeFile, 'unknown500');
  const unknownD = await submit('hl-opencode-d', {
    revision: runD.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(unknownD.status, 202, unknownD.text);
  const unknownRunD = await waitForRun('hl-opencode-d', ['submit-unknown'], 'ambiguous submit D');
  assert.ok(unknownRunD.error);
  assertSafe(unknownRunD.error, 'run error after HTTP 500');
  const promptCallsD = await readJsonLines(fakePromptLog);
  assert.equal(promptCallsD.length, 7);
  assert.equal(promptCallsD[6].text, runD.promptPreview);
  assert.equal(
    promptCallsD[6].id,
    deterministicMessageId('hl-opencode-d', runD.revision, 'ses_target'),
  );
  await assertRevalidatedBeforePrompt('ses_target', 'ambiguous submit D');
  const retryUnknown = await submit('hl-opencode-d', {
    revision: runD.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(retryUnknown.status, 409, retryUnknown.text);
  await delay(1000);
  assert.equal(
    (await readJsonLines(fakePromptLog)).length,
    7,
    'submit-unknown must not be retried implicitly',
  );

  // E: no eligible candidates produces a null suggestion without calling AI.
  await saveSettings({ autoDraft: false, directory: emptyProjectDir });
  const aiCallsBeforeEmpty = aiCalls;
  await uploadSession({
    sessionId: 'hl-opencode-e',
    title: 'Checkout page E',
    text: 'CAPTURE_MARKER_EPSILON',
  });
  await startRun('hl-opencode-e');
  const runE = await waitForRun('hl-opencode-e', ['suggested'], 'no candidates E');
  assert.deepEqual(runE.candidates, []);
  assert.deepEqual(runE.eligibleSessionIds, []);
  assert.equal(runE.suggestion, null);
  assert.ok(runE.promptPreview.includes('CAPTURE_MARKER_EPSILON'));
  assertPromptHasNoLocalPaths(runE.promptPreview, 'preview E');
  assert.equal(aiCalls, aiCallsBeforeEmpty, 'no candidates must skip the AI call');
  const emptySubmit = await submit('hl-opencode-e', {
    revision: runE.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(emptySubmit.status, 409, emptySubmit.text);
  await saveSettings({ autoDraft: false });

  // F: an AI request failure is a visible, retryable analysis failure.
  const aiCallsBeforeFailure = aiCalls;
  aiMode = 'fail';
  await uploadSession({
    sessionId: 'hl-opencode-f',
    title: 'Checkout page F',
    text: 'CAPTURE_MARKER_ZETA',
  });
  await startRun('hl-opencode-f');
  const runF = await waitForRun('hl-opencode-f', ['failed'], 'AI failure F');
  assert.ok(runF.error);
  assertSafe(runF.error, 'AI failure error');
  assert.equal(aiCalls, aiCallsBeforeFailure + 1);
  aiMode = 'valid';

  // G: an invalid exit-0 prompt response is submit-unknown and is not retried.
  await uploadSession({
    sessionId: 'hl-opencode-g',
    title: 'Checkout page G',
    text: 'CAPTURE_MARKER_ETA',
  });
  await startRun('hl-opencode-g');
  const runG = await waitForRun('hl-opencode-g', ['suggested'], 'suggestion G');
  await writeFile(fakeModeFile, 'invalid');
  const invalidG = await submit('hl-opencode-g', {
    revision: runG.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(invalidG.status, 202, invalidG.text);
  const unknownG = await waitForRun('hl-opencode-g', ['submit-unknown'], 'invalid exit G');
  assert.ok(unknownG.error);
  assertSafe(unknownG.error, 'invalid exit-0 error');
  const promptCallsG = await readJsonLines(fakePromptLog);
  assert.equal(promptCallsG.length, 8);
  assert.equal(promptCallsG[7].text, runG.promptPreview);
  await assertRevalidatedBeforePrompt('ses_target', 'invalid exit G');
  const retryG = await submit('hl-opencode-g', {
    revision: runG.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(retryG.status, 409, retryG.text);
  await delay(500);
  assert.equal((await readJsonLines(fakePromptLog)).length, 8);

  // H: HTTP 409 is an ambiguous delivery, not a clear rejection.
  await uploadSession({
    sessionId: 'hl-opencode-h',
    title: 'Checkout page H',
    text: 'CAPTURE_MARKER_THETA',
  });
  await startRun('hl-opencode-h');
  const runH = await waitForRun('hl-opencode-h', ['suggested'], 'suggestion H');
  await writeFile(fakeModeFile, 'unknown409');
  const unknownH = await submit('hl-opencode-h', {
    revision: runH.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(unknownH.status, 202, unknownH.text);
  const unknownRunH = await waitForRun('hl-opencode-h', ['submit-unknown'], 'HTTP 409 H');
  assert.ok(unknownRunH.error);
  assertSafe(unknownRunH.error, 'HTTP 409 error');
  const promptCallsH = await readJsonLines(fakePromptLog);
  assert.equal(promptCallsH.length, 9);
  assert.equal(promptCallsH[8].text, runH.promptPreview);
  await assertRevalidatedBeforePrompt('ses_target', 'HTTP 409 H');
  const retryH = await submit('hl-opencode-h', {
    revision: runH.revision,
    sessionId: 'ses_target',
    confirm: true,
  });
  assert.equal(retryH.status, 409, retryH.text);
  await delay(500);
  assert.equal((await readJsonLines(fakePromptLog)).length, 9);
  await writeFile(fakeModeFile, 'ok');

  // CLI subprocess contract: no color, no relay secrets, and session.get before prompt.
  const cliCalls = await readJsonLines(fakeCallLog);
  const promptCalls = await readJsonLines(fakePromptLog);
  assert.equal(promptCalls.length, 9);
  for (const call of cliCalls) {
    assert.equal(call.noColor, '1', 'the CLI must run with NO_COLOR=1');
    assert.ok(!call.env.includes('HIGHLITE_CONFIG_DIR'), 'CLI env must omit HIGHLITE_CONFIG_DIR');
    assert.ok(
      !call.env.some((name) => name.startsWith('HIGHLITE_RELAY_')),
      'CLI env must omit HIGHLITE_RELAY_* variables',
    );
  }
  const listCalls = cliCalls.filter((call) => call.command === 'session.list');
  assert.ok(listCalls.length >= 2, 'discovery must call session.list');
  for (const expected of [
    `directory=${projectDir}`,
    'archived=false',
    'parentID=null',
    'order=desc',
    'limit=30',
  ]) {
    assert.ok(listCalls[0].args.includes(expected), `session.list must include ${expected}`);
  }
  const listedLimits = listCalls.map((call) =>
    call.args.find((argument) => argument.startsWith('limit=')),
  );
  assert.ok(listedLimits.includes('limit=5'), 'candidate cap must reduce the session.list limit');
  assert.ok(
    cliCalls.some((call) => call.command === 'session.get'),
    'submission must revalidate the target with session.get',
  );

  // Activity: metadata only, sorted newest first, redacted errors.
  const activity = await api('/v1/activity?limit=100');
  assert.equal(activity.status, 200, activity.text);
  const items = activity.json.items;
  const opencodeItems = items.filter((item) => item.recipe === 'opencode');
  assert.ok(opencodeItems.length >= 8);
  for (let index = 1; index < items.length; index += 1) {
    assert.ok(
      items[index - 1].updatedAtMs >= items[index].updatedAtMs,
      'activity must be newest first',
    );
  }
  const bySession = new Map(opencodeItems.map((item) => [item.sessionId, item]));
  assert.equal(bySession.get('hl-opencode-a').status, 'submitted');
  assert.equal(bySession.get('hl-opencode-b').status, 'submitted');
  assert.equal(bySession.get('hl-opencode-c').status, 'submitted');
  assert.equal(bySession.get('hl-opencode-d').status, 'submit-unknown');
  assert.equal(bySession.get('hl-opencode-e').status, 'suggested');
  assert.equal(bySession.get('hl-opencode-f').status, 'failed');
  assert.equal(bySession.get('hl-opencode-g').status, 'submit-unknown');
  assert.equal(bySession.get('hl-opencode-h').status, 'submit-unknown');
  assert.equal(bySession.get('hl-opencode-a').opencodeSessionId, 'ses_target');
  assert.equal(bySession.get('hl-opencode-a').opencodeTitle, 'Checkout bug');
  const activityText = JSON.stringify(items);
  assertSafe(activityText, 'activity');
  for (const item of opencodeItems) {
    for (const forbidden of [
      'prompt',
      'promptPreview',
      'summary',
      'candidates',
      'eligibleSessionIds',
      'draft',
    ]) {
      assert.ok(!(forbidden in item), `activity item must not include ${forbidden}`);
    }
  }

  for (const limit of [0, 101]) {
    const invalidLimit = await api(`/v1/activity?limit=${limit}`);
    assert.equal(invalidLimit.status, 400, invalidLimit.text);
  }
  const noTokenActivity = await api('/v1/activity', { token: null });
  assert.equal(noTokenActivity.status, 401, noTokenActivity.text);

  process.stdout.write(
    'OpenCode recipe smoke test passed: fake authenticated CLI + fake AI + real relay.\n',
  );
} finally {
  if (relay?.pid && relay.exitCode === null) {
    let exited = false;
    const done = new Promise((resolve) => {
      relay.once('exit', () => {
        exited = true;
        resolve();
      });
    });
    relay.kill('SIGINT');
    await Promise.race([done, delay(5000)]);
    if (!exited && relay.exitCode === null) {
      relay.kill('SIGKILL');
      await Promise.race([done, delay(2000)]);
    }
  }
  await new Promise((resolve) => aiServer.close(resolve));
  await rm(root, { recursive: true, force: true });
}
