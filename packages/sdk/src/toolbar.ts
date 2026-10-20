import type { Annotation, AnnotationKind } from '@highlite/core';

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
.recording::before { width: 8px; height: 8px; border-radius: 50%; background: currentColor; content: ''; }
canvas { position: fixed; inset: 0; width: 100vw; height: 100vh; pointer-events: none; touch-action: none; }
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
  readonly #options: ToolbarOptions;
  readonly #annotations: Annotation[] = [];
  #drawing = false;
  #annotating = false;
  #draft: Annotation['points'] = [];
  #annotationKind: AnnotationKind = 'freehand';
  #pixelRatio = 1;
  #disposed = false;

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
      'Microphone and display capture are requested only after you press Record. Captured pixels are not automatically redacted.';

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
    this.setStatus('Waiting for microphone and display permissions…');
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
    this.#draw();
  }

  clearAnnotations(): void {
    this.#annotations.length = 0;
    this.#draw();
  }

  destroy(): void {
    if (this.#disposed) return;
    this.#disposed = true;
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
    this.#draft = [this.#normalizedPoint(event.clientX, event.clientY)];
    this.#canvas.setPointerCapture(event.pointerId);
    this.#draw();
  };

  readonly #onPointerMove = (event: PointerEvent): void => {
    if (!this.#drawing) return;
    event.preventDefault();
    event.stopPropagation();
    this.#draft.push(this.#normalizedPoint(event.clientX, event.clientY));
    this.#draw();
  };

  readonly #onPointerUp = (event: PointerEvent): void => {
    if (!this.#drawing) return;
    event.preventDefault();
    event.stopPropagation();
    this.#draft.push(this.#normalizedPoint(event.clientX, event.clientY));
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

  #normalizedPoint(clientX: number, clientY: number): { x: number; y: number } {
    return {
      x: Math.max(0, Math.min(1, clientX / Math.max(1, window.innerWidth))),
      y: Math.max(0, Math.min(1, clientY / Math.max(1, window.innerHeight))),
    };
  }

  #draw(): void {
    const context = this.#context;
    context.clearRect(0, 0, window.innerWidth, window.innerHeight);
    for (const annotation of this.#annotations)
      this.#drawAnnotation(annotation.kind, annotation.points);
    if (this.#drawing) this.#drawAnnotation(this.#annotationKind, this.#draft);
  }

  #drawAnnotation(kind: AnnotationKind, points: Annotation['points']): void {
    if (points.length < 2) return;
    const context = this.#context;
    const width = window.innerWidth;
    const height = window.innerHeight;
    const pixels = points.map((point) => ({ x: point.x * width, y: point.y * height }));
    const first = pixels[0]!;
    const last = pixels.at(-1)!;
    context.save();
    context.strokeStyle = '#ff3b5c';
    context.fillStyle = 'rgba(255, 214, 10, .24)';
    context.lineWidth = 4;
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
        last.x - 14 * Math.cos(angle - Math.PI / 6),
        last.y - 14 * Math.sin(angle - Math.PI / 6),
      );
      context.moveTo(last.x, last.y);
      context.lineTo(
        last.x - 14 * Math.cos(angle + Math.PI / 6),
        last.y - 14 * Math.sin(angle + Math.PI / 6),
      );
      context.stroke();
    }
    context.restore();
  }
}
