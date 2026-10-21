import { describe, expect, it } from 'vitest';
import { SessionTimeline } from './index';

describe('SessionTimeline', () => {
  it('uses one monotonic origin and preserves insertion order', () => {
    let time = 100;
    let id = 0;
    const timeline = new SessionTimeline({
      clock: { now: () => time },
      createId: () => `event-${id++}`,
    });

    time = 125;
    const mark = timeline.record('mark', { label: 'Metric' });
    time = 190;
    const click = timeline.record('click', { button: 0 }, 'target-1');

    expect(mark).toMatchObject({ id: 'event-0', seq: 0, atMs: 25, kind: 'mark' });
    expect(click).toMatchObject({
      id: 'event-1',
      seq: 1,
      atMs: 90,
      kind: 'click',
      targetId: 'target-1',
    });
    expect(timeline.snapshot()).toHaveLength(2);
  });

  it('rounds monotonic time to whole milliseconds for the compiler contract', () => {
    let time = 100;
    const timeline = new SessionTimeline({
      clock: { now: () => time },
      createId: () => 'event-0',
    });

    time = 125.6;
    expect(timeline.now()).toBe(26);
    expect(timeline.record('mark').atMs).toBe(26);
  });

  it('does not return its mutable event payloads from snapshots', () => {
    const timeline = new SessionTimeline({
      clock: { now: () => 0 },
      createId: () => 'event-0',
    });
    timeline.record('context', { page: 'dashboard' });

    const snapshot = timeline.snapshot();
    snapshot[0]!.payload.page = 'changed';

    expect(timeline.snapshot()[0]!.payload.page).toBe('dashboard');
  });
});
