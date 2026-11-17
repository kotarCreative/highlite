import { describe, expect, it } from 'vitest';
import {
  ANNOTATION_HIGHLIGHT_FILL,
  ANNOTATION_STROKE,
  ANNOTATION_STROKE_DARK,
  TOOLBAR_DARK_THEME,
  TOOLBAR_THEME,
} from '../src/theme';

/**
 * Expected light values from `crates/highlite-relay/src/ui-theme.css`. Keeping
 * them explicit here fails the build if the recorder drifts to a separate
 * accent or a low-contrast surface.
 */
const RELAY_PALETTE = {
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
  highlightPink: '#ff81bd',
  actionHover: '#e0ef2a',
  actionInk: '#30232d',
  success: '#087443',
  danger: '#b4232d',
  warning: '#9a5700',
} as const;

function luminance(hex: string): number {
  const channels = [1, 3, 5]
    .map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16) / 255)
    .map((value) => (value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4));
  return 0.2126 * channels[0]! + 0.7152 * channels[1]! + 0.0722 * channels[2]!;
}

function contrast(foreground: string, background: string): number {
  const lighter = Math.max(luminance(foreground), luminance(background));
  const darker = Math.min(luminance(foreground), luminance(background));
  return (lighter + 0.05) / (darker + 0.05);
}

describe('recorder theme', () => {
  it('shares the relay highlighter palette instead of a separate accent color', () => {
    for (const [name, value] of Object.entries(RELAY_PALETTE)) {
      expect(TOOLBAR_THEME[name as keyof typeof RELAY_PALETTE]).toBe(value);
    }
    expect(TOOLBAR_THEME.action).toBe(TOOLBAR_THEME.highlightYellow);
    expect(TOOLBAR_THEME.dockInk).toBe(TOOLBAR_THEME.ink);
  });

  it('keeps marker colors paired with dark ink and status colors readable', () => {
    expect(contrast(TOOLBAR_THEME.ink, TOOLBAR_THEME.canvas)).toBeGreaterThan(12);
    expect(contrast(TOOLBAR_THEME.actionInk, TOOLBAR_THEME.action)).toBeGreaterThan(12);
    expect(contrast(TOOLBAR_THEME.actionInk, TOOLBAR_THEME.highlightOrange)).toBeGreaterThan(7);
    expect(contrast(TOOLBAR_THEME.actionInk, TOOLBAR_THEME.highlightPink)).toBeGreaterThan(6);
    expect(contrast(TOOLBAR_THEME.dangerInk, TOOLBAR_THEME.dangerSurface)).toBeGreaterThan(6);
  });

  it('keeps the dark appearance legible without recoloring the brand dock', () => {
    expect(TOOLBAR_DARK_THEME.canvas).not.toBe(TOOLBAR_THEME.canvas);
    expect(contrast(TOOLBAR_DARK_THEME.ink!, TOOLBAR_DARK_THEME.canvas!)).toBeGreaterThan(12);
    expect(contrast(TOOLBAR_DARK_THEME.primary!, TOOLBAR_DARK_THEME.surface!)).toBeGreaterThan(6);
    expect(contrast(TOOLBAR_DARK_THEME.muted!, TOOLBAR_DARK_THEME.surface!)).toBeGreaterThan(6);
    expect(contrast(TOOLBAR_DARK_THEME.success!, TOOLBAR_DARK_THEME.surface!)).toBeGreaterThan(6);
    expect(contrast(TOOLBAR_DARK_THEME.warning!, TOOLBAR_DARK_THEME.surface!)).toBeGreaterThan(6);
    expect(contrast(TOOLBAR_DARK_THEME.danger!, TOOLBAR_DARK_THEME.surface!)).toBeGreaterThan(5);
    expect(contrast(TOOLBAR_THEME.dockText, TOOLBAR_THEME.dockInk)).toBeGreaterThan(12);
  });

  it('draws annotations with brand ink and a readable yellow highlight wash', () => {
    expect(ANNOTATION_STROKE).toBe(TOOLBAR_THEME.primary);
    expect(ANNOTATION_STROKE_DARK).toBe(TOOLBAR_THEME.highlightPink);
    expect(ANNOTATION_HIGHLIGHT_FILL).toBe('rgba(239, 255, 61, .3)');
  });
});
