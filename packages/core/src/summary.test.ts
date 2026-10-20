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
});
