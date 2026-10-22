import type { Annotation, AnnotationKind } from '@highlite/core';
import {
  ANNOTATION_ARROW_HEAD,
  ANNOTATION_FADE_AFTER_MS,
  ANNOTATION_LINE_WIDTH,
  annotationOpacity,
  appendPointerSamples,
  pointerSamples,
  type NormalizedPoint,
} from './annotation';

export interface PermissionRequest {
  kind: 'microphone' | 'display';
  step: number;
  total: number;
  title: string;
  description: string;
  details: readonly string[];
  allowLabel: string;
  skipLabel: string;
}

export type PermissionDecision = 'granted' | 'skipped';

export interface ToolbarOptions {
  zIndex: number;
  onStart: () => void;
  onMark: () => void;
  onStop: () => void;
  onCancel: () => void;
  onExport: () => void;
  onAnnotation: (
    kind: AnnotationKind,
    points: Annotation['points'],
    clientX: number,
    clientY: number,
    target: Element | null,
  ) => void;
  onAnnotatingChange: (annotating: boolean) => void;
}

const styles = `
:host { all: initial; position: fixed; inset: 0; width: 100vw; height: 100vh; z-index: var(--highlite-z); pointer-events: none; color: #172033; font: 14px/1.4 system-ui, sans-serif; }
* { box-sizing: border-box; }
button, select { font: inherit; }
.toolbar { position: fixed; right: 20px; bottom: 20px; width: min(340px, calc(100vw - 32px)); pointer-events: auto; }
.launcher { margin-left: auto; display: block; border: 0; border-radius: 999px; padding: 12px 16px; color: white; background: #3b5bdb; box-shadow: 0 8px 28px #17203330; font-weight: 700; cursor: pointer; }
.launcher:focus-visible, button:focus-visible, select:focus-visible { outline: 3px solid #91a7ff; outline-offset: 2px; }
.panel { margin-bottom: 10px; padding: 14px; border: 1px solid #dbe2ef; border-radius: 14px; background: #fff; box-shadow: 0 12px 36px #1720332e; }
.panel[hidden] { display: none; }
.heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 8px; }
.heading strong { font-size: 15px; }
.status { min-height: 20px; color: #526179; font-size: 12px; }
.disclosure { margin: 8px 0 12px; color: #68758b; font-size: 11px; }
.row { display: flex; flex-wrap: wrap; align-items: center; gap: 7px; }
.row + .row { margin-top: 8px; }
.row button, .row select { min-height: 34px; border: 1px solid #cdd5e1; border-radius: 8px; padding: 6px 10px; background: white; color: #172033; cursor: pointer; }
.row button:hover { background: #f4f6fa; }
.row button.primary { border-color: #3b5bdb; color: white; background: #3b5bdb; }
.row button.danger { color: #b42318; }
.row button:disabled, .row select:disabled { cursor: not-allowed; opacity: .52; }
.recording { display: inline-flex; align-items: center; gap: 6px; color: #b42318; font-size: 12px; font-weight: 700; }
.recording[hidden] { display: none; }
.recording::before { width: 8px; height: 8px; border-radius: 50%; background: currentColor; content: ''; }
canvas { position: fixed; inset: 0; width: 100vw; height: 100vh; pointer-events: none; touch-action: none; }
.backdrop { position: fixed; inset: 0; display: grid; place-items: center; padding: 20px; background: #17203359; pointer-events: auto; }
.backdrop[hidden] { display: none; }
.modal { position: relative; width: min(430px, 100%); padding: 20px; border-radius: 16px; background: #fff; box-shadow: 0 24px 64px #17203355; }
.modal h2 { margin: 0 0 6px; padding-right: 30px; font-size: 18px; line-height: 1.25; }
.step { margin: 0 0 5px; padding-right: 30px; color: #3b5bdb; font-size: 11px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
.close { position: absolute; top: 10px; right: 10px; display: grid; place-items: center; width: 32px; height: 32px; border: 0; border-radius: 8px; padding: 0; background: transparent; color: #526179; font-size: 20px; line-height: 1; cursor: pointer; }
.close:hover { background: #eef1f7; color: #172033; }
.description { margin: 0 0 10px; color: #33415c; }
.details { margin: 0 0 10px; padding-left: 18px; color: #526179; font-size: 12px; }
.details li + li { margin-top: 4px; }
.permission-status { min-height: 18px; color: #3b5bdb; font-size: 12px; }
.actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 12px; }
.actions button { min-height: 36px; border: 1px solid #cdd5e1; border-radius: 8px; padding: 7px 12px; background: #fff; color: #172033; cursor: pointer; }
.actions button:hover { background: #f4f6fa; }
.actions button.primary { border-color: #3b5bdb; background: #3b5bdb; color: #fff; font-weight: 700; }
.actions button.primary:hover { background: #2f4ac4; }
.actions button:disabled { cursor: progress; opacity: .6; }
`;

