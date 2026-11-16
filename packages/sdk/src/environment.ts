/**
 * Bounded environment context for a capture. It intentionally reports only a browser
 * family, a coarse platform, and the viewport size: enough to reproduce layout bugs
 * without building a fingerprint from user-agent details, languages or hardware.
 */

export interface EnvironmentInput {
  userAgent: string;
  width?: number;
  height?: number;
}

function browserFamily(userAgent: string): string | undefined {
  const edge = /Edg(?:e|A|iOS)?\/(\d+)/.exec(userAgent);
  if (edge) return `Edge ${edge[1]}`;
  const opera = /OPR\/(\d+)/.exec(userAgent);
  if (opera) return `Opera ${opera[1]}`;
  const chrome = /(?:CriOS|Chrome)\/(\d+)/.exec(userAgent);
  if (chrome) return `Chrome ${chrome[1]}`;
  const firefox = /(?:FxiOS|Firefox)\/(\d+)/.exec(userAgent);
  if (firefox) return `Firefox ${firefox[1]}`;
  const safari = /Version\/(\d+)[\d.]*.*Safari\//.exec(userAgent);
  if (safari) return `Safari ${safari[1]}`;
  return undefined;
}

function platformFamily(userAgent: string): string | undefined {
  if (/Android/i.test(userAgent)) return 'Android';
  if (/iPhone|iPad|iPod/i.test(userAgent)) return 'iOS';
  if (/Windows/i.test(userAgent)) return 'Windows';
  if (/Macintosh|Mac OS X/i.test(userAgent)) return 'macOS';
  if (/Linux/i.test(userAgent)) return 'Linux';
  return undefined;
}

function dimension(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value)) return undefined;
  return Math.max(0, Math.round(value));
}

/** `Chrome 141 · Linux · viewport 1440×1000` */
export function describeEnvironment(input: EnvironmentInput): string {
  const parts: string[] = [];
  const browser = browserFamily(input.userAgent);
  const platform = platformFamily(input.userAgent);
  if (browser) parts.push(browser);
  if (platform) parts.push(platform);
  const width = dimension(input.width);
  const height = dimension(input.height);
  if (width !== undefined && height !== undefined) parts.push(`viewport ${width}×${height}`);
  if (parts.length === 0) return 'Browser environment unavailable';
  return parts.join(' · ');
}
