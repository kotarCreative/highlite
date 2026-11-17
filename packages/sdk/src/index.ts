import JSZip from 'jszip';
import {
  SessionTimeline,
  buildSummary,
  type Annotation,
  type AnnotationKind,
  type FrameProvider,
  type HighliteBundle,
  type HighliteManifest,
  type MonotonicClock,
  type Processor,
  type Target,
} from '@highlite/core';
import {
  ANNOTATION_FADE_AFTER_MS,
  ANNOTATION_FADE_DURATION_MS,
  ANNOTATION_LINE_WIDTH,
} from './annotation';
import { describeEnvironment } from './environment';
import {
  accessibleLabel,
  changePayload,
  classifyField,
  contentEditableHost,
  fieldDescriptor,
  isFieldElement,
  isSubmitControlDescriptor,
  readableTextExcerpt,
  submitPayload,
  textEditPayload,
  TextEditCoalescer,
  type FieldClassification,
} from './form';
import { DisplayMediaFrameProvider } from './frame-provider';
import { CaptureToolbar, type PermissionDecision, type PermissionRequest } from './toolbar';

export type {
  Annotation,
  AnnotationKind,
  FrameProvider,
  HighliteBundle,
  HighliteManifest,
  Keyframe,
  Processor,
  Target,
  TimelineEvent,
  TimelineKind,
  TranscriptSegment,
  Transcriber,
} from '@highlite/core';

export interface HighliteOptions {
  mount?: HTMLElement;
  ui?: 'floating' | 'headless';
  zIndex?: number;
  capture?: {
    microphone?: boolean;
    frames?: 'none' | 'prompt';
    interactions?: boolean;
    /**
     * Include values for supported, non-sensitive form fields. Disabled by default.
     * Password, hidden, file, private, disabled and secret-like fields are always excluded.
     */
    formValues?: boolean;
    disabledRoutes?: string[];
  };
  privacy?: {
    redactSelectors?: string[];
    disableSelectors?: string[];
    includeQueryString?: boolean;
  };
  relay?: RelayOptions;
  frameProvider?: FrameProvider;
  processor?: Processor;
  clock?: MonotonicClock;
  onComplete?: (bundle: HighliteBundle) => void | Promise<void>;
}

export interface RelayOptions {
  /** Full URL of the relay ingest endpoint, for example https://relay.example.com/v1/sessions. */
  endpoint: string;
  /** Bearer token. Treat this as a browser-visible ingest capability. */
  token?: string;
  /** Upload automatically after a session stops. Defaults to true when relay is configured. */
  autoUpload?: boolean;
  /** Abort an upload after this many milliseconds. Defaults to 120000. */
  timeoutMs?: number;
}

export interface RelayUploadResult {
  sessionId: string;
  status: string;
  statusUrl?: string;
  bundleUrl?: string;
  summary?: string;
}

export interface HighliteEvents {
  ready: { sessionId: string };
  'recording-started': { sessionId: string; microphone: 'active' | 'denied' | 'disabled' };
  'annotation-added': { annotation: Annotation };
  'target-selected': { target: Target };
  'mark-added': { label: string; atMs: number };
  'recording-stopped': { durationMs: number };
  'processing-started': { sessionId: string };
  'processing-complete': { bundle: HighliteBundle };
  'relay-uploaded': { result: RelayUploadResult };
  'relay-failed': { error: unknown; message: string };
  error: { error: unknown; message: string };
  cancelled: { sessionId: string };
}

export type HighliteEventName = keyof HighliteEvents;
export type HighliteEventHandler<K extends HighliteEventName> = (
  payload: HighliteEvents[K],
) => void;

export interface HighliteController {
  start(): Promise<void>;
  stop(): Promise<HighliteBundle>;
  cancel(): Promise<void>;
  mark(label?: string): Promise<void>;
  context(scope: string, value: string): void;
  registerTarget(selector: string, metadata: Record<string, string | number | boolean>): () => void;
  on<K extends HighliteEventName>(event: K, handler: HighliteEventHandler<K>): this;
  off<K extends HighliteEventName>(event: K, handler: HighliteEventHandler<K>): this;
  export(options?: { download?: boolean }): Promise<Blob>;
  upload(): Promise<RelayUploadResult>;
  destroy(): Promise<void>;
}

type CaptureState =
  | 'idle'
  | 'starting'
  | 'recording'
  | 'processing'
  | 'stopped'
  | 'cancelled'
  | 'destroyed';
type MicrophoneState = 'active' | 'denied' | 'disabled';

interface PermissionStep extends Omit<PermissionRequest, 'step' | 'total'> {
  waitingMessage: string;
}

/**
 * A submit-control click is held until the current task finishes. If the browser fires
 * `submit`, the click is redundant; if validation or a click handler blocks submission,
 * the click is the only evidence of the failed attempt.
 */
interface PendingSubmitClick {
  form: HTMLFormElement;
  target: Target | undefined;
  button: number;
  x: number;
  y: number;
  timer: number;
}

const MICROPHONE_PERMISSION: PermissionStep = {
  kind: 'microphone',
  title: 'Microphone',
  description:
    'Highlite records your spoken explanation so an agent can follow the reasoning behind each interaction, not just the clicks.',
  details: [
    'Audio is recorded in this tab only while a Highlite session is running.',
    'The SDK does not upload audio by itself.',
  ],
  allowLabel: 'Allow microphone',
  skipLabel: 'Continue without audio',
  waitingMessage: 'Waiting for your browser to confirm microphone access…',
};

const DISPLAY_PERMISSION: PermissionStep = {
  kind: 'display',
  title: 'Current tab',
  description:
    'Highlite saves a few still screenshots at the moments that matter so an agent can see the page you were describing.',
  details: [
    'Only still frames at clicks, marks, and annotations — not continuous video.',
    'The current tab is preselected in the browser share picker; confirm it to continue.',
    'Shared screen pixels are not automatically redacted, so avoid sensitive content.',
  ],
  allowLabel: 'Share this tab',
  skipLabel: 'Continue without screenshots',
  waitingMessage: 'Waiting for your browser to confirm screen sharing…',
};

const DEFAULT_REDACT_SELECTORS = [
  '[data-private]',
  '[data-highlite-private]',
  'input[type="password"]',
];

const FORM_EDIT_IDLE_MS = 500;