export class CaptureToolbar {
  readonly #host: HTMLDivElement;
  readonly #root: ShadowRoot;
  readonly #panel: HTMLDivElement;
  readonly #status: HTMLDivElement;
  readonly #recordingBadge: HTMLSpanElement;
  readonly #recordButton: HTMLButtonElement;
  readonly #markButton: HTMLButtonElement;
  readonly #annotateButton: HTMLButtonElement;
  readonly #stopButton: HTMLButtonElement;
  readonly #cancelButton: HTMLButtonElement;
  readonly #exportButton: HTMLButtonElement;
  readonly #shapeSelect: HTMLSelectElement;
  readonly #canvas: HTMLCanvasElement;
  readonly #context: CanvasRenderingContext2D;
  readonly #backdrop: HTMLDivElement;
  readonly #permissionStep: HTMLParagraphElement;
  readonly #permissionTitle: HTMLHeadingElement;
  readonly #permissionDescription: HTMLParagraphElement;
  readonly #permissionDetails: HTMLUListElement;
  readonly #permissionStatus: HTMLDivElement;
  readonly #permissionAllow: HTMLButtonElement;
  readonly #permissionSkip: HTMLButtonElement;
  readonly #permissionClose: HTMLButtonElement;
  readonly #options: ToolbarOptions;
  readonly #annotations: Annotation[] = [];
  readonly #annotationAddedAt = new Map<string, number>();
  #fadeTimer: number | undefined;
  #fadeFrame: number | undefined;
  #drawing = false;
  #annotating = false;
  #draft: NormalizedPoint[] = [];
  #annotationKind: AnnotationKind = 'freehand';
  #pixelRatio = 1;
  #disposed = false;
  #permissionResolve: ((decision: PermissionDecision) => void) | undefined;
  #returnFocus: HTMLElement | null = null;

