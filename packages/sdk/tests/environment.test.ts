import { describe, expect, it } from 'vitest';
import { describeEnvironment } from '../src/environment';

describe('describeEnvironment', () => {
  it('reports a bounded browser, platform and viewport', () => {
    expect(
      describeEnvironment({
        userAgent:
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
        width: 1440,
        height: 1000,
      }),
    ).toBe('Chrome 141 · Linux · viewport 1440×1000');
  });

  it('keeps only the browser family and major version from Chromium variants', () => {
    expect(
      describeEnvironment({
        userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
        width: 1280.4,
        height: 720,
      }),
    ).toBe('Edge 141 · macOS · viewport 1280×720');
  });

  it('recognizes Firefox and Safari without exposing the rest of the user agent', () => {
    expect(
      describeEnvironment({
        userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:142.0) Gecko/20100101 Firefox/142.0',
      }),
    ).toBe('Firefox 142 · Windows');
    expect(
      describeEnvironment({
        userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        width: 390,
        height: 844,
      }),
    ).toBe('Safari 18 · iOS · viewport 390×844');
  });

  it('does not invent a browser when the user agent is unknown', () => {
    expect(describeEnvironment({ userAgent: 'custom-agent', width: 800, height: 600 })).toBe(
      'viewport 800×600',
    );
    expect(describeEnvironment({ userAgent: '' })).toBe('Browser environment unavailable');
  });
});
