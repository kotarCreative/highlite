import type { HighliteManifest, Keyframe, TimelineEvent } from './index';

function formatTime(atMs: number): string {
  const seconds = Math.floor(atMs / 1000);
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}

function markdownText(value: string): string {
  return value.replace(/[\\`*_{}[\]()#+.!|>]/g, '\\$&').replace(/[\r\n]+/g, ' ');
}

function targetLabel(manifest: HighliteManifest, targetId?: string): string | undefined {
  if (!targetId) return undefined;
  const target = manifest.targets.find((candidate) => candidate.id === targetId);
  if (!target) return undefined;
  return target.label ?? target.textExcerpt ?? target.selector ?? target.tag ?? target.id;
}

function targetDescription(manifest: HighliteManifest, targetId?: string): string | undefined {
  const label = targetLabel(manifest, targetId);
  return label ? `Target: ${markdownText(label)}` : undefined;
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

function quotedValue(event: TimelineEvent): string | undefined {
  if (event.payload.valueCaptured !== true) return undefined;
  return typeof event.payload.value === 'string' ? markdownText(event.payload.value) : undefined;
}

function eventDescription(manifest: HighliteManifest, event: TimelineEvent): string {
  if (event.kind === 'mark' && typeof event.payload.label === 'string') {
    return `Mark: ${markdownText(event.payload.label)}`;
  }
  if (event.kind === 'context') {
    return `Context: ${markdownText(String(event.payload.scope ?? 'page'))} — ${markdownText(String(event.payload.value ?? ''))}`;
  }
  const label = targetLabel(manifest, event.targetId);
  if (event.kind === 'click') {
    const target = manifest.targets.find((candidate) => candidate.id === event.targetId);
    const role = target?.role ?? 'element';
    return label ? `Clicked ${role} “${markdownText(label)}”` : `Clicked ${role}`;
  }
  if (event.kind === 'scroll') {
    return `Scroll to x=${String(event.payload.x ?? 0)}, y=${String(event.payload.y ?? 0)}`;
  }
  if (event.kind === 'navigate') {
    return `Navigate to ${markdownText(String(event.payload.to ?? 'unknown route'))}`;
  }
  if (event.kind === 'annotation') {
    return `Added ${markdownText(String(event.payload.annotationKind ?? ''))} annotation${label ? ` — ${markdownText(label)}` : ''}`;
  }
  if (event.kind === 'input') {
    const name = label ? ` — ${markdownText(label)}` : '';
    if (event.payload.filled === false) return `Cleared field${name}`;
    const value = quotedValue(event);
    return value !== undefined
      ? `Entered “${value}” in field${name}`
      : `Entered text in field${name}`;
  }
  if (event.kind === 'change') {
    if (event.payload.fieldKind === 'checkbox' || event.payload.fieldKind === 'radio') {
      const action = event.payload.checked === true ? 'Checked' : 'Unchecked';
      return label ? `${action} “${markdownText(label)}”` : action;
    }
    const field = label ? ` in ${markdownText(label)}` : '';
    if (event.payload.valueCaptured === true && Array.isArray(event.payload.optionLabels)) {
      const options = event.payload.optionLabels
        .filter((option): option is string => typeof option === 'string' && option.length > 0)
        .map((option) => `“${markdownText(option)}”`);
      if (options.length > 0) return `Selected ${options.join(', ')}${field}`;
      return label ? `Cleared selection in ${markdownText(label)}` : 'Cleared selection';
    }
    const option =
      event.payload.valueCaptured === true && typeof event.payload.optionLabel === 'string'
        ? markdownText(event.payload.optionLabel)
        : undefined;
    if (option !== undefined) return `Selected “${option}”${field}`;
    return label ? `Changed selection — ${markdownText(label)}` : 'Changed selection';
  }
  if (event.kind === 'submit') {
    const form = label ? `form “${markdownText(label)}”` : 'form';
    const submitter =
      typeof event.payload.submitterLabel === 'string'
        ? ` via “${markdownText(event.payload.submitterLabel)}”`
        : '';
    return `Submitted ${form}${submitter}`;
  }
  return label ? `${event.kind} — ${markdownText(label)}` : event.kind;
}

function isEnvironmentEvent(event: TimelineEvent): boolean {
  return (
    event.kind === 'context' &&
    (event.payload.scope === 'environment' ||
      event.payload.scope === 'app' ||
      event.payload.scope === 'app.version')
  );
}

export function buildSummary(manifest: HighliteManifest): string {
  const url = new URL(manifest.page.initialUrl);
  const pathname = markdownText(url.pathname || '/');
  const lines = [
    '# Captured web interaction',
    `Page: ${pathname}${manifest.page.title ? ` — ${markdownText(manifest.page.title)}` : ''}`,
    `Duration: ${formatTime(manifest.durationMs)}`,
  ];

  if (manifest.artifacts.video) {
    const name =
      manifest.artifacts.video.split(/[\\/]/).filter(Boolean).pop() ?? manifest.artifacts.video;
    lines.push(`Video: ${name.replace(/[\r\n]+/g, ' ')}`);
  }

  const environment = manifest.timeline.filter(isEnvironmentEvent);
  if (environment.length > 0) {
    lines.push(
      `Environment: ${environment
        .map((event) => markdownText(String(event.payload.value ?? '')))
        .filter(Boolean)
        .join(' · ')}`,
    );
  }
  lines.push('');

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

  const actions = manifest.timeline.filter(
    (event) => event.kind !== 'target' && !isEnvironmentEvent(event),
  );
  lines.push('## Timeline', '');
  for (const event of actions) {
    lines.push(`- ${formatTime(event.atMs)} — ${eventDescription(manifest, event)}`);
  }
  if (actions.length === 0) lines.push('- No browser interactions were captured.');

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
