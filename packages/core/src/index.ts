export type TimelineKind =
  | 'click'
  | 'scroll'
  | 'navigate'
  | 'annotation'
  | 'mark'
  | 'target'
  | 'context';

export interface TimelineEvent {
  id: string;
  seq: number;
  atMs: number;
  kind: TimelineKind;
  targetId?: string;
  payload: Record<string, unknown>;
}

export interface MonotonicClock {
  now(): number;
}

export interface TimelineOptions {
  clock?: MonotonicClock;
  createId?: () => string;
}

const defaultClock: MonotonicClock = {
  now: () => globalThis.performance.now(),
};

function defaultId(): string {
  return globalThis.crypto.randomUUID();
}

export class SessionTimeline {
  readonly #clock: MonotonicClock;
  readonly #createId: () => string;
  readonly #origin: number;
  readonly #events: TimelineEvent[] = [];
  #sequence = 0;

  constructor(options: TimelineOptions = {}) {
    this.#clock = options.clock ?? defaultClock;
    this.#createId = options.createId ?? defaultId;
    this.#origin = this.#clock.now();
  }

  now(): number {
    return Math.max(0, this.#clock.now() - this.#origin);
  }

  record(
    kind: TimelineKind,
    payload: Record<string, unknown> = {},
    targetId?: string,
  ): TimelineEvent {
    const event: TimelineEvent = {
      id: this.#createId(),
      seq: this.#sequence++,
      atMs: this.now(),
      kind,
      ...(targetId === undefined ? {} : { targetId }),
      payload,
    };

    this.#events.push(event);
    return event;
  }

  snapshot(): TimelineEvent[] {
    return this.#events.map((event) => ({ ...event, payload: { ...event.payload } }));
  }
}
