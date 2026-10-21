// Opt-in end-to-end test for the Parakeet transcriber.
//
// It runs the real path: capture manifest + audio -> ffmpeg -> parakeet-cli
// -> compiler bundle (transcript, crops, annotated frames, contact sheet).
//
// Required:
//   HIGHLITE_PARAKEET_BIN    path to parakeet-cli
//   HIGHLITE_PARAKEET_MODEL  path to a Parakeet .gguf
//
// Optional:
//   HIGHLITE_ASR_AUDIO       a speech WAV to use instead of the small fixture
//   HIGHLITE_COMPILER        compiler binary (default target/release/highlite-compiler)
//   HIGHLITE_REQUIRE_ASR=1   fail instead of skipping when the above are missing

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const binaryName = process.platform === 'win32' ? 'highlite-compiler.exe' : 'highlite-compiler';
const compiler = process.env.HIGHLITE_COMPILER ?? join(root, 'target/release', binaryName);
const parakeet = process.env.HIGHLITE_PARAKEET_BIN;
const model = process.env.HIGHLITE_PARAKEET_MODEL;
const required = process.env.HIGHLITE_REQUIRE_ASR === '1';

const FIXTURE_URL =
  'https://raw.githubusercontent.com/mudler/parakeet.cpp/master/tests/fixtures/speech.wav';

// A 640x360 placeholder UI frame so rendering, cropping, and the contact sheet
// all run. The pixels do not matter; the pipeline does.
const FRAME_PNG = Buffer.from(
  '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',
  'base64',
);

function skipOrFail(message) {
  if (required) {
    console.error(`Parakeet e2e: ${message}`);
    process.exit(1);
  }
  console.log(`Parakeet e2e skipped: ${message}`);
  process.exit(0);
}

if (!parakeet || !model) {
  skipOrFail(
    [
      'set HIGHLITE_PARAKEET_BIN and HIGHLITE_PARAKEET_MODEL.',
      '  parakeet-cli: https://github.com/mudler/parakeet.cpp/releases',
      '  model: curl -LO https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt_ctc-110m-q8_0.gguf',
      'Set HIGHLITE_REQUIRE_ASR=1 to fail instead of skipping.',
    ].join('\n'),
  );
}
for (const [label, path] of [
  ['parakeet-cli', parakeet],
  ['Parakeet model', model],
]) {
  if (!existsSync(path)) {
    console.error(`Parakeet e2e: ${label} was not found at ${path}.`);
    process.exit(1);
  }
}
if (!existsSync(compiler)) {
  console.error(`Parakeet e2e: the compiler was not found at ${compiler}. Run pnpm build:rust.`);
  process.exit(1);
}

function wavDurationMs(buffer) {
  if (buffer.toString('ascii', 0, 4) !== 'RIFF' || buffer.toString('ascii', 8, 12) !== 'WAVE') {
    return null;
  }
  let offset = 12;
  let byteRate = 0;
  let dataSize = 0;
  while (offset + 8 <= buffer.length) {
    const id = buffer.toString('ascii', offset, offset + 4);
    const size = buffer.readUInt32LE(offset + 4);
    if (id === 'fmt ') byteRate = buffer.readUInt32LE(offset + 16);
    if (id === 'data') {
      dataSize = size;
      break;
    }
    offset += 8 + size + (size % 2);
  }
  return byteRate > 0 ? Math.round((dataSize / byteRate) * 1000) : null;
}

async function ensureAudio() {
  if (process.env.HIGHLITE_ASR_AUDIO) {
    const path = process.env.HIGHLITE_ASR_AUDIO;
    if (!existsSync(path)) {
      throw new Error(`HIGHLITE_ASR_AUDIO was not found at ${path}.`);
    }
    return path;
  }

  const cache = join(process.env.XDG_CACHE_HOME ?? join(homedir(), '.cache'), 'highlite', 'asr');
  const path = join(cache, 'parakeet-speech.wav');
  if (existsSync(path) && statSync(path).size > 1_000) return path;

  console.log('Downloading the parakeet.cpp speech fixture...');
  const response = await fetch(FIXTURE_URL);
  if (!response.ok) {
    throw new Error(`Could not download ${FIXTURE_URL}: HTTP ${response.status}.`);
  }
  mkdirSync(cache, { recursive: true });
  writeFileSync(path, Buffer.from(await response.arrayBuffer()));
  return path;
}