  constructor(mount: HTMLElement, options: ToolbarOptions) {
    this.#options = options;
    this.#host = document.createElement('div');
    this.#host.dataset.highliteRoot = '';
    this.#host.style.setProperty('--highlite-z', String(options.zIndex));
    this.#root = this.#host.attachShadow({ mode: 'open' });

    const style = document.createElement('style');
    style.textContent = styles;
    this.#root.append(style);

    this.#canvas = document.createElement('canvas');
    this.#canvas.setAttribute('aria-hidden', 'true');
    this.#root.append(this.#canvas);
    const context = this.#canvas.getContext('2d');
    if (!context) throw new Error('Canvas is unavailable; annotations cannot be drawn.');
    this.#context = context;

    this.#panel = document.createElement('div');
    this.#panel.className = 'panel';
    this.#panel.hidden = true;
    this.#panel.setAttribute('role', 'region');
    this.#panel.setAttribute('aria-label', 'Highlite capture toolbar');

    const heading = document.createElement('div');
    heading.className = 'heading';
    const title = document.createElement('strong');
    title.textContent = 'Capture context';
    this.#recordingBadge = document.createElement('span');
    this.#recordingBadge.className = 'recording';
    this.#recordingBadge.textContent = 'Recording';
    this.#recordingBadge.hidden = true;
    heading.append(title, this.#recordingBadge);

    this.#status = document.createElement('div');
    this.#status.className = 'status';
    this.#status.setAttribute('role', 'status');
    this.#status.setAttribute('aria-live', 'polite');
    this.#status.textContent = 'Ready when you are.';

    const disclosure = document.createElement('p');
    disclosure.className = 'disclosure';
    disclosure.textContent =
      'Microphone and screen access are requested one at a time after you press Record. Captured pixels are not automatically redacted.';

    const primaryRow = document.createElement('div');
    primaryRow.className = 'row';
    this.#recordButton = this.#button('Record', 'Start capture', 'primary');
    this.#markButton = this.#button('Mark', 'Capture a marked moment');
    this.#stopButton = this.#button('Stop', 'Stop capture', 'danger');
    this.#cancelButton = this.#button('Cancel', 'Discard capture');
    primaryRow.append(this.#recordButton, this.#markButton, this.#stopButton, this.#cancelButton);

    const annotationRow = document.createElement('div');
    annotationRow.className = 'row';
    this.#annotateButton = this.#button('Annotate: off', 'Enter annotation mode');
    this.#annotateButton.setAttribute('aria-pressed', 'false');
    this.#shapeSelect = document.createElement('select');
    this.#shapeSelect.setAttribute('aria-label', 'Annotation shape');
    for (const [value, label] of [
      ['freehand', 'Freehand'],
      ['circle', 'Circle'],
      ['arrow', 'Arrow'],
      ['highlight', 'Highlight'],
    ] satisfies Array<[AnnotationKind, string]>) {
      const option = document.createElement('option');
      option.value = value;
      option.textContent = label;
      this.#shapeSelect.append(option);
    }
    annotationRow.append(this.#annotateButton, this.#shapeSelect);

    this.#exportButton = this.#button('Download ZIP', 'Download the capture bundle', 'primary');
    this.#exportButton.hidden = true;
    this.#panel.append(
      heading,
      this.#status,
      disclosure,
      primaryRow,
      annotationRow,
      this.#exportButton,
    );

    const toolbar = document.createElement('div');
    toolbar.className = 'toolbar';
    const launcher = this.#button('Capture context', 'Open Highlite capture tools', 'primary');
    launcher.className = 'launcher';
    launcher.addEventListener('click', () => {
      this.#panel.hidden = !this.#panel.hidden;
      launcher.setAttribute('aria-expanded', String(!this.#panel.hidden));
    });

    toolbar.append(this.#panel, launcher);
    this.#root.append(toolbar);

    this.#backdrop = document.createElement('div');
    this.#backdrop.className = 'backdrop';
    this.#backdrop.hidden = true;
    const modal = document.createElement('div');
    modal.className = 'modal';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-labelledby', 'highlite-permission-title');
    modal.setAttribute('aria-describedby', 'highlite-permission-description');

    this.#permissionStep = document.createElement('p');
    this.#permissionStep.className = 'step';
    this.#permissionTitle = document.createElement('h2');
    this.#permissionTitle.id = 'highlite-permission-title';
    this.#permissionDescription = document.createElement('p');
    this.#permissionDescription.className = 'description';
    this.#permissionDescription.id = 'highlite-permission-description';
    this.#permissionDetails = document.createElement('ul');
    this.#permissionDetails.className = 'details';
    this.#permissionStatus = document.createElement('div');
    this.#permissionStatus.className = 'permission-status';
    this.#permissionStatus.setAttribute('role', 'status');
    this.#permissionStatus.setAttribute('aria-live', 'polite');

    const actions = document.createElement('div');
    actions.className = 'actions';
    this.#permissionAllow = this.#button('Allow', 'Allow this permission', 'primary');
    this.#permissionSkip = this.#button('Not now', 'Continue without this permission');
    this.#permissionClose = this.#button('×', 'Cancel capture and discard', 'close');
    this.#permissionClose.title = 'Cancel capture';
    actions.append(this.#permissionAllow, this.#permissionSkip);

    modal.append(
      this.#permissionClose,
      this.#permissionStep,
      this.#permissionTitle,
      this.#permissionDescription,
      this.#permissionDetails,
      this.#permissionStatus,
      actions,
    );
    this.#backdrop.append(modal);
    this.#root.append(this.#backdrop);

    mount.append(this.#host);
    this.#bindControls();
    this.#resizeCanvas();
    window.addEventListener('resize', this.#resizeCanvas);
  }

  readonly #resizeCanvas = (): void => {
    const width = window.innerWidth;
    const height = window.innerHeight;
    this.#pixelRatio = Math.max(1, window.devicePixelRatio || 1);
    this.#canvas.width = Math.round(width * this.#pixelRatio);
    this.#canvas.height = Math.round(height * this.#pixelRatio);
    this.#canvas.style.width = `${width}px`;
    this.#canvas.style.height = `${height}px`;
    this.#context.setTransform(this.#pixelRatio, 0, 0, this.#pixelRatio, 0, 0);
    this.#draw();
  };

  setStatus(message: string): void {
    this.#status.textContent = message;
  }

  requestPermission(request: PermissionRequest): Promise<PermissionDecision> {
    this.dismissPermission();
    this.#permissionStep.textContent = `Permission ${request.step} of ${request.total}`;
    this.#permissionTitle.textContent = request.title;
    this.#permissionDescription.textContent = request.description;
    this.#permissionDetails.replaceChildren(
      ...request.details.map((text) => {
        const item = document.createElement('li');
        item.textContent = text;
        return item;
      }),
    );
    this.#permissionStatus.textContent = '';
    this.#permissionAllow.textContent = request.allowLabel;
    this.#permissionAllow.setAttribute('aria-label', request.allowLabel);
    this.#permissionAllow.disabled = false;
    this.#permissionSkip.textContent = request.skipLabel;
    this.#permissionSkip.setAttribute('aria-label', request.skipLabel);
    this.#permissionSkip.disabled = false;
    this.#permissionClose.disabled = false;
    this.#returnFocus =
      this.#root.activeElement instanceof HTMLElement ? this.#root.activeElement : null;
    this.#backdrop.hidden = false;
    requestAnimationFrame(() => this.#permissionAllow.focus());
    return new Promise((resolve) => {
      this.#permissionResolve = resolve;
    });
  }

  setPermissionWaiting(message: string): void {
    this.#permissionStatus.textContent = message;
    this.#permissionAllow.disabled = true;
    this.#permissionSkip.disabled = true;
  }

  dismissPermission(): void {
    const resolve = this.#permissionResolve;
    this.#permissionResolve = undefined;
    if (this.#backdrop.hidden && !resolve) return;
    this.#backdrop.hidden = true;
    this.#permissionDetails.replaceChildren();
    this.#permissionStatus.textContent = '';
    this.#returnFocus?.focus();
    this.#returnFocus = null;
    resolve?.('skipped');
  }

  setStarting(): void {
    this.#panel.hidden = false;
    this.#recordingBadge.hidden = true;
    this.#recordButton.hidden = true;
    this.#markButton.hidden = true;
    this.#annotateButton.hidden = true;
    this.#shapeSelect.hidden = true;
    this.#stopButton.hidden = true;
    this.#cancelButton.hidden = false;
    this.#exportButton.hidden = true;
    this.setStatus('Starting capture…');
  }

  setRecording(recording: boolean): void {
    this.#recordingBadge.hidden = !recording;
    this.#recordButton.hidden = recording;
    this.#markButton.hidden = !recording;
    this.#annotateButton.hidden = !recording;
    this.#shapeSelect.hidden = !recording;
    this.#stopButton.hidden = !recording;
    this.#cancelButton.hidden = !recording;
    if (!recording) this.#setAnnotating(false);
  }

  setProcessing(): void {
    this.dismissPermission();
    this.#setAnnotating(false);
    this.#recordingBadge.hidden = true;
    this.#recordButton.hidden = true;
    this.#markButton.hidden = true;
    this.#annotateButton.hidden = true;
    this.#shapeSelect.hidden = true;
    this.#stopButton.hidden = true;
    this.#cancelButton.hidden = true;
    this.#exportButton.hidden = true;
    this.setStatus('Finishing audio and assembling the capture bundle…');
  }

  setComplete(): void {
    this.dismissPermission();
    this.#setAnnotating(false);
    this.#recordingBadge.hidden = true;
    this.#recordButton.hidden = true;
    this.#markButton.hidden = true;
    this.#annotateButton.hidden = true;
    this.#shapeSelect.hidden = true;
    this.#stopButton.hidden = true;
    this.#cancelButton.hidden = true;
    this.#exportButton.hidden = false;
    this.#panel.hidden = false;
    this.setStatus('Capture ready. Download the portable ZIP bundle.');
  }

  setCancelled(): void {
    this.dismissPermission();
    this.#setAnnotating(false);
    this.#recordingBadge.hidden = true;
    this.#recordButton.hidden = true;
    this.#markButton.hidden = true;
    this.#annotateButton.hidden = true;
    this.#shapeSelect.hidden = true;
    this.#stopButton.hidden = true;
    this.#cancelButton.hidden = true;
    this.#exportButton.hidden = true;
    this.setStatus('Capture discarded. No bundle was created.');
  }

  addAnnotation(annotation: Annotation): void {
    this.#annotations.push(annotation);
    this.#annotationAddedAt.set(annotation.id, performance.now());
    this.#scheduleFade();
    this.#draw();
  }

  clearAnnotations(): void {
    this.#annotations.length = 0;
    this.#annotationAddedAt.clear();
    this.#cancelFade();
    this.#draw();
  }

  destroy(): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#cancelFade();
    this.dismissPermission();
    window.removeEventListener('resize', this.#resizeCanvas);
    this.#host.remove();
  }

  #button(label: string, ariaLabel: string, className = ''): HTMLButtonElement {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    button.setAttribute('aria-label', ariaLabel);
    if (className) button.className = className;
    return button;
  }

  #bindControls(): void {
    this.#recordButton.addEventListener('click', () => this.#run(this.#options.onStart));
    this.#markButton.addEventListener('click', () => this.#run(this.#options.onMark));
    this.#stopButton.addEventListener('click', () => this.#run(this.#options.onStop));
    this.#cancelButton.addEventListener('click', () => this.#run(this.#options.onCancel));
    this.#exportButton.addEventListener('click', () => this.#run(this.#options.onExport));
    this.#annotateButton.addEventListener('click', () => this.#setAnnotating(!this.#annotating));
    this.#shapeSelect.addEventListener('change', () => {
      this.#annotationKind = this.#shapeSelect.value as AnnotationKind;
    });
    this.#canvas.addEventListener('pointerdown', this.#onPointerDown);
    this.#canvas.addEventListener('pointermove', this.#onPointerMove);
    this.#canvas.addEventListener('pointerup', this.#onPointerUp);
    this.#canvas.addEventListener('pointercancel', this.#onPointerCancel);
    this.#permissionAllow.addEventListener('click', this.#onPermissionAllow);
    this.#permissionSkip.addEventListener('click', () => this.#finishPermission('skipped'));
    this.#permissionClose.addEventListener('click', () => {
      this.#run(this.#options.onCancel);
      this.dismissPermission();
    });
    this.#backdrop.addEventListener('click', (event) => {
      if (event.target === this.#backdrop) this.#finishPermission('skipped');
    });
    this.#backdrop.addEventListener('keydown', this.#onPermissionKeydown);
  }

  readonly #onPermissionAllow = (): void => {
    const resolve = this.#permissionResolve;
    if (!resolve) return;
    this.#permissionResolve = undefined;
    this.#permissionAllow.disabled = true;
    this.#permissionSkip.disabled = true;
    this.#permissionAllow.textContent = 'Waiting for permission…';
    resolve('granted');
  };

