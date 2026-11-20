import { describe, expect, it } from 'vitest';
import { buildSummary, type HighliteManifest } from './index';

function createManifest(): HighliteManifest {
  return {
    schemaVersion: '0.1.0',
    sessionId: 'session-1',
    createdAt: '2026-10-20T00:00:00.000Z',
    page: { initialUrl: 'https://example.test/analytics?token=secret', title: 'Analytics' },
    durationMs: 1500,
    timeline: [
      { id: 'event-1', seq: 0, atMs: 1000, kind: 'mark', payload: { label: 'Net retention' } },
    ],
    targets: [],
    annotations: [],
    transcript: [],
    keyframes: [],
    artifacts: {},
    captureWarnings: [],
  };
}

describe('buildSummary', () => {
  it('produces a deterministic summary without exposing query strings', () => {
    const summary = buildSummary(createManifest());

    expect(summary).toContain('Page: /analytics — Analytics');
    expect(summary).toContain('00:01 — Mark: Net retention');
    expect(summary).not.toContain('secret');
    expect(summary).toContain('Visual evidence: unavailable');
    expect(summary).not.toContain('Video:');
  });

  it('points at a bundled video artifact when the capture includes one', () => {
    const manifest = createManifest();
    manifest.artifacts.video = 'media/recording.mp4';

    const summary = buildSummary(manifest);

    expect(summary).toContain('Video: recording.mp4');
    expect(summary).not.toContain('media/recording.mp4');
  });

  it('associates a nearby explicit mark with its real frame path', () => {
    const manifest = createManifest();
    manifest.keyframes.push({
      id: 'frame-1',
      atMs: 1010,
      imagePath: 'frames/0001.png',
      targetIds: [],
      annotationIds: [],
      transcriptSegmentIds: [],
      reason: 'mark',
    });

    const summary = buildSummary(manifest);

    expect(summary).toContain('### 00:01 — Net retention');
    expect(summary).toContain('![Frame 1](frames/0001.png)');
    expect(summary).not.toContain('Visual evidence: unavailable');
  });

  it('describes semantic form activity and omits internal target rows', () => {
    const manifest = createManifest();
    manifest.timeline = [
      {
        id: 'event-env',
        seq: 0,
        atMs: 0,
        kind: 'context',
        payload: { scope: 'environment', value: 'Chrome 141 · Linux · viewport 1440×1000' },
      },
      {
        id: 'event-target',
        seq: 1,
        atMs: 100,
        kind: 'target',
        targetId: 't1',
        payload: { role: 'textbox' },
      },
      {
        id: 'event-input',
        seq: 2,
        atMs: 200,
        kind: 'input',
        targetId: 't1',
        payload: { fieldKind: 'text', fieldType: 'search', filled: true, valueCaptured: false },
      },
      {
        id: 'event-change',
        seq: 3,
        atMs: 300,
        kind: 'change',
        targetId: 't1',
        payload: {
          fieldKind: 'checkbox',
          fieldType: 'checkbox',
          checked: true,
          valueCaptured: false,
        },
      },
      {
        id: 'event-submit',
        seq: 4,
        atMs: 400,
        kind: 'submit',
        targetId: 't2',
        payload: { submitterLabel: 'Apply' },
      },
    ];
    manifest.targets = [
      {
        id: 't1',
        label: 'Search metrics',
        selector: '#search',
        rect: { x: 0, y: 0, width: 10, height: 10 },
        pageUrl: 'https://example.test/',
      },
      {
        id: 't2',
        label: 'Filters',
        selector: '#filters',
        rect: { x: 0, y: 0, width: 10, height: 10 },
        pageUrl: 'https://example.test/',
      },
    ];

    const summary = buildSummary(manifest);

    expect(summary).toContain('Environment: Chrome 141 · Linux · viewport 1440×1000');
    expect(summary).toContain('Entered text in field — Search metrics');
    expect(summary).toContain('Checked “Search metrics”');
    expect(summary).toContain('Submitted form “Filters” via “Apply”');
    expect(summary).not.toContain('target —');
    expect(summary).not.toContain('retention');
  });

  it('lists every selected option for a multiple select', () => {
    const manifest = createManifest();
    manifest.targets = [
      {
        id: 't1',
        label: 'Categories',
        selector: '#categories',
        rect: { x: 0, y: 0, width: 10, height: 10 },
        pageUrl: 'https://example.test/',
      },
    ];
    manifest.timeline = [
      {
        id: 'event-change',
        seq: 0,
        atMs: 100,
        kind: 'change',
        targetId: 't1',
        payload: {
          fieldKind: 'select',
          fieldType: 'select',
          valueCaptured: true,
          optionLabels: ['Retention', 'Churn'],
        },
      },
      {
        id: 'event-cleared',
        seq: 1,
        atMs: 200,
        kind: 'change',
        targetId: 't1',
        payload: {
          fieldKind: 'select',
          fieldType: 'select',
          valueCaptured: true,
          optionLabels: [],
        },
      },
      {
        id: 'event-default',
        seq: 2,
        atMs: 300,
        kind: 'change',
        targetId: 't1',
        payload: {
          fieldKind: 'select',
          fieldType: 'select',
          valueCaptured: false,
          optionLabels: ['Not captured'],
        },
      },
    ];

    const summary = buildSummary(manifest);

    expect(summary).toContain('Selected “Retention”, “Churn” in Categories');
    expect(summary).toContain('Cleared selection in Categories');
    expect(summary).not.toContain('Not captured');
  });

  it('shows opt-in values only when the event marks them captured', () => {
    const manifest = createManifest();
    manifest.targets = [
      {
        id: 't1',
        label: 'Search metrics',
        selector: '#search',
        rect: { x: 0, y: 0, width: 10, height: 10 },
        pageUrl: 'https://example.test/',
      },
    ];
    manifest.timeline = [
      {
        id: 'event-input',
        seq: 0,
        atMs: 100,
        kind: 'input',
        targetId: 't1',
        payload: {
          fieldKind: 'text',
          fieldType: 'search',
          filled: true,
          valueCaptured: true,
          value: 'retention',
        },
      },
    ];

    expect(buildSummary(manifest)).toContain('Entered “retention” in field — Search metrics');
  });
});