function createId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') return globalThis.crypto.randomUUID();
  return `hl-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

function safeMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'An unknown Highlite error occurred.';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function textExcerpt(value: string | null | undefined): string | undefined {
  const text = value?.replace(/\s+/g, ' ').trim();
  if (!text) return undefined;
  return text.length > 160 ? `${text.slice(0, 157)}…` : text;
}

function implicitRole(element: Element): string | undefined {
  const tag = element.tagName.toLowerCase();
  if (tag === 'button') return 'button';
  if (tag === 'a' && element.hasAttribute('href')) return 'link';
  if (tag === 'select') return element.hasAttribute('multiple') ? 'listbox' : 'combobox';
  if (tag === 'textarea') return 'textbox';
  if (tag === 'form') return 'form';
  if (tag === 'input') {
    const type = (element.getAttribute('type') ?? 'text').toLowerCase();
    if (type === 'checkbox' || type === 'radio' || type === 'button' || type === 'submit')
      return type;
    return 'textbox';
  }
  if (tag === 'img') return 'img';
  return undefined;
}

function extensionForMime(mimeType: string, fallback: string): string {
  if (mimeType.includes('png')) return 'png';
  if (mimeType.includes('jpeg') || mimeType.includes('jpg')) return 'jpg';
  if (mimeType.includes('webp')) return 'webp';
  if (mimeType.includes('mp4')) return 'mp4';
  if (mimeType.includes('ogg')) return 'ogg';
  if (mimeType.includes('webm')) return 'webm';
  return fallback;
}

class Highlite implements HighliteController {
  #sessionId = createId();
  readonly #options: HighliteOptions;
  readonly #captureOptions: NonNullable<HighliteOptions['capture']>;
  readonly #privacyOptions: NonNullable<HighliteOptions['privacy']>;
  readonly #frameProvider: FrameProvider | undefined;
  readonly #listeners = new Map<HighliteEventName, Set<HighliteEventHandler<HighliteEventName>>>();
  readonly #files: Record<string, Blob> = {};
  readonly #targets = new Map<string, Target>();
  #elementIds = new WeakMap<Element, string>();
  readonly #registeredTargets = new Map<string, Record<string, string | number | boolean>>();
  readonly #annotations: Annotation[] = [];
  readonly #keyframes: HighliteManifest['keyframes'] = [];
  readonly #warnings: string[] = [];
  readonly #audioChunks: Blob[] = [];
  readonly #pendingCaptures = new Set<Promise<void>>();
  readonly #interactionTimers = new Set<number>();
  readonly #pendingSubmitClicks = new Set<PendingSubmitClick>();
  readonly #textEdits = new TextEditCoalescer();
  readonly #formFields = new Map<string, FieldClassification>();
  readonly #keyframeOrder = new Map<string, number>();
  readonly #frameEndUnsubscribe: (() => void) | undefined;
  #toolbar: CaptureToolbar | undefined;
  readonly #interactionCleanups: Array<() => void> = [];
  #timeline: SessionTimeline | undefined;
  #state: CaptureState = 'idle';
  #sessionToken = 0;
  #microphoneState: MicrophoneState = 'disabled';
  #audioStream: MediaStream | undefined;
  #recorder: MediaRecorder | undefined;
  #audioBlob: Blob | undefined;
  #audioOffsetMs: number | undefined;
  #bundle: HighliteBundle | undefined;
  #startPromise: Promise<void> | undefined;
  #interactionAttached = false;
  #scrollTimer: number | undefined;
  #formEditTimer: number | undefined;
  #lastTargetId: string | undefined;
  #lastUrl = '';
  #routeUnsubscribe: (() => void) | undefined;
  #initialPage: HighliteManifest['page'] | undefined;
  #initialViewport: HighliteManifest['viewport'] | undefined;
  #createdAt = '';
  #frameAvailable = false;
  #nextKeyframeOrder = 0;

  constructor(options: HighliteOptions) {
    this.#options = options;
    this.#captureOptions = options.capture ?? {};
    this.#privacyOptions = options.privacy ?? {};
    this.#frameProvider =
      options.frameProvider ??
      (this.#captureOptions.frames === 'none' ? undefined : new DisplayMediaFrameProvider());
    this.#frameEndUnsubscribe = this.#frameProvider?.onEnded?.(() => {
      this.#frameAvailable = false;
      this.#addWarning(
        'Display sharing ended before Highlite stopped; no later visual frames are available.',
      );
      this.#toolbar?.setStatus(
        'Display sharing ended. Audio and web context can still be recorded.',
      );
    });

    if (options.ui !== 'headless') {
      const mount = options.mount ?? document.body;
      this.#toolbar = new CaptureToolbar(mount, {
        zIndex: options.zIndex ?? 2147483000,
        onStart: () => void this.start().catch((error: unknown) => this.#reportError(error)),
        onMark: () => void this.mark().catch((error: unknown) => this.#reportError(error)),
        onStop: () => void this.stop().catch((error: unknown) => this.#reportError(error)),
        onCancel: () => void this.cancel().catch((error: unknown) => this.#reportError(error)),
        onAnnotation: (kind, points, clientX, clientY, target) =>
          void this.#addAnnotation(kind, points, clientX, clientY, target),
        onAnnotatingChange: (annotating) => {
          if (!annotating) this.#toolbar?.setStatus('Interact mode. Page controls work normally.');
        },
      });
    }

    queueMicrotask(() => this.#emit('ready', { sessionId: this.#sessionId }));
  }

  async start(): Promise<void> {
    if (
      this.#state === 'starting' ||
      this.#state === 'recording' ||
      this.#state === 'processing' ||
      this.#state === 'destroyed'
    ) {
      throw new Error('This Highlite controller is already running a session.');
    }
    if (this.#isDisabledRoute(location.pathname)) {
      throw new Error('Highlite is disabled on this route.');
    }
    // A cancelled start may still be unwinding a pending permission prompt.
    if (this.#startPromise) await this.#startPromise.catch(() => undefined);

    if (this.#state !== 'idle') this.#sessionId = createId();
    this.#resetSession();
    this.#state = 'starting';
    this.#timeline = new SessionTimeline(
      this.#options.clock ? { clock: this.#options.clock } : undefined,
    );
    this.#lastUrl = this.#safeUrl(location.href);
    this.#initialPage = { initialUrl: this.#lastUrl, title: textExcerpt(document.title) ?? '' };
    this.#initialViewport = {
      x: 0,
      y: 0,
      width: window.innerWidth,
      height: window.innerHeight,
    };
    this.#createdAt = new Date().toISOString();
    this.#toolbar?.setStarting();
    this.#startPromise = this.#beginCapture();
    return this.#startPromise;
  }

  /** Drop every per-session buffer so a later start() begins with a clean bundle. */
  #resetSession(): void {
    this.#removeInteractionListeners();
    this.#sessionToken += 1;
    this.#timeline = undefined;
    this.#microphoneState = 'disabled';
    this.#audioStream = undefined;
    this.#recorder = undefined;
    this.#audioBlob = undefined;
    this.#audioOffsetMs = undefined;
    this.#bundle = undefined;
    this.#startPromise = undefined;
    this.#lastTargetId = undefined;
    this.#lastUrl = '';
    this.#initialPage = undefined;
    this.#initialViewport = undefined;
    this.#createdAt = '';
    this.#frameAvailable = false;
    this.#nextKeyframeOrder = 0;
    for (const path of Object.keys(this.#files)) delete this.#files[path];
    this.#targets.clear();
    this.#elementIds = new WeakMap();
    this.#annotations.length = 0;
    this.#keyframes.length = 0;
    this.#warnings.length = 0;
    this.#audioChunks.length = 0;
    this.#pendingCaptures.clear();
    this.#interactionTimers.clear();
    this.#textEdits.clear();
    this.#formFields.clear();
    this.#keyframeOrder.clear();
    this.#toolbar?.clearAnnotations();
  }

  async stop(): Promise<HighliteBundle> {
    if (this.#state === 'starting' && this.#startPromise) await this.#startPromise;
    if (this.#state !== 'recording' || !this.#timeline) {
      throw new Error('There is no active Highlite session to stop.');
    }

    // Commit held clicks and text edits before the duration snapshot so the action list
    // is complete and no event can fall after the recorded session duration.
    this.#flushPendingSubmitClicks();
    this.#flushTextEdit();
    const durationMs = this.#timeline.now();
    this.#state = 'processing';
    this.#removeInteractionListeners();
    this.#toolbar?.setProcessing();

    await this.#finishAudio();
    while (this.#pendingCaptures.size > 0) {
      await Promise.allSettled(this.#pendingCaptures);
    }
    await this.#stopFrameProvider();
    this.#finalizeKeyframes();
    this.#emit('recording-stopped', { durationMs });
    this.#emit('processing-started', { sessionId: this.#sessionId });

    const artifacts: HighliteManifest['artifacts'] = {};
    if (this.#audioBlob) {
      const extension = extensionForMime(this.#audioBlob.type, 'webm');
      artifacts.audio = `audio.${extension}`;
      this.#files[artifacts.audio] = this.#audioBlob;
    }

    const manifest: HighliteManifest = {
      schemaVersion: '0.1.0',
      sessionId: this.#sessionId,
      createdAt: this.#createdAt,
      page: this.#initialPage ?? { initialUrl: this.#safeUrl(location.href), title: '' },
      viewport: this.#initialViewport ?? {
        x: 0,
        y: 0,
        width: window.innerWidth,
        height: window.innerHeight,
      },
      durationMs,
      timeline: this.#timeline.snapshot(),
      targets: [...this.#targets.values()],
      annotations: [...this.#annotations],
      transcript: [],
      keyframes: [...this.#keyframes],
      artifacts,
      ...(this.#audioBlob && this.#audioOffsetMs !== undefined
        ? { audioOffsetMs: this.#audioOffsetMs }
        : {}),
      captureWarnings: [...this.#warnings],
    };

    let bundle: HighliteBundle;
    try {
      bundle = this.#options.processor
        ? await this.#options.processor.process({ manifest, files: { ...this.#files } })
        : { manifest, summary: buildSummary(manifest), files: { ...this.#files } };
    } catch (error) {
      this.#addWarning(`Configured processor failed: ${safeMessage(error)}`);
      manifest.captureWarnings = [...this.#warnings];
      bundle = { manifest, summary: buildSummary(manifest), files: { ...this.#files } };
      this.#emit('error', {
        error,
        message: 'Processor failed; a local bundle was assembled instead.',
      });
    }

    this.#bundle = bundle;
    this.#state = 'stopped';
    this.#toolbar?.setComplete();
    this.#emit('processing-complete', { bundle });
    try {
      await this.#options.onComplete?.(bundle);
    } catch (error) {
      this.#reportError(error, 'The onComplete callback failed.');
    }

    if (this.#options.relay && this.#options.relay.autoUpload !== false) {
      this.#toolbar?.setStatus('Sending the Highlite session to the relay…');
      try {
        const result = await this.upload();
        this.#toolbar?.setStatus(`Highlite session sent to the relay (${result.status}).`);
        this.#emit('relay-uploaded', { result });
      } catch (error) {
        const message = safeMessage(error);
        this.#toolbar?.setStatus(`Highlite session saved locally. ${message}`);
        this.#emit('relay-failed', { error, message });
      }
    }
    return bundle;
  }

  async cancel(): Promise<void> {
    if (this.#state === 'cancelled' || this.#state === 'destroyed' || this.#state === 'stopped')
      return;
    if (this.#state === 'processing')
      throw new Error('Processing has started; the Highlite session can no longer be cancelled.');
    const wasStarting = this.#state === 'starting';
    this.#state = 'cancelled';
    this.#removeInteractionListeners();
    if (!wasStarting && this.#startPromise) await this.#startPromise;
    await this.#stopRecorderAndDiscard();
    await this.#stopFrameProvider();
    this.#audioChunks.length = 0;
    for (const path of Object.keys(this.#files)) delete this.#files[path];
    this.#toolbar?.setCancelled();
    this.#emit('cancelled', { sessionId: this.#sessionId });
  }

  async mark(label = 'Marked moment'): Promise<void> {
    this.#assertRecording();
    this.#flushPendingSubmitClicks();
    this.#flushTextEdit();
    const normalizedLabel = textExcerpt(label) ?? 'Marked moment';
    const event = this.#timeline!.record('mark', { label: normalizedLabel }, this.#lastTargetId);
    this.#emit('mark-added', { label: normalizedLabel, atMs: event.atMs });
    await this.#trackCapture(
      this.#captureKeyframe('mark', this.#lastTargetId, undefined, false, event.id),
    );
  }

  context(scope: string, value: string): void {
    this.#assertRecording();
    this.#flushPendingSubmitClicks();
    this.#flushTextEdit();
    this.#timeline!.record('context', {
      scope: textExcerpt(scope) ?? 'page',
      value: textExcerpt(value) ?? '',
    });
  }

  registerTarget(
    selector: string,
    metadata: Record<string, string | number | boolean>,
  ): () => void {
    document.querySelector(selector);
    const safeMetadata = Object.fromEntries(
      Object.entries(metadata).filter(
        ([key, value]) =>
          /^[a-zA-Z0-9_-]{1,48}$/.test(key) &&
          ['string', 'number', 'boolean'].includes(typeof value),
      ),
    ) as Record<string, string | number | boolean>;
    this.#registeredTargets.set(selector, safeMetadata);
    return () => {
      if (this.#registeredTargets.get(selector) === safeMetadata)
        this.#registeredTargets.delete(selector);
    };
  }

  on<K extends HighliteEventName>(event: K, handler: HighliteEventHandler<K>): this {
    const handlers = this.#listeners.get(event) ?? new Set();
    handlers.add(handler as HighliteEventHandler<HighliteEventName>);
    this.#listeners.set(event, handlers);
    return this;
  }

  off<K extends HighliteEventName>(event: K, handler: HighliteEventHandler<K>): this {
    this.#listeners.get(event)?.delete(handler as HighliteEventHandler<HighliteEventName>);
    return this;
  }

  async export(options: { download?: boolean } = {}): Promise<Blob> {
    if (!this.#bundle) throw new Error('Stop Highlite before exporting its bundle.');
    const archive = await this.#createArchive(this.#bundle);

    if (options.download !== false) {
      const url = URL.createObjectURL(archive);
      const link = document.createElement('a');
      link.href = url;
      link.download = `highlite-session-${this.#sessionId}.zip`;
      link.hidden = true;
      document.body.append(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    return archive;
  }

  async upload(): Promise<RelayUploadResult> {
    const relay = this.#options.relay;
    if (!relay?.endpoint) throw new Error('Configure relay.endpoint before uploading a session.');
    if (!this.#bundle) throw new Error('Stop Highlite before uploading its bundle.');

    const archive = await this.#createArchive(this.#bundle);
    const controller = typeof AbortController === 'undefined' ? undefined : new AbortController();
    const timeout = controller
      ? window.setTimeout(() => controller.abort(), relay.timeoutMs ?? 120_000)
      : undefined;

    try {
      const response = await fetch(relay.endpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/zip',
          ...(relay.token ? { Authorization: `Bearer ${relay.token}` } : {}),
        },
        body: archive,
        mode: 'cors',
        credentials: 'omit',
        redirect: 'error',
        cache: 'no-store',
        ...(controller ? { signal: controller.signal } : {}),
      });
      const text = await response.text();
      let payload: unknown = {};
      try {
        payload = text ? JSON.parse(text) : {};
      } catch {
        payload = {};
      }
      if (!response.ok) {
        const message =
          isRecord(payload) && typeof payload.error === 'string'
            ? payload.error
            : `HTTP ${response.status}`;
        throw new Error(`Relay upload failed: ${message}`);
      }
      if (
        !isRecord(payload) ||
        typeof payload.sessionId !== 'string' ||
        typeof payload.status !== 'string'
      ) {
        throw new Error('Relay upload failed: the relay returned an unexpected response.');
      }
      return {
        sessionId: payload.sessionId,
        status: payload.status,
        ...(typeof payload.statusUrl === 'string' ? { statusUrl: payload.statusUrl } : {}),
        ...(typeof payload.bundleUrl === 'string' ? { bundleUrl: payload.bundleUrl } : {}),
        ...(typeof payload.summary === 'string' ? { summary: payload.summary } : {}),
      };
    } finally {
      if (timeout !== undefined) window.clearTimeout(timeout);
    }
  }

  async #createArchive(bundle: HighliteBundle): Promise<Blob> {
    const zip = new JSZip();
    zip.file('manifest.json', JSON.stringify(bundle.manifest, null, 2));
    zip.file('summary.md', bundle.summary);
    zip.file('web/interactions.json', JSON.stringify(bundle.manifest.timeline, null, 2));
    zip.file('web/targets.json', JSON.stringify(bundle.manifest.targets, null, 2));
    zip.file('web/annotations.json', JSON.stringify(bundle.manifest.annotations, null, 2));
    for (const [path, blob] of Object.entries(bundle.files)) zip.file(path, blob);
    return zip.generateAsync({ type: 'blob', compression: 'DEFLATE' });
  }

  async destroy(): Promise<void> {
    if (this.#state === 'starting' || this.#state === 'recording') await this.cancel();
    this.#removeInteractionListeners();
    this.#frameEndUnsubscribe?.();
    this.#toolbar?.destroy();
    this.#state = 'destroyed';
    this.#listeners.clear();
  }

  async #beginCapture(): Promise<void> {
    const microphoneEnabled = this.#captureOptions.microphone !== false;
    const microphonePreApproved = microphoneEnabled ? await this.#hasMicrophonePermission() : false;
    if (!microphoneEnabled) this.#microphoneState = 'disabled';

    const steps: Array<{ step: PermissionStep; preApproved: boolean }> = [];
    if (microphoneEnabled) {
      steps.push({ step: MICROPHONE_PERMISSION, preApproved: microphonePreApproved });
    }
    if (this.#frameProvider) steps.push({ step: DISPLAY_PERMISSION, preApproved: false });

    const promptTotal = steps.filter((entry) => !entry.preApproved).length;
    let promptNumber = 0;

    for (const { step, preApproved } of steps) {
      if (this.#state !== 'starting') break;
      let decision: PermissionDecision = 'granted';
      if (!preApproved) {
        promptNumber += 1;
        decision = await this.#askPermission(step, promptNumber, promptTotal);
        if (this.#state !== 'starting') break;
      }
      if (decision === 'skipped') {
        if (step.kind === 'microphone') this.#microphoneState = 'disabled';
        else this.#addWarning('Visual evidence unavailable: screen sharing was not approved.');
        continue;
      }
      if (step.kind === 'microphone') await this.#startMicrophone();
      else await this.#startFrames();
      this.#toolbar?.dismissPermission();
    }

    if (this.#state !== 'starting') {
      await this.#stopRecorderAndDiscard();
      await this.#stopFrameProvider();
      return;
    }

    this.#state = 'recording';
    this.#recordEnvironment();
    this.#attachInteractionListeners();
    this.#toolbar?.setRecording(true);
    const micStatus =
      this.#microphoneState === 'active'
        ? 'Microphone on.'
        : this.#microphoneState === 'denied'
          ? 'Microphone unavailable; continuing without audio.'
          : 'Microphone disabled.';
    this.#toolbar?.setStatus(
      this.#frameAvailable
        ? `${micStatus} Approved screen sharing is available.`
        : `${micStatus} Visual evidence is unavailable.`,
    );
    this.#emit('recording-started', {
      sessionId: this.#sessionId,
      microphone: this.#microphoneState,
    });
    if (this.#frameAvailable) {
      void this.#trackCapture(this.#captureKeyframe('interaction', undefined, undefined));
    }
  }

  #recordEnvironment(): void {
    this.#timeline?.record('context', {
      scope: 'environment',
      value: describeEnvironment({
        userAgent: navigator.userAgent,
        width: window.innerWidth,
        height: window.innerHeight,
      }),
    });
  }

  async #hasMicrophonePermission(): Promise<boolean> {
    const permissions = navigator.permissions;
    if (!permissions?.query) return false;
    try {
      const status = await permissions.query({ name: 'microphone' as PermissionName });
      return status.state === 'granted';
    } catch {
      return false;
    }
  }

  async #askPermission(
    step: PermissionStep,
    stepNumber: number,
    total: number,
  ): Promise<PermissionDecision> {
    const toolbar = this.#toolbar;
    if (!toolbar) return 'granted';
    const { waitingMessage, ...request } = step;
    const decision = await toolbar.requestPermission({ ...request, step: stepNumber, total });
    if (decision === 'granted') toolbar.setPermissionWaiting(waitingMessage);
    return decision;
  }

  async #startMicrophone(): Promise<void> {
    const getUserMedia = navigator.mediaDevices?.getUserMedia?.bind(navigator.mediaDevices);
    if (!getUserMedia || typeof MediaRecorder === 'undefined') {
      this.#microphoneState = 'denied';
      this.#addWarning('Microphone recording is not supported by this browser.');
      return;
    }

    try {
      this.#audioStream = await getUserMedia({ audio: true });
      if (this.#state !== 'starting') {
        for (const track of this.#audioStream.getTracks()) track.stop();
        this.#audioStream = undefined;
        return;
      }

      const mimeType = [
        'audio/webm;codecs=opus',
        'audio/mp4',
        'audio/ogg;codecs=opus',
        'audio/webm',
      ].find((candidate) => MediaRecorder.isTypeSupported(candidate));
      this.#recorder = new MediaRecorder(this.#audioStream, mimeType ? { mimeType } : undefined);
      this.#recorder.addEventListener('dataavailable', (event: BlobEvent) => {
        if (event.data.size > 0) this.#audioChunks.push(event.data);
      });
      this.#recorder.addEventListener('error', (event: Event) => {
        this.#microphoneState = 'denied';
        this.#addWarning(
          'Microphone recording stopped unexpectedly; available audio was retained.',
        );
        this.#emit('error', {
          error: event,
          message: 'Microphone recording stopped unexpectedly.',
        });
      });
      this.#recorder.start(1000);
      this.#audioOffsetMs = this.#timeline?.now();
      this.#microphoneState = 'active';
    } catch (error) {
      if (this.#state !== 'starting') return;
      this.#microphoneState = 'denied';
      this.#addWarning(`Microphone unavailable: ${safeMessage(error)}`);
      this.#emit('error', {
        error,
        message: 'Microphone unavailable; continuing without narration audio.',
      });
      for (const track of this.#audioStream?.getTracks() ?? []) track.stop();
      this.#audioStream = undefined;
    }
  }

  async #startFrames(): Promise<void> {
    try {
      await this.#frameProvider!.start();
      if (this.#state !== 'starting') {
        await this.#frameProvider!.stop();
        return;
      }
      this.#frameAvailable = true;
      this.#addWarning(
        'Visual pixels are not automatically redacted. Review the shared surface and avoid exposing sensitive content.',
      );
    } catch (error) {
      if (this.#state !== 'starting') return;
      this.#addWarning(`Visual evidence unavailable: ${safeMessage(error)}`);
      this.#emit('error', {
        error,
        message: 'Screen sharing unavailable; Highlite continues without screenshots.',
      });
    }
  }

  async #finishAudio(): Promise<void> {
    const recorder = this.#recorder;
    if (recorder && recorder.state !== 'inactive') {
      await new Promise<void>((resolve) => {
        recorder.addEventListener('stop', () => resolve(), { once: true });
        recorder.stop();
      });
    }
    if (this.#audioChunks.length > 0) {
      this.#audioBlob = new Blob(this.#audioChunks, {
        type: recorder?.mimeType || this.#audioChunks[0]!.type || 'application/octet-stream',
      });
    }
    this.#audioChunks.length = 0;
    for (const track of this.#audioStream?.getTracks() ?? []) track.stop();
    this.#audioStream = undefined;
    this.#recorder = undefined;
  }

  async #stopRecorderAndDiscard(): Promise<void> {
    const recorder = this.#recorder;
    if (recorder && recorder.state !== 'inactive') {
      await new Promise<void>((resolve) => {
        recorder.addEventListener('stop', () => resolve(), { once: true });
        recorder.stop();
      });
    }
    for (const track of this.#audioStream?.getTracks() ?? []) track.stop();
    this.#audioStream = undefined;
    this.#recorder = undefined;
    this.#audioChunks.length = 0;
  }

  async #stopFrameProvider(): Promise<void> {
    this.#frameAvailable = false;
    try {
      await this.#frameProvider?.stop();
    } catch (error) {
      this.#addWarning(`Screen sharing cleanup failed: ${safeMessage(error)}`);
    }
  }

  #attachInteractionListeners(): void {
    if (this.#interactionAttached || this.#captureOptions.interactions === false) return;
    this.#interactionAttached = true;
    const onClick = (event: MouseEvent): void => this.#captureClick(event);
    const onInput = (event: Event): void => this.#captureInput(event);
    const onChange = (event: Event): void => this.#captureChange(event);
    const onSubmit = (event: Event): void => this.#captureSubmit(event);
    const onScroll = (): void => {
      if (this.#scrollTimer !== undefined) window.clearTimeout(this.#scrollTimer);
      this.#scrollTimer = window.setTimeout(() => {
        this.#scrollTimer = undefined;
        if (this.#state !== 'recording' || !this.#timeline) return;
        this.#flushPendingSubmitClicks();
        this.#flushTextEdit();
        const event = this.#timeline.record('scroll', { x: window.scrollX, y: window.scrollY });
        this.#toolbar?.clearAnnotations();
        void this.#trackCapture(
          this.#captureKeyframe('interaction', undefined, undefined, false, event.id),
        );
      }, 180);
    };
    document.addEventListener('click', onClick, true);
    document.addEventListener('input', onInput, true);
    document.addEventListener('change', onChange, true);
    document.addEventListener('submit', onSubmit, true);
    window.addEventListener('scroll', onScroll, { capture: true, passive: true });
    this.#interactionCleanups.push(() => document.removeEventListener('click', onClick, true));
    this.#interactionCleanups.push(() => document.removeEventListener('input', onInput, true));
    this.#interactionCleanups.push(() => document.removeEventListener('change', onChange, true));
    this.#interactionCleanups.push(() => document.removeEventListener('submit', onSubmit, true));
    this.#interactionCleanups.push(() => window.removeEventListener('scroll', onScroll, true));
    this.#installRouteListeners();
  }

  #captureClick(event: MouseEvent): void {
    if (this.#state !== 'recording' || !this.#timeline) return;
    const path = event.composedPath();
    if (path.some((entry) => entry instanceof Element && entry.hasAttribute('data-highlite-root')))
      return;
    this.#flushPendingSubmitClicks();
    const element = path.find((entry): entry is Element => entry instanceof Element);
    if (!element || this.#isDisabledElement(element)) return;

    const control = this.#formControlFor(element);
    if (control && this.#isDisabledElement(control)) return;

    const submitForm = control ? this.#submitFormForControl(control) : undefined;
    if (
      control &&
      submitForm &&
      !this.#matchesAny(control, this.#redactSelectors()) &&
      !this.#matchesAny(submitForm, this.#redactSelectors())
    ) {
      this.#deferSubmitClick(submitForm, control, event);
      return;
    }

    if (control && this.#shouldSkipFieldClick(control)) return;

    this.#flushTextEdit();
    const target = this.#resolveTarget(element);
    this.#recordClickAction(
      target,
      event.button,
      Math.round(event.clientX),
      Math.round(event.clientY),
    );
  }

  #recordClickAction(target: Target | undefined, button: number, x: number, y: number): void {
    if (this.#state !== 'recording' || !this.#timeline) return;
    if (target) {
      this.#lastTargetId = target.id;
      this.#timeline.record('target', { role: target.role, tag: target.tag }, target.id);
      this.#emit('target-selected', { target });
    }
    const clickEvent = this.#timeline.record('click', { button, x, y }, target?.id);

    if (this.#frameAvailable) {
      void this.#trackCapture(
        this.#captureKeyframe('interaction', target?.id, undefined, false, clickEvent.id),
      );
      this.#scheduleInteraction(() => {
        if (this.#state === 'recording')
          void this.#trackCapture(
            this.#captureKeyframe('interaction', target?.id, undefined, false, clickEvent.id),
          );
      }, 350);
    }
  }

  #deferSubmitClick(form: HTMLFormElement, control: Element, event: MouseEvent): void {
    // Commit preceding text before the click, but do not record the click yet: a
    // synchronous `submit` event makes it redundant, while no submit means the click is
    // the only evidence that the attempt failed.
    this.#flushTextEdit();
    const pending: PendingSubmitClick = {
      form,
      target: this.#resolveTarget(control),
      button: event.button,
      x: Math.round(event.clientX),
      y: Math.round(event.clientY),
      timer: 0,
    };
    pending.timer = window.setTimeout(() => {
      this.#pendingSubmitClicks.delete(pending);
      if (this.#state !== 'recording') return;
      this.#recordClickAction(pending.target, pending.button, pending.x, pending.y);
    }, 0);
    this.#pendingSubmitClicks.add(pending);
  }

  #flushPendingSubmitClicks(): void {
    for (const pending of this.#pendingSubmitClicks) {
      window.clearTimeout(pending.timer);
      this.#pendingSubmitClicks.delete(pending);
      this.#recordClickAction(pending.target, pending.button, pending.x, pending.y);
    }
  }

  #clearPendingSubmitClicks(): void {
    for (const pending of this.#pendingSubmitClicks) window.clearTimeout(pending.timer);
    this.#pendingSubmitClicks.clear();
  }

  #cancelPendingSubmitClick(form: HTMLFormElement): void {
    let latest: PendingSubmitClick | undefined;
    for (const pending of this.#pendingSubmitClicks) {
      if (pending.form === form) latest = pending;
    }
    if (!latest) return;
    window.clearTimeout(latest.timer);
    this.#pendingSubmitClicks.delete(latest);
  }

  #submitFormForControl(control: Element): HTMLFormElement | undefined {
    if (!(control instanceof HTMLButtonElement) && !(control instanceof HTMLInputElement))
      return undefined;
    const descriptor = {
      tagName: control.tagName,
      type: control.getAttribute('type'),
    };
    if (!isSubmitControlDescriptor(descriptor)) return undefined;
    return control.form ?? undefined;
  }

  #captureInput(event: Event): void {
    if (this.#state !== 'recording' || !this.#timeline) return;
    this.#flushPendingSubmitClicks();
    const element = this.#eventElement(event);
    if (!element || this.#isDisabledElement(element)) return;
    const host = contentEditableHost(element) ?? element;
    if (!isFieldElement(host)) return;
    const field = this.#fieldTarget(host);
    if (
      !field ||
      (field.classification.kind !== 'text' && field.classification.kind !== 'textarea')
    )
      return;

    this.#lastTargetId = field.target.id;
    const value = this.#fieldValue(host);
    const committed = this.#textEdits.push(field.target.id, value, this.#timeline.now());
    if (committed) this.#recordTextEdit(committed);
    this.#scheduleTextEditFlush();
  }

  #captureChange(event: Event): void {
    if (this.#state !== 'recording' || !this.#timeline) return;
    this.#flushPendingSubmitClicks();
    const element = this.#eventElement(event);
    if (!element || this.#isDisabledElement(element)) return;
    const host = contentEditableHost(element) ?? element;
    if (!isFieldElement(host)) return;
    const field = this.#fieldTarget(host);
    if (!field) return;
    const classification = field.classification;

    // Text fields are represented by coalesced input events. A change only means the
    // field lost focus, so commit the pending edit before any later action.
    if (classification.kind === 'text' || classification.kind === 'textarea') {
      this.#flushTextEdit();
      return;
    }

    this.#flushTextEdit();
    this.#lastTargetId = field.target.id;
    const input = host instanceof HTMLInputElement ? host : undefined;
    const select = host instanceof HTMLSelectElement ? host : undefined;
    const selectedOptions = select ? Array.from(select.selectedOptions) : [];
    const multiple = select?.multiple === true;
    const optionLabels = multiple
      ? selectedOptions.map((option) => option.textContent ?? option.value).filter(Boolean)
      : undefined;
    this.#timeline.record(
      'change',
      changePayload(classification, {
        ...(input ? { checked: input.checked, value: input.value } : {}),
        ...(select && !multiple ? { value: select.value } : {}),
        ...(select && !multiple && selectedOptions[0]?.textContent
          ? { optionLabel: selectedOptions[0].textContent }
          : {}),
        ...(optionLabels ? { optionLabels } : {}),
      }),
      field.target.id,
    );
  }

  #captureSubmit(event: Event): void {
    if (this.#state !== 'recording' || !this.#timeline) return;
    if (!(event.target instanceof HTMLFormElement)) return;
    const form = event.target;
    // The browser fired submit for the click we are holding, so that click is redundant.
    this.#cancelPendingSubmitClick(form);
    if (this.#isDisabledElement(form) || this.#matchesAny(form, this.#redactSelectors())) return;

    this.#flushTextEdit();
    const target = this.#resolveTarget(form);
    if (target) this.#lastTargetId = target.id;
    const submitter = event instanceof SubmitEvent ? event.submitter : null;
    const submitterLabel =
      submitter && !this.#matchesAny(submitter, this.#redactSelectors())
        ? this.#accessibleLabel(submitter)
        : undefined;
    const payload = submitPayload(
      { method: form.method, action: this.#safeUrl(form.action) },
      submitterLabel,
    );
    const submitEvent = this.#timeline.record('submit', payload, target?.id);
    if (this.#frameAvailable) {
      void this.#trackCapture(
        this.#captureKeyframe('interaction', target?.id, undefined, false, submitEvent.id),
      );
    }
  }

  #eventElement(event: Event): Element | undefined {
    const path = event.composedPath();
    if (path.some((entry) => entry instanceof Element && entry.hasAttribute('data-highlite-root')))
      return undefined;
    return path.find((entry): entry is Element => entry instanceof Element);
  }

  #formControlFor(element: Element): Element | undefined {
    const host = contentEditableHost(element);
    if (host) return host;
    const control = element.closest('input, textarea, select, button');
    if (control) return control;
    const label = element.closest('label');
    return label instanceof HTMLLabelElement ? (label.control ?? undefined) : undefined;
  }

  #shouldSkipFieldClick(control: Element): boolean {
    // A submit control that will produce a `submit` event never needs its click; a
    // blocked submit is handled by the deferred-click path before this check.
    if (this.#submitFormForControl(control)) return true;
    if (!isFieldElement(control)) return false;
    const classification = this.#classifyField(control);
    // Skip every classified field, including excluded password/secret fields, so no
    // field click duplicates the semantic input/change action (or leaks a target).
    // Unsupported field types keep their click, because no semantic action replaces it.
    return classification !== undefined && classification.excluded !== 'unsupported';
  }

  #accessibleLabel(element: Element): string | undefined {
    return accessibleLabel(element, { privateSelectors: this.#redactSelectors() });
  }

  #fieldDescriptor(element: Element): ReturnType<typeof fieldDescriptor> {
    return fieldDescriptor(element, { privateSelectors: this.#redactSelectors() });
  }

  #classifyField(element: Element): FieldClassification | undefined {
    const descriptor = this.#fieldDescriptor(element);
    if (!descriptor) return undefined;
    const classification = classifyField(descriptor, {
      captureValues: this.#captureOptions.formValues === true,
      redacted: this.#matchesAny(element, this.#redactSelectors()),
      disabled: this.#isDisabledElement(element),
    });
    // A rich-text field can contain a private region while the field itself is public.
    // Keep the action but drop the value rather than capturing that region's text.
    if (classification.captureValue && this.#containsAny(element, this.#redactSelectors())) {
      return { ...classification, captureValue: false };
    }
    return classification;
  }

  #fieldTarget(
    element: Element,
  ): { target: Target; classification: FieldClassification } | undefined {
    const existingId = this.#elementIds.get(element);
    if (existingId) {
      const classification = this.#formFields.get(existingId);
      const target = this.#targets.get(existingId);
      if (classification && target) return { target, classification };
    }
    const classification = this.#classifyField(element);
    if (!classification || classification.excluded) return undefined;
    const target = this.#resolveTarget(element);
    if (!target) return undefined;
    this.#formFields.set(target.id, classification);
    return { target, classification };
  }

  #fieldValue(element: Element): string {
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement)
      return element.value;
    return element instanceof HTMLElement ? (element.innerText ?? element.textContent ?? '') : '';
  }

  #recordTextEdit(edit: { key: string; value: string }): void {
    if (!this.#timeline) return;
    const classification = this.#formFields.get(edit.key);
    if (!classification) return;
    this.#timeline.record('input', textEditPayload(classification, edit.value), edit.key);
  }

  #scheduleTextEditFlush(): void {
    if (this.#formEditTimer !== undefined) window.clearTimeout(this.#formEditTimer);
    this.#formEditTimer = window.setTimeout(() => {
      this.#formEditTimer = undefined;
      this.#flushTextEdit();
    }, FORM_EDIT_IDLE_MS);
  }

  #flushTextEdit(): void {
    if (this.#formEditTimer !== undefined) {
      window.clearTimeout(this.#formEditTimer);
      this.#formEditTimer = undefined;
    }
    if (this.#state !== 'recording') {
      this.#textEdits.clear();
      return;
    }
    const edit = this.#textEdits.flush();
    if (edit) this.#recordTextEdit(edit);
  }

  #redactSelectors(): string[] {
    return this.#privacyOptions.redactSelectors ?? DEFAULT_REDACT_SELECTORS;
  }

  async #addAnnotation(
    kind: AnnotationKind,
    points: Annotation['points'],
    clientX: number,
    clientY: number,
    element: Element | null,
  ): Promise<void> {
    if (this.#state !== 'recording' || !this.#timeline) return;
    this.#flushPendingSubmitClicks();
    const target =
      element && !this.#isDisabledElement(element) ? this.#resolveTarget(element) : undefined;
    if (element && this.#isDisabledElement(element)) {
      this.#toolbar?.setStatus('Annotations are disabled on this element.');
      return;
    }
    this.#flushTextEdit();
    const annotation: Annotation = {
      id: createId(),
      atMs: this.#timeline.now(),
      kind,
      points,
      coordinateSpace: 'viewport-normalized',
      strokeWidth: ANNOTATION_LINE_WIDTH,
      fadeAfterMs: ANNOTATION_FADE_AFTER_MS,
      fadeDurationMs: ANNOTATION_FADE_DURATION_MS,
      ...(target ? { targetId: target.id } : {}),
    };
    this.#annotations.push(annotation);
    const annotationEvent = this.#timeline.record(
      'annotation',
      { annotationId: annotation.id, annotationKind: kind, x: clientX, y: clientY },
      target?.id,
    );
    this.#toolbar?.addAnnotation(annotation);
    this.#emit('annotation-added', { annotation });
    const capture = (async (): Promise<void> => {
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      await this.#captureKeyframe(
        'annotation',
        target?.id,
        annotation.id,
        true,
        annotationEvent.id,
      );
    })();
    await this.#trackCapture(capture);
  }

  async #captureKeyframe(
    reason: HighliteManifest['keyframes'][number]['reason'],
    targetId: string | undefined,
    annotationId: string | undefined,
    allowProcessing = false,
    eventId?: string,
  ): Promise<void> {
    const token = this.#sessionToken;
    const canCapture =
      this.#state === 'recording' || (allowProcessing && this.#state === 'processing');
    if (!this.#frameProvider || !this.#frameAvailable || !canCapture) {
      this.#addWarning('Visual evidence unavailable because no approved frame provider is active.');
      return;
    }

    const atMs = this.#timeline?.now() ?? 0;
    const order = this.#nextKeyframeOrder++;
    try {
      const image = await this.#frameProvider.capture(atMs);
      if (token !== this.#sessionToken) return;
      if (this.#state !== 'recording' && this.#state !== 'processing') return;
      if (!image) {
        this.#addWarning('The frame provider did not return image data for a requested keyframe.');
        return;
      }
      const id = createId();
      const extension = extensionForMime(image.type, 'png');
      const imagePath = `frames/.pending-${String(order).padStart(6, '0')}-${id}.${extension}`;
      this.#files[imagePath] = image;
      this.#keyframes.push({
        id,
        atMs,
        imagePath,
        targetIds: targetId ? [targetId] : [],
        annotationIds: annotationId ? [annotationId] : [],
        transcriptSegmentIds: [],
        reason,
        ...(eventId ? { eventIds: [eventId] } : {}),
      });
      this.#keyframeOrder.set(id, order);
    } catch (error) {
      if (token !== this.#sessionToken) return;
      this.#addWarning(`A requested keyframe could not be saved: ${safeMessage(error)}`);
      this.#emit('error', { error, message: 'A screenshot candidate could not be saved.' });
    }
  }

  #resolveTarget(element: Element): Target | undefined {
    if (element.closest('[data-highlite-root]')) return undefined;
    const redacted = this.#matchesAny(element, this.#redactSelectors());
    const selector = this.#selectorFor(element);
    const context = this.#findRegisteredMetadata(element);
    let id = this.#elementIds.get(element);
    if (!id) {
      const contextId = element.getAttribute('data-context-id');
      id = contextId ? `context:${contextId}` : `target-${this.#elementIdsCount() + 1}`;
      this.#elementIds.set(element, id);
    }

    const rect = element.getBoundingClientRect();
    const target: Target = {
      id,
      tag: element.tagName.toLowerCase(),
      role: element.getAttribute('role') ?? implicitRole(element),
      selector,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      pageUrl: this.#safeUrl(location.href),
      ...(redacted ? {} : this.#targetLabel(element)),
      ...(!redacted && context ? { metadata: { ...context } } : {}),
    };
    this.#targets.set(target.id, target);
    return target;
  }

  #elementIdsCount(): number {
    return this.#targets.size;
  }

  #targetLabel(element: Element): Partial<Pick<Target, 'label' | 'textExcerpt'>> {
    const privateSelectors = this.#redactSelectors();
    const label =
      this.#accessibleLabel(element) ??
      element.getAttribute('aria-label') ??
      element.getAttribute('alt') ??
      element.getAttribute('title') ??
      (element instanceof HTMLLabelElement
        ? readableTextExcerpt(element, privateSelectors)
        : undefined);
    const safeLabel = textExcerpt(label);
    // Field values and form copy are not target excerpts. Ancestor excerpts also drop
    // private, hidden, and embedded control content so a descendant cannot leak.
    const excerpt =
      isFieldElement(element) || element.tagName.toLowerCase() === 'form'
        ? undefined
        : readableTextExcerpt(element, privateSelectors);
    return {
      ...(safeLabel ? { label: safeLabel } : {}),
      ...(excerpt ? { textExcerpt: excerpt } : {}),
    };
  }

  #selectorFor(element: Element): string {
    const contextId = element.getAttribute('data-context-id');
    if (contextId) return `[data-context-id="${CSS.escape(contextId)}"]`;
    if (element.id) return `#${CSS.escape(element.id)}`;
    const testId = element.getAttribute('data-testid');
    if (testId) return `[data-testid="${CSS.escape(testId)}"]`;
    return element.tagName.toLowerCase();
  }

  #findRegisteredMetadata(element: Element): Record<string, string | number | boolean> | undefined {
    for (const [selector, metadata] of this.#registeredTargets) {
      if (element.closest(selector)) return metadata;
    }
    return undefined;
  }

  #matchesAny(element: Element, selectors: string[]): boolean {
    return selectors.some((selector) => {
      try {
        return element.closest(selector) !== null;
      } catch {
        return false;
      }
    });
  }

  #containsAny(element: Element, selectors: string[]): boolean {
    return selectors.some((selector) => {
      try {
        return element.querySelector(selector) !== null;
      } catch {
        return false;
      }
    });
  }

  #isDisabledElement(element: Element): boolean {
    return this.#matchesAny(element, this.#privacyOptions.disableSelectors ?? []);
  }

  #isDisabledRoute(pathname: string): boolean {
    return (this.#captureOptions.disabledRoutes ?? []).includes(pathname);
  }

  #safeUrl(href: string): string {
    const url = new URL(href, location.origin);
    return `${url.origin}${url.pathname}${this.#privacyOptions.includeQueryString ? url.search : ''}`;
  }

  #installRouteListeners(): void {
    const history = window.history;
    const originalPushState = history.pushState;
    const originalReplaceState = history.replaceState;
    const onRoute = (source: string): void => this.#captureRoute(source);
    const wrappedPushState: History['pushState'] = function (
      this: History,
      data,
      unused,
      url,
    ): void {
      originalPushState.call(this, data, unused, url);
      onRoute('pushState');
    };
    const wrappedReplaceState: History['replaceState'] = function (
      this: History,
      data,
      unused,
      url,
    ): void {
      originalReplaceState.call(this, data, unused, url);
      onRoute('replaceState');
    };
    const onPopState = (): void => onRoute('popstate');
    history.pushState = wrappedPushState;
    history.replaceState = wrappedReplaceState;
    window.addEventListener('popstate', onPopState);
    this.#routeUnsubscribe = () => {
      if (history.pushState === wrappedPushState) history.pushState = originalPushState;
      if (history.replaceState === wrappedReplaceState) history.replaceState = originalReplaceState;
      window.removeEventListener('popstate', onPopState);
    };
  }

  #captureRoute(source: string): void {
    if (this.#state !== 'recording' || !this.#timeline) return;
    const nextUrl = this.#safeUrl(location.href);
    if (nextUrl === this.#lastUrl) return;
    const previousUrl = this.#lastUrl;
    this.#lastUrl = nextUrl;
    this.#flushPendingSubmitClicks();
    this.#flushTextEdit();
    const navigateEvent = this.#timeline.record('navigate', {
      from: previousUrl,
      to: nextUrl,
      source,
    });
    // Annotations are viewport coordinates on the page they were drawn on; a route
    // change makes them stale, just like scrolling does.
    this.#toolbar?.clearAnnotations();
    if (this.#isDisabledRoute(location.pathname)) {
      this.#addWarning('Highlite stopped because the browser navigated to a disabled route.');
      void this.cancel();
      return;
    }
    this.#scheduleInteraction(() => {
      if (this.#state === 'recording')
        void this.#trackCapture(
          this.#captureKeyframe('interaction', undefined, undefined, false, navigateEvent.id),
        );
    }, 350);
  }

  #removeInteractionListeners(): void {
    this.#clearPendingSubmitClicks();
    if (this.#scrollTimer !== undefined) {
      window.clearTimeout(this.#scrollTimer);
      this.#scrollTimer = undefined;
    }
    if (this.#formEditTimer !== undefined) {
      window.clearTimeout(this.#formEditTimer);
      this.#formEditTimer = undefined;
    }
    this.#textEdits.clear();
    this.#formFields.clear();
    for (const timer of this.#interactionTimers) window.clearTimeout(timer);
    this.#interactionTimers.clear();
    for (const cleanup of this.#interactionCleanups.splice(0)) cleanup();
    this.#routeUnsubscribe?.();
    this.#routeUnsubscribe = undefined;
    this.#interactionAttached = false;
  }

  #assertRecording(): void {
    if (this.#state !== 'recording' || !this.#timeline) {
      throw new Error('This action is available only while Highlite is recording.');
    }
  }

  #trackCapture(promise: Promise<void>): Promise<void> {
    this.#pendingCaptures.add(promise);
    void promise.then(
      () => this.#pendingCaptures.delete(promise),
      () => this.#pendingCaptures.delete(promise),
    );
    return promise;
  }

  #finalizeKeyframes(): void {
    const ordered = [...this.#keyframes].sort(
      (left, right) =>
        left.atMs - right.atMs ||
        (this.#keyframeOrder.get(left.id) ?? 0) - (this.#keyframeOrder.get(right.id) ?? 0),
    );
    ordered.forEach((frame, index) => {
      const pendingPath = frame.imagePath;
      const extension = pendingPath.split('.').at(-1) ?? 'png';
      const imagePath = `frames/${String(index + 1).padStart(4, '0')}.${extension}`;
      this.#files[imagePath] = this.#files[pendingPath]!;
      delete this.#files[pendingPath];
      frame.imagePath = imagePath;
    });
    this.#keyframes.splice(0, this.#keyframes.length, ...ordered);
  }

  #scheduleInteraction(action: () => void, delayMs: number): void {
    const timer = window.setTimeout(() => {
      this.#interactionTimers.delete(timer);
      action();
    }, delayMs);
    this.#interactionTimers.add(timer);
  }

  #addWarning(message: string): void {
    if (!this.#warnings.includes(message)) this.#warnings.push(message);
    if (this.#state === 'recording' || this.#state === 'starting') {
      this.#toolbar?.setStatus(message);
    }
  }

  #reportError(error: unknown, message = safeMessage(error)): void {
    this.#toolbar?.setStatus(message);
    this.#emit('error', { error, message });
  }

  #emit<K extends HighliteEventName>(event: K, payload: HighliteEvents[K]): void {
    const handlers = this.#listeners.get(event);
    if (!handlers) return;
    for (const handler of handlers) {
      try {
        (handler as HighliteEventHandler<K>)(payload);
      } catch {
        this.#toolbar?.setStatus(`A handler for the ${event} event failed.`);
      }
    }
  }
}

export function createHighlite(options: HighliteOptions = {}): HighliteController {
  return new Highlite(options);
}
