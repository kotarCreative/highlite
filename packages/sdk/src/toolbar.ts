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
[hidden] { display: none !important; }
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
.row button:disabled, .row select:disabled { cursor: not-allowed; opacity: .52; }
canvas { position: fixed; inset: 0; width: 100vw; height: 100vh; pointer-events: none; touch-action: none; }
.dock { position: fixed; left: 50%; bottom: 24px; display: flex; max-width: calc(100vw - 32px); flex-direction: column; align-items: center; gap: 10px; transform: translateX(-50%); pointer-events: none; }
.dock-status { position: relative; z-index: 1; max-width: min(560px, calc(100vw - 48px)); padding: 7px 13px; border-radius: 999px; background: #16181de6; box-shadow: 0 10px 26px #0f111640; color: #dfe3eb; font-size: 12px; line-height: 1.35; text-align: center; pointer-events: auto; }
.dock-status:empty { display: none; }
.dock-bar { display: flex; align-items: center; gap: 6px; padding: 7px; border-radius: 16px; background: #16181df7; box-shadow: 0 18px 44px #0f111659, inset 0 0 0 1px #ffffff12; color: #e7eaf0; pointer-events: auto; }
.rec { display: inline-flex; align-items: center; gap: 7px; padding: 0 9px 0 7px; color: #ff9b9e; font-size: 10px; font-weight: 700; line-height: 1; letter-spacing: .07em; text-transform: uppercase; white-space: nowrap; }
/* Uppercase cap-height sits high in the line box; nudge it onto the dot's center. */
.rec span { position: relative; top: 1.5px; }
.rec::before { width: 8px; height: 8px; border-radius: 50%; background: #f2555a; box-shadow: 0 0 0 3px #f2555a2e; content: ''; animation: highlite-pulse 1.8s ease-in-out infinite; }
.rec.is-starting { color: #b8c0ce; }
.rec.is-starting::before { background: #8f99a8; box-shadow: none; animation: none; }
@keyframes highlite-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .4; } }
@media (prefers-reduced-motion: reduce) { .rec::before { animation: none; } }
.tools { display: flex; align-items: center; gap: 2px; }
.tool, .discard { position: relative; display: grid; width: 38px; height: 38px; place-items: center; border: 0; border-radius: 10px; padding: 0; background: transparent; color: #aeb6c4; cursor: pointer; }
.tool svg { width: 19px; height: 19px; }
.discard svg { width: 18px; height: 18px; }
.tool:hover, .discard:hover { background: #272b34; color: #fff; }
.tool[aria-pressed='true'] { background: #5a66dc; color: #fff; box-shadow: inset 0 1px 0 #ffffff2e; }
.tool:focus-visible, .discard:focus-visible, .mark:focus-visible, .stop:focus-visible { outline: 3px solid #91a7ff; outline-offset: 2px; }
.tool::after, .discard::after { content: attr(data-tooltip); position: absolute; left: 50%; bottom: calc(100% + 9px); z-index: 2; padding: 5px 9px; border-radius: 7px; background: #f5f6f9; box-shadow: 0 6px 18px #0f11164d; color: #16181d; font-size: 11px; font-weight: 600; line-height: 1.3; letter-spacing: 0; text-transform: none; white-space: nowrap; opacity: 0; visibility: hidden; transform: translate(-50%, 2px); transition: opacity .12s ease, transform .12s ease, visibility .12s; pointer-events: none; }
.tool:hover::after, .tool:focus-visible::after, .discard:hover::after, .discard:focus-visible::after { opacity: 1; visibility: visible; transform: translate(-50%, 0); }
.tools > .tool:first-child::after { left: 0; transform: translate(0, 2px); }
.tools > .tool:first-child:hover::after, .tools > .tool:first-child:focus-visible::after { transform: translate(0, 0); }
.separator { width: 1px; height: 24px; margin: 0 4px; background: #ffffff1f; }
.mark { display: inline-flex; height: 38px; align-items: center; gap: 7px; padding: 0 13px; border: 0; border-radius: 10px; background: #ffffff12; color: #e7eaf0; font-size: 12px; font-weight: 600; cursor: pointer; }
.mark svg { width: 16px; height: 16px; }
.mark:hover { background: #ffffff21; }
.stop { display: inline-flex; height: 38px; align-items: center; gap: 8px; padding: 0 16px 0 13px; border: 0; border-radius: 10px; background: #e5484d; color: #fff; font-size: 13px; font-weight: 700; cursor: pointer; box-shadow: inset 0 1px 0 #ffffff2e; }
.stop svg { width: 16px; height: 16px; }
.stop:hover { background: #d93d42; }
@media (max-width: 560px) {
  .dock { bottom: 16px; }
  .dock-bar { gap: 4px; padding: 6px; }
  .rec { padding: 0 4px; }
  .rec span, .mark span { display: none; }
  .tool, .discard, .mark { width: 32px; height: 32px; }
  .mark { justify-content: center; padding: 0; }
  .separator { margin: 0 2px; }
  .stop { height: 32px; padding: 0 12px; }
  .dock-status { font-size: 11px; }
}
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
.actions button.danger { border-color: #e5484d; background: #e5484d; color: #fff; font-weight: 700; }
.actions button.danger:hover { background: #d93d42; }
.actions button:disabled { cursor: progress; opacity: .6; }
`;

const ICON_POINTER =
  '<path d="M4.04 4.69a.5.5 0 0 1 .65-.65l16 6.5a.5.5 0 0 1-.06.95l-6.13 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.12a.5.5 0 0 1-.95.06z"/>';
const ICON_PEN =
  '<path d="M17 3a2.83 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/>';
const ICON_CIRCLE = '<circle cx="12" cy="12" r="8.5"/>';
const ICON_ARROW = '<path d="M5 19 19 5"/><path d="M9 5h10v10"/>';
const ICON_HIGHLIGHT =
  '<path d="m9 11-6 6v3h9l3-3"/><path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4Z"/>';
const ICON_BOOKMARK = '<path d="m19 21-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2Z"/>';
const ICON_TRASH =
  '<path d="M3 6h18"/><path d="M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2"/><path d="m19 6-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11h4"/><path d="M10 15h4"/>';
const ICON_STOP =
  '<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor" stroke="none"/>';

/** One compact tool button per annotation kind, in the order shown in the session dock. */
const ANNOTATION_TOOLS: ReadonlyArray<{
  kind: AnnotationKind;
  label: string;
  hint: string;
  shortcut: string;
  icon: string;
}> = [
  {
    kind: 'freehand',
    label: 'Freehand annotation',
    hint: 'Freehand — draw a stroke (Ctrl+F)',
    shortcut: 'Control+F',
    icon: ICON_PEN,
  },
  {
    kind: 'circle',
    label: 'Circle annotation',
    hint: 'Circle — drag to outline an area (Ctrl+C)',
    shortcut: 'Control+C',
    icon: ICON_CIRCLE,
  },
  {
    kind: 'arrow',
    label: 'Arrow annotation',
    hint: 'Arrow — drag to point at something (Ctrl+A)',
    shortcut: 'Control+A',
    icon: ICON_ARROW,
  },
  {
    kind: 'highlight',
    label: 'Highlight annotation',
    hint: 'Highlight — drag to shade an area (Ctrl+H)',
    shortcut: 'Control+H',
    icon: ICON_HIGHLIGHT,
  },
];

/** Single-letter shortcuts that select an annotation tool while recording. */
const TOOL_SHORTCUTS: Readonly<Record<string, AnnotationKind>> = {
  f: 'freehand',
  c: 'circle',
  a: 'arrow',
  h: 'highlight',
};

function iconSvg(body: string): string {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
}

export class CaptureToolbar {
  readonly #host: HTMLDivElement;
  readonly #root: ShadowRoot;
  readonly #panel: HTMLDivElement;
  readonly #launcher: HTMLButtonElement;
  readonly #status: HTMLDivElement;
  readonly #dock: HTMLDivElement;
  readonly #dockStatus: HTMLDivElement;
  readonly #dockLabel: HTMLSpanElement;
  readonly #dockLabelText: HTMLSpanElement;
  readonly #tools: HTMLDivElement;
  readonly #interactButton: HTMLButtonElement;
  readonly #toolButtons = new Map<AnnotationKind, HTMLButtonElement>();
  readonly #recordButton: HTMLButtonElement;
  readonly #markButton: HTMLButtonElement;
  readonly #stopButton: HTMLButtonElement;
  readonly #cancelButton: HTMLButtonElement;
  readonly #exportButton: HTMLButtonElement;
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
  readonly #confirmBackdrop: HTMLDivElement;
  readonly #confirmKeep: HTMLButtonElement;
  readonly #confirmDiscardButton: HTMLButtonElement;
  readonly #options: ToolbarOptions;
  readonly #annotations: Annotation[] = [];
  readonly #annotationAddedAt = new Map<string, number>();
  #fadeTimer: number | undefined;
  #fadeFrame: number | undefined;
  #statusTimer: number | undefined;
  #drawing = false;
  #annotating = false;
  #recording = false;
  #draft: NormalizedPoint[] = [];
  #annotationKind: AnnotationKind = 'freehand';
  #pixelRatio = 1;
  #disposed = false;
  #permissionResolve: ((decision: PermissionDecision) => void) | undefined;
  #returnFocus: HTMLElement | null = null;
  #confirmReturnFocus: HTMLElement | null = null;

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
    this.#panel.setAttribute('aria-label', 'Highlite session toolbar');

    const heading = document.createElement('div');
    heading.className = 'heading';
    const title = document.createElement('strong');
    title.textContent = 'Highlite session';
    heading.append(title);

    this.#status = document.createElement('div');
    this.#status.className = 'status';
    this.#status.setAttribute('role', 'status');
    this.#status.setAttribute('aria-live', 'polite');
    this.#status.textContent = 'Ready when you are.';

    const disclosure = document.createElement('p');
    disclosure.className = 'disclosure';
    disclosure.textContent =
      'Microphone and screen access are requested one at a time after you press Record. Shared screen pixels are not automatically redacted.';

    const primaryRow = document.createElement('div');
    primaryRow.className = 'row';
    this.#recordButton = this.#button('Record', 'Start Highlite', 'primary');
    primaryRow.append(this.#recordButton);

    this.#exportButton = this.#button('Download ZIP', 'Download the Highlite bundle', 'primary');
    this.#exportButton.hidden = true;
    this.#panel.id = 'highlite-capture-panel';
    this.#panel.append(heading, this.#status, disclosure, primaryRow, this.#exportButton);

    const toolbar = document.createElement('div');
    toolbar.className = 'toolbar';
    this.#launcher = this.#button('Highlite', 'Open Highlite tools', 'primary');
    this.#launcher.className = 'launcher';
    this.#launcher.setAttribute('aria-expanded', 'false');
    this.#launcher.setAttribute('aria-controls', 'highlite-capture-panel');
    this.#launcher.addEventListener('click', () => this.#setPanelOpen(this.#panel.hidden));

    toolbar.append(this.#panel, this.#launcher);
    this.#root.append(toolbar);

    this.#dock = document.createElement('div');
    this.#dock.className = 'dock';
    this.#dock.hidden = true;

    this.#dockStatus = document.createElement('div');
    this.#dockStatus.className = 'dock-status';
    this.#dockStatus.setAttribute('role', 'status');
    this.#dockStatus.setAttribute('aria-live', 'polite');

    const dockBar = document.createElement('div');
    dockBar.className = 'dock-bar';
    dockBar.setAttribute('role', 'toolbar');
    dockBar.setAttribute('aria-label', 'Highlite session actions');
    dockBar.setAttribute('aria-orientation', 'horizontal');

    this.#dockLabel = document.createElement('span');
    this.#dockLabel.className = 'rec';
    this.#dockLabelText = document.createElement('span');
    this.#dockLabelText.textContent = 'Recording';
    this.#dockLabel.append(this.#dockLabelText);

    this.#tools = document.createElement('div');
    this.#tools.className = 'tools';
    this.#tools.setAttribute('role', 'group');
    this.#tools.setAttribute('aria-label', 'Annotate');
    this.#interactButton = this.#iconButton(
      'Interact with page',
      ICON_POINTER,
      'Interact — click the page normally (Ctrl+V)',
      'Control+V',
    );
    this.#interactButton.setAttribute('aria-pressed', 'true');
    this.#tools.append(this.#interactButton);
    for (const tool of ANNOTATION_TOOLS) {
      const button = this.#iconButton(tool.label, tool.icon, tool.hint, tool.shortcut);
      button.setAttribute('aria-pressed', 'false');
      this.#toolButtons.set(tool.kind, button);
      this.#tools.append(button);
    }

    this.#markButton = document.createElement('button');
    this.#markButton.type = 'button';
    this.#markButton.className = 'mark';
    this.#markButton.setAttribute('aria-label', 'Mark a moment in Highlite');
    this.#markButton.setAttribute('aria-keyshortcuts', 'Control+M');
    this.#markButton.title = 'Mark this moment (Ctrl+M)';
    this.#markButton.innerHTML = `${iconSvg(ICON_BOOKMARK)}<span>Mark</span>`;

    this.#cancelButton = document.createElement('button');
    this.#cancelButton.type = 'button';
    this.#cancelButton.className = 'discard';
    this.#cancelButton.setAttribute('aria-label', 'Discard Highlite session');
    this.#cancelButton.setAttribute('aria-keyshortcuts', 'Control+D');
    this.#cancelButton.dataset.tooltip = 'Discard Highlite session (Ctrl+D)';
    this.#cancelButton.innerHTML = iconSvg(ICON_TRASH);

    this.#stopButton = document.createElement('button');
    this.#stopButton.type = 'button';
    this.#stopButton.className = 'stop';
    this.#stopButton.setAttribute('aria-label', 'Stop Highlite');
    this.#stopButton.setAttribute('aria-keyshortcuts', 'Control+S');
    this.#stopButton.title = 'Stop Highlite (Ctrl+S)';
    this.#stopButton.innerHTML = `${iconSvg(ICON_STOP)}<span>Stop</span>`;

    dockBar.append(
      this.#dockLabel,
      this.#tools,
      this.#separator(),
      this.#markButton,
      this.#separator(),
      this.#cancelButton,
      this.#stopButton,
    );
    this.#dock.append(this.#dockStatus, dockBar);
    this.#root.append(this.#dock);

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
    this.#permissionClose = this.#button('×', 'Cancel Highlite and discard', 'close');
    this.#permissionClose.title = 'Cancel Highlite';
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

    this.#confirmBackdrop = document.createElement('div');
    this.#confirmBackdrop.className = 'backdrop';
    this.#confirmBackdrop.hidden = true;
    const discardModal = document.createElement('div');
    discardModal.className = 'modal';
    discardModal.setAttribute('role', 'dialog');
    discardModal.setAttribute('aria-modal', 'true');
    discardModal.setAttribute('aria-labelledby', 'highlite-discard-title');
    discardModal.setAttribute('aria-describedby', 'highlite-discard-description');

    const discardTitle = document.createElement('h2');
    discardTitle.id = 'highlite-discard-title';
    discardTitle.textContent = 'Discard this Highlite session?';
    const discardDescription = document.createElement('p');
    discardDescription.className = 'description';
    discardDescription.id = 'highlite-discard-description';
    discardDescription.textContent =
      'The recording, narration audio, and screenshots will be deleted. This cannot be undone.';

    const discardActions = document.createElement('div');
    discardActions.className = 'actions';
    this.#confirmKeep = this.#button(
      'Keep recording',
      'Keep recording and return to the session',
      'primary',
    );
    this.#confirmDiscardButton = this.#button(
      'Discard Highlite session',
      'Discard Highlite session',
      'danger',
    );
    discardActions.append(this.#confirmKeep, this.#confirmDiscardButton);

    discardModal.append(discardTitle, discardDescription, discardActions);
    this.#confirmBackdrop.append(discardModal);
    this.#root.append(this.#confirmBackdrop);

    mount.append(this.#host);
    this.#bindControls();
    this.#resizeCanvas();
    window.addEventListener('resize', this.#resizeCanvas);
    window.addEventListener('keydown', this.#onKeydown, true);
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
    this.#setDockStatus(message);
  }

  #setDockStatus(message: string): void {
    if (this.#statusTimer !== undefined) {
      window.clearTimeout(this.#statusTimer);
      this.#statusTimer = undefined;
    }
    this.#dockStatus.textContent = message;
    if (!message) return;
    // The dock is an overlay above the page, so keep its status message brief;
    // the setup panel retains the full text after the session ends.
    this.#statusTimer = window.setTimeout(() => {
      this.#statusTimer = undefined;
      this.#dockStatus.textContent = '';
    }, 10_000);
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
    this.#recording = false;
    this.#setPanelOpen(false);
    this.#launcher.hidden = true;
    this.#dock.hidden = false;
    this.#dockLabel.classList.add('is-starting');
    this.#dockLabelText.textContent = 'Starting';
    this.#tools.hidden = true;
    this.#markButton.hidden = true;
    this.#stopButton.hidden = true;
    this.#cancelButton.hidden = false;
    this.#exportButton.hidden = true;
    this.#setAnnotating(false);
    this.setStatus('Starting Highlite…');
  }

  setRecording(recording: boolean): void {
    this.#recording = recording;
    this.#dock.hidden = !recording;
    if (!recording) {
      this.#setAnnotating(false);
      this.#setPanelOpen(true);
      this.#launcher.hidden = false;
      return;
    }
    this.#setPanelOpen(false);
    this.#launcher.hidden = true;
    this.#dockLabel.classList.remove('is-starting');
    this.#dockLabelText.textContent = 'Recording';
    this.#tools.hidden = false;
    this.#markButton.hidden = false;
    this.#stopButton.hidden = false;
    this.#cancelButton.hidden = false;
    this.#setDockStatus('');
  }

  setProcessing(): void {
    this.dismissPermission();
    this.#recording = false;
    this.#setAnnotating(false);
    this.#dock.hidden = true;
    this.#launcher.hidden = false;
    this.#setPanelOpen(true);
    this.#exportButton.hidden = true;
    this.setStatus('Finishing audio and assembling the Highlite bundle…');
  }

  setComplete(): void {
    this.dismissPermission();
    this.#recording = false;
    this.#setAnnotating(false);
    this.#dock.hidden = true;
    this.#launcher.hidden = false;
    this.#exportButton.hidden = false;
    this.#setPanelOpen(true);
    this.setStatus('Highlite session ready. Download the portable ZIP bundle.');
  }

  setCancelled(): void {
    this.dismissPermission();
    this.#recording = false;
    this.#dismissDiscard(false);
    this.#setAnnotating(false);
    this.#dock.hidden = true;
    this.#launcher.hidden = false;
    this.#exportButton.hidden = true;
    this.#setPanelOpen(true);
    this.setStatus('Highlite session discarded. No bundle was created.');
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
    if (this.#statusTimer !== undefined) {
      window.clearTimeout(this.#statusTimer);
      this.#statusTimer = undefined;
    }
    this.dismissPermission();
    this.#dismissDiscard(false);
    window.removeEventListener('resize', this.#resizeCanvas);
    window.removeEventListener('keydown', this.#onKeydown, true);
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

  #iconButton(label: string, icon: string, hint: string, shortcut: string): HTMLButtonElement {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'tool';
    button.setAttribute('aria-label', label);
    button.setAttribute('aria-keyshortcuts', shortcut);
    button.dataset.tooltip = hint;
    button.innerHTML = iconSvg(icon);
    return button;
  }

  #separator(): HTMLSpanElement {
    const separator = document.createElement('span');
    separator.className = 'separator';
    separator.setAttribute('aria-hidden', 'true');
    return separator;
  }

  #setPanelOpen(open: boolean): void {
    this.#panel.hidden = !open;
    this.#launcher.setAttribute('aria-expanded', String(open));
  }

  #bindControls(): void {
    this.#recordButton.addEventListener('click', () => this.#run(this.#options.onStart));
    this.#markButton.addEventListener('click', () => this.#run(this.#options.onMark));
    this.#stopButton.addEventListener('click', () => this.#run(this.#options.onStop));
    this.#cancelButton.addEventListener('click', () => this.#requestDiscard());
    this.#exportButton.addEventListener('click', () => this.#run(this.#options.onExport));
    this.#confirmKeep.addEventListener('click', () => this.#dismissDiscard());
    this.#confirmDiscardButton.addEventListener('click', () => this.#discardCapture());
    this.#confirmBackdrop.addEventListener('click', (event) => {
      if (event.target === this.#confirmBackdrop) this.#dismissDiscard();
    });
    this.#confirmBackdrop.addEventListener('keydown', this.#onDiscardKeydown);
    this.#interactButton.addEventListener('click', () => this.#setAnnotating(false));
    for (const [kind, button] of this.#toolButtons) {
      button.addEventListener('click', () => this.#selectTool(kind));
    }
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

  readonly #onDiscardKeydown = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') {
      event.preventDefault();
      this.#dismissDiscard();
      return;
    }
    if (event.key !== 'Tab') return;
    const first = this.#confirmKeep;
    const last = this.#confirmDiscardButton;
    if (event.shiftKey && this.#root.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && this.#root.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  readonly #onKeydown = (event: KeyboardEvent): void => {
    if (event.defaultPrevented || event.isComposing || event.repeat) return;
    if (event.metaKey || event.altKey || event.shiftKey) return;
    const target = event.target;
    if (
      target instanceof HTMLElement &&
      (target.isContentEditable ||
        target.closest(
          'input, textarea, select, [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="combobox"]',
        ) !== null)
    ) {
      return;
    }

    if (!this.#confirmBackdrop.hidden) {
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        this.#dismissDiscard();
      }
      return;
    }
    if (!this.#recording || this.#drawing) return;

    const key = event.key.toLowerCase();
    if (key === 'escape') {
      if (!this.#annotating) return;
      event.preventDefault();
      event.stopPropagation();
      this.#setAnnotating(false);
      return;
    }

    if (!event.ctrlKey) return;

    const tool = TOOL_SHORTCUTS[key];
    if (tool) {
      event.preventDefault();
      event.stopPropagation();
      this.#selectTool(tool);
      return;
    }

    if (key === 'v') {
      event.preventDefault();
      event.stopPropagation();
      this.#setAnnotating(false);
    } else if (key === 'm') {
      event.preventDefault();
      event.stopPropagation();
      this.#run(this.#options.onMark);
    } else if (key === 'd') {
      event.preventDefault();
      event.stopPropagation();
      this.#requestDiscard();
    } else if (key === 's') {
      event.preventDefault();
      event.stopPropagation();
      this.#run(this.#options.onStop);
    }
  };

  #requestDiscard(): void {
    if (!this.#confirmBackdrop.hidden) return;
    this.#confirmReturnFocus =
      this.#root.activeElement instanceof HTMLElement
        ? this.#root.activeElement
        : this.#cancelButton;
    this.#confirmBackdrop.hidden = false;
    requestAnimationFrame(() => this.#confirmKeep.focus());
  }

  #dismissDiscard(restoreFocus = true): void {
    if (this.#confirmBackdrop.hidden) return;
    this.#confirmBackdrop.hidden = true;
    const focus = this.#confirmReturnFocus;
    this.#confirmReturnFocus = null;
    if (restoreFocus) focus?.focus();
  }

  #discardCapture(): void {
    this.#confirmBackdrop.hidden = true;
    this.#confirmReturnFocus = null;
    this.#run(this.#options.onCancel);
  }

  #run(action: () => void): void {
    try {
      action();
    } catch (error) {
      this.setStatus(error instanceof Error ? error.message : 'Highlite action failed.');
    }
  }

  #selectTool(kind: AnnotationKind): void {
    this.#annotationKind = kind;
    this.#setAnnotating(true);
  }

  #setAnnotating(annotating: boolean): void {
    this.#annotating = annotating;
    this.#canvas.style.pointerEvents = annotating ? 'auto' : 'none';
    this.#canvas.style.cursor = annotating ? 'crosshair' : 'default';
    this.#interactButton.setAttribute('aria-pressed', String(!annotating));
    for (const [kind, button] of this.#toolButtons) {
      button.setAttribute('aria-pressed', String(annotating && kind === this.#annotationKind));
    }
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
