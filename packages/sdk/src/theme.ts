/**
 * Highlite recorder palette.
 *
 * These values mirror `crates/highlite-relay/src/ui-theme.css` so the browser
 * recorder and the relay dashboard read as one product. Keep semantic status
 * colors (success, warning, danger) separate from the decorative highlighter
 * accents, and always pair vivid marker colors with dark ink text.
 */
export const TOOLBAR_THEME = {
  canvas: '#fffdf5',
  surface: '#ffffff',
  surfaceMuted: '#fffbf0',
  ink: '#30232d',
  muted: '#75636c',
  line: '#eadfda',
  lineStrong: '#c9b7bd',
  primary: '#a92261',
  primaryHover: '#86194d',
  primarySoft: '#fff0f6',
  primaryBorder: '#f5b8d3',
  highlightYellow: '#efff3d',
  highlightOrange: '#ffad60',
  highlightOrangeHover: '#ffbd7d',
  highlightPink: '#ff81bd',
  action: '#efff3d',
  actionHover: '#e0ef2a',
  actionInk: '#30232d',
  success: '#087443',
  successSoft: '#e9f7ef',
  danger: '#b4232d',
  dangerSurface: '#b4232d',
  dangerSurfaceHover: '#941a23',
  dangerInk: '#ffffff',
  warning: '#9a5700',
  warningSoft: '#fff5e5',
  neutralSoft: '#f3eee8',
  overlay: '#30232d7a',
  dockInk: '#30232d',
  dockMuted: '#c4b2bc',
  dockHover: '#3d2f37',
  dockLine: '#4b3943',
  dockText: '#fffdf5',
  recording: '#ff7b81',
  tooltipBackground: '#30232d',
  tooltipInk: '#fffdf5',
} as const;

export type ToolbarTheme = {
  readonly [Name in keyof typeof TOOLBAR_THEME]: string;
};

/**
 * Dark appearance tokens. The floating dock deliberately keeps the brand ink
 * surface in both appearances; light panels and popovers adapt instead.
 */
export const TOOLBAR_DARK_THEME: Partial<ToolbarTheme> = {
  canvas: '#1b1519',
  surface: '#241d22',
  surfaceMuted: '#2a2228',
  ink: '#f7efe8',
  muted: '#c4b2bc',
  line: '#40333b',
  lineStrong: '#5b4a54',
  primary: '#ff81bd',
  primaryHover: '#ff9dcc',
  primarySoft: '#3a2230',
  primaryBorder: '#7a3b5d',
  success: '#5bd39a',
  successSoft: '#173528',
  danger: '#ff7b81',
  warning: '#ffc46b',
  warningSoft: '#382a16',
  neutralSoft: '#332b30',
  overlay: '#000000a6',
  tooltipBackground: '#f7efe8',
  tooltipInk: '#30232d',
};

/** Annotation ink follows the same brand hierarchy as the recorder controls. */
export const ANNOTATION_STROKE = TOOLBAR_THEME.primary;
export const ANNOTATION_STROKE_DARK = TOOLBAR_THEME.highlightPink;
export const ANNOTATION_HIGHLIGHT_FILL = 'rgba(239, 255, 61, .3)';