function writeCapture(directory, audioPath, durationMs) {
  mkdirSync(join(directory, 'frames'), { recursive: true });
  const framePaths = [1, 2, 3].map((index) => {
    const relative = `frames/000${index}.png`;
    writeFileSync(join(directory, relative), FRAME_PNG);
    return relative;
  });
  copyFileSync(audioPath, join(directory, 'audio.wav'));

  const times = [0.15, 0.45, 0.75].map((fraction) => Math.round(durationMs * fraction));
  const manifest = {
    schemaVersion: '0.1.0',
    sessionId: 'parakeet-e2e',
    createdAt: new Date().toISOString(),
    page: { initialUrl: 'https://app.example.com/analytics', title: 'Parakeet e2e' },
    viewport: { x: 0, y: 0, width: 640, height: 360 },
    durationMs,
    timeline: [
      {
        id: 'click',
        seq: 0,
        atMs: times[0],
        kind: 'click',
        targetId: 'metric',
        payload: { button: 0, x: 200, y: 120 },
      },
      {
        id: 'mark',
        seq: 1,
        atMs: times[1],
        kind: 'mark',
        targetId: 'metric',
        payload: { label: 'The number' },
      },
      {
        id: 'annotation',
        seq: 2,
        atMs: times[2],
        kind: 'annotation',
        targetId: 'metric',
        payload: { annotationId: 'circle', annotationKind: 'circle', x: 430, y: 140 },
      },
    ],
    targets: [
      {
        id: 'metric',
        tag: 'div',
        role: 'img',
        label: 'Retention metric',
        selector: '.metric',
        rect: { x: 70, y: 80, width: 470, height: 120 },
        pageUrl: 'https://app.example.com/analytics',
        metadata: { docsId: 'analytics.net-retention' },
      },
    ],
    annotations: [
      {
        id: 'circle',
        atMs: times[2],
        kind: 'circle',
        points: [
          { x: 0.67, y: 0.22 },
          { x: 0.86, y: 0.56 },
        ],
        coordinateSpace: 'viewport-normalized',
        targetId: 'metric',
      },
    ],
    transcript: [],
    keyframes: [
      {
        id: 'k1',
        atMs: times[0],
        imagePath: framePaths[0],
        targetIds: ['metric'],
        annotationIds: [],
        transcriptSegmentIds: [],
        reason: 'interaction',
      },
      {
        id: 'k2',
        atMs: times[1],
        imagePath: framePaths[1],
        targetIds: ['metric'],
        annotationIds: [],
        transcriptSegmentIds: [],
        reason: 'mark',
      },
      {
        id: 'k3',
        atMs: times[2],
        imagePath: framePaths[2],
        targetIds: ['metric'],
        annotationIds: ['circle'],
        transcriptSegmentIds: [],
        reason: 'annotation',
      },
    ],
    artifacts: { audio: 'audio.wav' },
    audioOffsetMs: 0,
    captureWarnings: [],
  };

  writeFileSync(join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2));
}

const work = mkdtempSync(join(tmpdir(), 'highlite-parakeet-'));
try {
  const audio = await ensureAudio();
  const durationMs = Math.max(2_000, (wavDurationMs(readFileSync(audio)) ?? 8_000) + 500);
  const capture = join(work, 'capture');
  const output = join(work, 'bundle');
  writeCapture(capture, audio, durationMs);

  const started = Date.now();
  const result = spawnSync(
    compiler,
    [
      'bundle',
      capture,
      '--out',
      output,
      '--transcribe',
      'parakeet',
      '--parakeet',
      parakeet,
      '--parakeet-model',
      model,
      '--contact-sheet-width',
      '800',
    ],
    { encoding: 'utf8' },
  );
  const elapsed = Date.now() - started;

  if (result.status !== 0) {
    throw new Error(
      `compiler bundle failed (${result.status}):\n${result.stderr || result.stdout || ''}`,
    );
  }

  const manifest = JSON.parse(readFileSync(join(output, 'manifest.json'), 'utf8'));
  const summary = readFileSync(join(output, 'summary.md'), 'utf8');
  const scrawl = JSON.parse(readFileSync(join(output, 'scrawl.json'), 'utf8'));
  const text = manifest.transcript.map((segment) => segment.text).join(' ');
  const lower = text.toLowerCase();

  assert.ok(manifest.transcript.length > 0, 'Parakeet must produce at least one segment.');
  assert.ok(text.split(/\s+/).length >= 5, `Transcript is too short: ${JSON.stringify(text)}`);
  const keywords = ['portrait', 'phoebe', 'wish', 'eyes', 'observed'];
  assert.ok(
    keywords.filter((word) => lower.includes(word)).length >= 2,
    `Transcript does not look like the fixture: ${JSON.stringify(text)}`,
  );

  for (const segment of manifest.transcript) {
    assert.ok(Number.isInteger(segment.startMs) && segment.startMs >= 0);
    assert.ok(Number.isInteger(segment.endMs) && segment.endMs > segment.startMs);
    assert.ok(segment.endMs <= manifest.durationMs, 'A segment outlived the capture.');
    for (const word of segment.wordTimings ?? []) {
      assert.ok(word.startMs >= 0 && word.endMs > word.startMs);
      assert.ok(word.endMs <= manifest.durationMs, 'A word outlived the capture.');
    }
  }

  assert.match(summary, /^\[highlite /);
  assert.match(summary, /- #\d+ \(/);
  assert.ok(
    summary.toLowerCase().includes('portrait') ||
      summary.toLowerCase().includes('phoebe') ||
      summary.toLowerCase().includes('narration'),
    'summary.md must carry the narration.',
  );
  assert.ok(existsSync(join(output, 'frames/frame-01.png')), 'frames must be rendered.');
  assert.ok(existsSync(join(output, 'contact-sheet.png')), 'the contact sheet must exist.');
  assert.ok(scrawl.keyframes.length > 0);
  assert.ok(scrawl.keyframes.every((frame) => frame.file.startsWith('frames/')));

  console.log(`Parakeet e2e passed in ${elapsed} ms.`);
  console.log(`Transcript: ${text.slice(0, 180)}${text.length > 180 ? '…' : ''}`);
} catch (error) {
  console.error(`Parakeet e2e failed: ${error instanceof Error ? error.message : error}`);
  process.exitCode = 1;
} finally {
  rmSync(work, { recursive: true, force: true });
}