  readonly #onPermissionKeydown = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') {
      event.preventDefault();
      this.#finishPermission('skipped');
      return;
    }
    if (event.key !== 'Tab') return;
    const focusable = [this.#permissionClose, this.#permissionAllow, this.#permissionSkip].filter(
      (button) => !button.disabled,
    );
    const first = focusable[0];
    const last = focusable.at(-1);
    if (!first || !last) return;
    if (event.shiftKey && this.#root.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && this.#root.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  #finishPermission(decision: PermissionDecision): void {
    const resolve = this.#permissionResolve;
    this.#permissionResolve = undefined;
    this.#backdrop.hidden = true;
    this.#permissionDetails.replaceChildren();
    this.#permissionStatus.textContent = '';
    this.#returnFocus?.focus();
    this.#returnFocus = null;
    resolve?.(decision);
  }

  #run(action: () => void): void {
    try {
      action();
    } catch (error) {
      this.setStatus(error instanceof Error ? error.message : 'Capture action failed.');
    }
  }

  #setAnnotating(annotating: boolean): void {
    this.#annotating = annotating;
    this.#canvas.style.pointerEvents = annotating ? 'auto' : 'none';
    this.#canvas.style.cursor = annotating ? 'crosshair' : 'default';
    this.#annotateButton.textContent = annotating ? 'Interact' : 'Annotate: off';
    this.#annotateButton.setAttribute(
      'aria-label',
      annotating ? 'Return to interact mode' : 'Enter annotation mode',
    );
    this.#annotateButton.setAttribute('aria-pressed', String(annotating));
    this.#options.onAnnotatingChange(annotating);
  }

  readonly #onPointerDown = (event: PointerEvent): void => {
    if (!this.#annotating || event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    this.#drawing = true;
    this.#draft = pointerSamples(event, window.innerWidth, window.innerHeight);
    this.#canvas.setPointerCapture(event.pointerId);
    this.#draw();
  };

  readonly #onPointerMove = (event: PointerEvent): void => {
    if (!this.#drawing) return;
    event.preventDefault();
    event.stopPropagation();
    appendPointerSamples(this.#draft, event, window.innerWidth, window.innerHeight);
    this.#draw();
  };

  readonly #onPointerUp = (event: PointerEvent): void => {
    if (!this.#drawing) return;
    event.preventDefault();
    event.stopPropagation();
    appendPointerSamples(this.#draft, event, window.innerWidth, window.innerHeight);
    this.#drawing = false;
    this.#canvas.releasePointerCapture(event.pointerId);
    this.#draw();

    const previousPointerEvents = this.#host.style.pointerEvents;
    const previousCanvasPointerEvents = this.#canvas.style.pointerEvents;
    this.#host.style.pointerEvents = 'none';
    this.#canvas.style.pointerEvents = 'none';
    const target = document.elementFromPoint(event.clientX, event.clientY);
    this.#canvas.style.pointerEvents = previousCanvasPointerEvents;
    this.#host.style.pointerEvents = previousPointerEvents;
    this.#options.onAnnotation(
      this.#annotationKind,
      [...this.#draft],
      event.clientX,
      event.clientY,
      target,
    );
    this.#draft = [];
  };

  readonly #onPointerCancel = (): void => {
    this.#drawing = false;
    this.#draft = [];
    this.#draw();
  };

  #draw(now = performance.now()): void {
    const context = this.#context;
    context.clearRect(0, 0, window.innerWidth, window.innerHeight);
    for (const annotation of this.#annotations) {
      const start = this.#annotationAddedAt.get(annotation.id) ?? now;
      const opacity = annotationOpacity(now - start);
      if (opacity > 0) this.#drawAnnotation(annotation.kind, annotation.points, opacity);
    }
    if (this.#drawing) this.#drawAnnotation(this.#annotationKind, this.#draft, 1);
  }

  #scheduleFade(): void {
    if (this.#disposed || this.#fadeTimer !== undefined || this.#fadeFrame !== undefined) return;
    if (this.#annotations.length === 0) return;

    const now = performance.now();
    let wait = Number.POSITIVE_INFINITY;
    for (const annotation of this.#annotations) {
      const start = this.#annotationAddedAt.get(annotation.id) ?? now;
      wait = Math.min(wait, Math.max(0, start + ANNOTATION_FADE_AFTER_MS - now));
    }
    if (!Number.isFinite(wait)) return;
    this.#fadeTimer = window.setTimeout(() => {
      this.#fadeTimer = undefined;
      this.#startFadeFrame();
    }, wait);
  }

  #startFadeFrame(): void {
    if (this.#disposed || this.#fadeFrame !== undefined) return;
    const step = (): void => {
      this.#fadeFrame = undefined;
      if (this.#disposed) return;
      const now = performance.now();
      this.#draw(now);
      this.#pruneExpired(now);
      const fading = this.#annotations.some((annotation) => {
        const start = this.#annotationAddedAt.get(annotation.id) ?? now;
        return annotationOpacity(now - start) < 1;
      });
      if (fading) {
        this.#fadeFrame = window.requestAnimationFrame(step);
      } else if (this.#annotations.length > 0) {
        this.#scheduleFade();
      }
    };
    this.#fadeFrame = window.requestAnimationFrame(step);
  }

  #pruneExpired(now: number): void {
    for (let index = this.#annotations.length - 1; index >= 0; index -= 1) {
      const annotation = this.#annotations[index]!;
      const start = this.#annotationAddedAt.get(annotation.id) ?? now;
      if (annotationOpacity(now - start) > 0) continue;
      this.#annotations.splice(index, 1);
      this.#annotationAddedAt.delete(annotation.id);
    }
  }

  #cancelFade(): void {
    if (this.#fadeTimer !== undefined) {
      window.clearTimeout(this.#fadeTimer);
      this.#fadeTimer = undefined;
    }
    if (this.#fadeFrame !== undefined) {
      window.cancelAnimationFrame(this.#fadeFrame);
      this.#fadeFrame = undefined;
    }
  }

  #drawAnnotation(kind: AnnotationKind, points: Annotation['points'], opacity = 1): void {
    if (points.length < 2) return;
    const context = this.#context;
    const width = window.innerWidth;
    const height = window.innerHeight;
    const pixels = points.map((point) => ({ x: point.x * width, y: point.y * height }));
    const first = pixels[0]!;
    const last = pixels.at(-1)!;
    context.save();
    context.globalAlpha = opacity;
    context.strokeStyle = '#ff3b5c';
    context.fillStyle = 'rgba(255, 214, 10, .24)';
    context.lineWidth = ANNOTATION_LINE_WIDTH;
    context.lineCap = 'round';
    context.lineJoin = 'round';

    if (kind === 'freehand') {
      context.beginPath();
      context.moveTo(first.x, first.y);
      for (const point of pixels.slice(1)) context.lineTo(point.x, point.y);
      context.stroke();
    } else if (kind === 'circle') {
      const x = Math.min(first.x, last.x);
      const y = Math.min(first.y, last.y);
      context.beginPath();
      context.ellipse(
        x + Math.abs(last.x - first.x) / 2,
        y + Math.abs(last.y - first.y) / 2,
        Math.max(2, Math.abs(last.x - first.x) / 2),
        Math.max(2, Math.abs(last.y - first.y) / 2),
        0,
        0,
        Math.PI * 2,
      );
      context.stroke();
    } else if (kind === 'highlight') {
      context.fillRect(first.x, first.y, last.x - first.x, last.y - first.y);
      context.strokeRect(first.x, first.y, last.x - first.x, last.y - first.y);
    } else {
      const angle = Math.atan2(last.y - first.y, last.x - first.x);
      context.beginPath();
      context.moveTo(first.x, first.y);
      context.lineTo(last.x, last.y);
      context.lineTo(
        last.x - ANNOTATION_ARROW_HEAD * Math.cos(angle - Math.PI / 6),
        last.y - ANNOTATION_ARROW_HEAD * Math.sin(angle - Math.PI / 6),
      );
      context.moveTo(last.x, last.y);
      context.lineTo(
        last.x - ANNOTATION_ARROW_HEAD * Math.cos(angle + Math.PI / 6),
        last.y - ANNOTATION_ARROW_HEAD * Math.sin(angle + Math.PI / 6),
      );
      context.stroke();
    }
    context.restore();
  }
}
