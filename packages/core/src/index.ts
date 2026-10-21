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

export interface ViewportRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Target {
  id: string;
  tag?: string;
  role?: string;
  label?: string;
  textExcerpt?: string;
  selector?: string;
  rect: ViewportRect;
  pageUrl: string;
  metadata?: Record<string, string | number | boolean>;
}

export type AnnotationKind = 'freehand' | 'circle' | 'arrow' | 'highlight';

export interface Annotation {
  id: string;
  atMs: number;
  kind: AnnotationKind;
  points: Array<{ x: number; y: number }>;
  coordinateSpace: 'viewport-normalized';
  targetId?: string;
}

export interface TranscriptSegment {
  id?: string;
  startMs: number;
  endMs: number;
  text: string;
  wordTimings?: Array<{ startMs: number; endMs: number; text: string }>;
}

export interface Keyframe {
  id: string;
  atMs: number;
  imagePath: string;
  targetIds: string[];
  annotationIds: string[];
  transcriptSegmentIds: string[];
  reason: 'mark' | 'annotation' | 'interaction' | 'visual-change' | 'speech-cue';
}

export interface HighliteManifest {
  schemaVersion: '0.1.0';
  sessionId: string;
  createdAt: string;
  page: { initialUrl: string; title: string };
  viewport?: ViewportRect;
  durationMs: number;
  timeline: TimelineEvent[];
  targets: Target[];
  annotations: Annotation[];
  transcript: TranscriptSegment[];
  keyframes: Keyframe[];
  artifacts: { audio?: string; video?: string; contactSheet?: string };
  audioOffsetMs?: number;
  captureWarnings: string[];
}

export interface HighliteBundle {
  manifest: HighliteManifest;
  summary: string;
  files: Record<string, Blob>;
}

export interface RawCapture {
  manifest: HighliteManifest;
  files: Record<string, Blob>;
}

export interface Processor {
  process(input: RawCapture): Promise<HighliteBundle>;
}

export interface Transcriber {
  transcribe(audio: Blob): Promise<TranscriptSegment[]>;
}

export interface FrameProvider {
  start(): Promise<void>;
  capture(atMs: number): Promise<Blob | null>;
  stop(): Promise<void>;
  onEnded?(handler: () => void): () => void;
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
  if (typeof globalThis.crypto?.randomUUID === 'function') return globalThis.crypto.randomUUID();
  return `event-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
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
    return Math.max(0, Math.round(this.#clock.now() - this.#origin));
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

export { buildSummary } from './summary';
