import type { HighliteManifest, Keyframe, TimelineEvent } from './index';

function formatTime(atMs: number): string {
  const seconds = Math.floor(atMs / 1000);
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}

function markdownText(value: string): string {
  return value.replace(/[\\`*_{}[\]()#+.!|>]/g, '\\$&').replace(/[\r\n]+/g, ' ');
}

function targetDescription(manifest: HighliteManifest, targetId?: string): string | undefined {
  if (!targetId) return undefined;
  const target = manifest.targets.find((candidate) => candidate.id === targetId);
  if (!target) return undefined;
  const label = target.label ?? target.textExcerpt ?? target.selector ?? target.tag ?? target.id;
  return `Target: ${markdownText(label)}${target.metadata?.id ? ` (id: ${markdownText(String(target.metadata.id))})` : ''}`;
}

function frameHeading(manifest: HighliteManifest, frame: Keyframe): string {
  if (frame.reason === 'mark') {
    const event = manifest.timeline
      .filter((candidate) => candidate.kind === 'mark')
      .sort(
        (left, right) => Math.abs(left.atMs - frame.atMs) - Math.abs(right.atMs - frame.atMs),
      )[0];
    if (
      event &&
      Math.abs(event.atMs - frame.atMs) < 1500 &&
      typeof event.payload.label === 'string'
    ) {
      return markdownText(event.payload.label);
    }
  }
  const target = manifest.targets.find((candidate) => candidate.id === frame.targetIds[0]);
  return markdownText(target?.label ?? target?.textExcerpt ?? frame.reason);
}

function eventDescription(manifest: HighliteManifest, event: TimelineEvent): string {
  if (event.kind === 'mark' && typeof event.payload.label === 'string') {
    return `Mark: ${markdownText(event.payload.label)}`;
  }
  if (event.kind === 'context') {
    return `Context: ${markdownText(String(event.payload.scope ?? 'page'))} — ${markdownText(String(event.payload.value ?? ''))}`;
  }
  const target = targetDescription(manifest, event.targetId);
  if (event.kind === 'click') return target ? `Click — ${target.replace('Target: ', '')}` : 'Click';
  if (event.kind === 'scroll') {
    return `Scroll to x=${String(event.payload.x ?? 0)}, y=${String(event.payload.y ?? 0)}`;
  }
  if (event.kind === 'navigate') {
    return `Navigate to ${markdownText(String(event.payload.to ?? 'unknown route'))}`;
  }
  if (event.kind === 'annotation') {
    return `Added ${markdownText(String(event.payload.annotationKind ?? ''))} annotation${target ? ` — ${target.replace('Target: ', '')}` : ''}`;
  }
  return target ? `${event.kind} — ${target.replace('Target: ', '')}` : event.kind;
}

export function buildSummary(manifest: HighliteManifest): string {
  const url = new URL(manifest.page.initialUrl);
  const pathname = markdownText(url.pathname || '/');
  const lines = [
    '# Captured web interaction',
    `Page: ${pathname}${manifest.page.title ? ` — ${markdownText(manifest.page.title)}` : ''}`,
    `Duration: ${formatTime(manifest.durationMs)}`,
    '',
  ];

  if (manifest.keyframes.length > 0) {
    lines.push('## Keyframes', '');
    manifest.keyframes.forEach((frame, index) => {
      lines.push(`### ${formatTime(frame.atMs)} — ${frameHeading(manifest, frame)}`);
      lines.push(`![Frame ${index + 1}](${frame.imagePath})`);
      const target = targetDescription(manifest, frame.targetIds[0]);
      if (target) lines.push(target);
      if (frame.annotationIds.length > 0) {
        lines.push(`Annotation IDs: ${frame.annotationIds.map(markdownText).join(', ')}`);
      }
      lines.push('');
    });
  } else {
    lines.push('Visual evidence: unavailable. No approved frame provider supplied image data.', '');
  }

  lines.push('## Timeline', '');
  for (const event of manifest.timeline) {
    lines.push(`- ${formatTime(event.atMs)} — ${eventDescription(manifest, event)}`);
  }
  if (manifest.timeline.length === 0) lines.push('- No browser interactions were captured.');

  lines.push('', '## Narration', '');
  if (manifest.transcript.length > 0) {
    for (const segment of manifest.transcript) {
      lines.push(`- ${formatTime(segment.startMs)} — “${markdownText(segment.text)}”`);
    }
  } else if (manifest.artifacts.audio) {
    lines.push('Audio is included; transcription has not been configured.');
  } else {
    lines.push('No narration audio was recorded.');
  }

  if (manifest.captureWarnings.length > 0) {
    lines.push('', '## Capture limitations', '');
    for (const warning of manifest.captureWarnings) lines.push(`- ${markdownText(warning)}`);
  }

  return `${lines.join('\n')}\n`;
}
