import { createHighlite } from '@highlite/sdk';
import './style.css';

const retentionValue = document.querySelector<HTMLElement>('#retention-value');
const dateRange = document.querySelector<HTMLSelectElement>('#date-range');
const rangeCaption = document.querySelector<HTMLElement>('#range-caption');
const previewEmpty = document.querySelector<HTMLElement>('#preview-empty');
const previewResult = document.querySelector<HTMLElement>('#preview-result');
const summaryPreview = document.querySelector<HTMLElement>('#summary-preview');
const manifestPreview = document.querySelector<HTMLElement>('#manifest-preview');
const frameCount = document.querySelector<HTMLElement>('#frame-count');
const eventCount = document.querySelector<HTMLElement>('#event-count');
const audioStatus = document.querySelector<HTMLElement>('#audio-status');
const frameList = document.querySelector<HTMLElement>('#frame-list');

const retentionByRange: Record<string, { value: string; change: string; caption: string }> = {
  '7': { value: '108%', change: '2.1%', caption: 'Daily revenue · Last 7 days' },
  '30': { value: '112%', change: '4.8%', caption: 'Daily revenue · Last 30 days' },
  '90': { value: '116%', change: '7.3%', caption: 'Daily revenue · Last 90 days' },
};

dateRange?.addEventListener('change', () => {
  const range = retentionByRange[dateRange.value] ?? retentionByRange['30']!;
  if (retentionValue) retentionValue.textContent = range.value;
  if (rangeCaption) rangeCaption.textContent = range.caption;
  const metric = document.querySelector<HTMLElement>('.metric-card.featured');
  metric?.setAttribute('aria-label', `Net retention, ${range.value}, up ${range.change}`);
});

document.querySelector('.metric-card.featured')?.addEventListener('click', () => {
  const current = document.querySelector<HTMLElement>('.metric-card.featured');
  if (!current) return;
  const detail = current.querySelector('.metric-detail');
  if (detail) {
    detail.remove();
    return;
  }
  const note = document.createElement('span');
  note.className = 'metric-detail';
  note.textContent = 'Recurring revenue retained from existing customers, including expansion.';
  current.append(note);
});

const highlite = createHighlite({
  ui: 'floating',
  capture: {
    microphone: true,
    frames: 'prompt',
    interactions: true,
  },
  privacy: {
    redactSelectors: ['[data-private]', '[data-highlite-private]', 'input[type="password"]'],
    disableSelectors: ['[data-highlite-ignore]'],
  },
  onComplete: (bundle) => {
    if (previewEmpty) previewEmpty.hidden = true;
    if (previewResult) previewResult.hidden = false;
    if (summaryPreview) summaryPreview.textContent = bundle.summary;
    if (manifestPreview) manifestPreview.textContent = JSON.stringify(bundle.manifest, null, 2);
    if (frameCount) frameCount.textContent = `${bundle.manifest.keyframes.length} frames`;
    if (eventCount) eventCount.textContent = `${bundle.manifest.timeline.length} events`;
    if (audioStatus)
      audioStatus.textContent = bundle.manifest.artifacts.audio ? 'Audio included' : 'No audio';
    if (frameList) {
      frameList.replaceChildren();
      for (const frame of bundle.manifest.keyframes) {
        const image = bundle.files[frame.imagePath];
        if (!image) continue;
        const figure = document.createElement('figure');
        const thumbnail = document.createElement('img');
        thumbnail.alt = `Captured keyframe at ${Math.round(frame.atMs / 1000)} seconds`;
        thumbnail.src = URL.createObjectURL(image);
        const caption = document.createElement('figcaption');
        caption.textContent = `${frame.reason} · ${Math.round(frame.atMs / 1000)}s`;
        figure.append(thumbnail, caption);
        frameList.append(figure);
      }
    }
  },
});

highlite.registerTarget('[data-context-id="net-retention"]', {
  id: 'metric.net-retention',
  docsId: 'analytics.net-retention',
});
highlite.registerTarget('[data-context-id="date-range"]', {
  id: 'filter.date-range',
  docsId: 'analytics.date-range',
});

highlite.on('recording-started', ({ microphone }) => {
  if (microphone === 'active') document.documentElement.dataset.highliteMic = 'active';
});

window.addEventListener('pagehide', () => {
  void highlite.destroy();
});
