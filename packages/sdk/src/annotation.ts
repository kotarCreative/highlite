import type { Annotation } from '@highlite/core';

/** Must match the stroke used by the toolbar canvas. */
export const ANNOTATION_LINE_WIDTH = 4;
export const ANNOTATION_ARROW_HEAD = 14;
/** Keep a fresh annotation fully visible for four seconds, then fade the overlay out. */
export const ANNOTATION_FADE_AFTER_MS = 4_000;
export const ANNOTATION_FADE_DURATION_MS = 400;

export type NormalizedPoint = Annotation['points'][number];

/** Opacity of an annotation after `ageMs` on screen. */
export function annotationOpacity(ageMs: number): number {
  if (ageMs <= ANNOTATION_FADE_AFTER_MS) return 1;
  const faded = (ageMs - ANNOTATION_FADE_AFTER_MS) / ANNOTATION_FADE_DURATION_MS;
  return Math.max(0, 1 - faded);
}

export interface PointerSample {
  clientX: number;
  clientY: number;
  getCoalescedEvents?: () => readonly PointerSample[];
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

export function normalizedPoint(
  clientX: number,
  clientY: number,
  width: number,
  height: number,
): NormalizedPoint {
  return {
    x: clamp01(clientX / Math.max(1, width)),
    y: clamp01(clientY / Math.max(1, height)),
  };
}

/**
 * Browsers coalesce several physical samples into one `pointermove`. Reading only
 * `event.clientX/Y` drops those samples, which shortens fast freehand strokes.
 * Keep every coalesced sample and drop exact duplicates.
 */
export function pointerSamples(
  event: PointerSample,
  width: number,
  height: number,
): NormalizedPoint[] {
  const coalesced = event.getCoalescedEvents?.() ?? [];
  const samples = [...coalesced];
  const last = samples.at(-1);
  if (!last || last.clientX !== event.clientX || last.clientY !== event.clientY) {
    samples.push(event);
  }

  return samples.reduce<NormalizedPoint[]>((points, sample) => {
    const point = normalizedPoint(sample.clientX, sample.clientY, width, height);
    const previous = points.at(-1);
    if (!previous || previous.x !== point.x || previous.y !== point.y) points.push(point);
    return points;
  }, []);
}

/** Append a pointer event's samples to a draft stroke without duplicating its last point. */
export function appendPointerSamples(
  points: NormalizedPoint[],
  event: PointerSample,
  width: number,
  height: number,
): void {
  for (const point of pointerSamples(event, width, height)) {
    const last = points.at(-1);
    if (!last || last.x !== point.x || last.y !== point.y) points.push(point);
  }
}
