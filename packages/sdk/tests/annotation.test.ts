import { describe, expect, it } from 'vitest';
import {
  ANNOTATION_FADE_AFTER_MS,
  ANNOTATION_FADE_DURATION_MS,
  annotationOpacity,
  appendPointerSamples,
  normalizedPoint,
  pointerSamples,
  type NormalizedPoint,
  type PointerSample,
} from '../src/annotation';

function sample(clientX: number, clientY: number): PointerSample {
  return { clientX, clientY };
}

describe('annotation points', () => {
  it('normalizes against the viewport and clamps off-screen coordinates', () => {
    expect(normalizedPoint(500, 400, 1_000, 800)).toEqual({ x: 0.5, y: 0.5 });
    expect(normalizedPoint(-20, 900, 1_000, 800)).toEqual({ x: 0, y: 1 });
  });

  it('keeps every coalesced pointer sample so fast strokes stay complete', () => {
    const event: PointerSample = {
      clientX: 400,
      clientY: 400,
      getCoalescedEvents: () => [sample(100, 100), sample(250, 200), sample(400, 400)],
    };

    expect(pointerSamples(event, 1_000, 800)).toEqual([
      { x: 0.1, y: 0.125 },
      { x: 0.25, y: 0.25 },
      { x: 0.4, y: 0.5 },
    ]);
  });

  it('does not duplicate the dispatched event when coalesced samples already include it', () => {
    const event: PointerSample = {
      clientX: 400,
      clientY: 400,
      getCoalescedEvents: () => [sample(100, 100), sample(400, 400)],
    };

    expect(pointerSamples(event, 1_000, 800)).toHaveLength(2);
  });

  it('falls back to the event when the browser exposes no coalesced samples', () => {
    expect(pointerSamples(sample(300, 240), 1_000, 800)).toEqual([{ x: 0.3, y: 0.3 }]);
  });

  it('appends across move events without repeating the last point', () => {
    const points: NormalizedPoint[] = [{ x: 0.1, y: 0.1 }];
    appendPointerSamples(points, sample(100, 80), 1_000, 800);
    appendPointerSamples(points, sample(200, 160), 1_000, 800);
    appendPointerSamples(points, sample(200, 160), 1_000, 800);

    expect(points).toEqual([
      { x: 0.1, y: 0.1 },
      { x: 0.2, y: 0.2 },
    ]);
  });

  it('keeps annotations opaque for two seconds before fading them out', () => {
    expect(ANNOTATION_FADE_AFTER_MS).toBe(2_000);
    expect(annotationOpacity(0)).toBe(1);
    expect(annotationOpacity(ANNOTATION_FADE_AFTER_MS)).toBe(1);
    expect(annotationOpacity(ANNOTATION_FADE_AFTER_MS + ANNOTATION_FADE_DURATION_MS / 2)).toBe(0.5);
    expect(annotationOpacity(ANNOTATION_FADE_AFTER_MS + ANNOTATION_FADE_DURATION_MS)).toBe(0);
    expect(annotationOpacity(60_000)).toBe(0);
  });
});
