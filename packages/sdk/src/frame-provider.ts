import type { FrameProvider } from '@highlite/core';

interface CurrentTabDisplayOptions extends DisplayMediaStreamOptions {
  /** Chromium-only: preselect the tab that is asking instead of the last shared surface. */
  preferCurrentTab?: boolean;
  /** Chromium-only: allow the current tab to appear in the picker (excluded by default). */
  selfBrowserSurface?: 'include' | 'exclude';
  /** Chromium-only: hide the "switch surface" control for the lifetime of the share. */
  surfaceSwitching?: 'include' | 'exclude';
  /** Chromium-only: keep entire monitors out of the picker. */
  monitorTypeSurfaces?: 'include' | 'exclude';
  /** Standard but missing from some TypeScript DOM libs. */
  systemAudio?: 'include' | 'exclude';
}

export class DisplayMediaFrameProvider implements FrameProvider {
  #stream: MediaStream | undefined;
  #video: HTMLVideoElement | undefined;
  #endedHandler: (() => void) | undefined;

  async start(): Promise<void> {
    const getDisplayMedia = navigator.mediaDevices?.getDisplayMedia?.bind(navigator.mediaDevices);
    if (!getDisplayMedia) {
      throw new Error('Screen sharing is not supported by this browser.');
    }

    const options: CurrentTabDisplayOptions = {
      video: { frameRate: { ideal: 2, max: 5 }, displaySurface: 'browser' },
      audio: false,
      // The picker cannot be skipped, but these hints make the current tab the
      // preselected surface instead of asking the user to hunt for it.
      preferCurrentTab: true,
      selfBrowserSurface: 'include',
      surfaceSwitching: 'exclude',
      monitorTypeSurfaces: 'exclude',
      systemAudio: 'exclude',
    };
    this.#stream = await getDisplayMedia(options);
    for (const track of this.#stream.getVideoTracks()) {
      track.addEventListener('ended', () => this.#endedHandler?.(), { once: true });
    }

    this.#video = document.createElement('video');
    this.#video.muted = true;
    this.#video.playsInline = true;
    this.#video.srcObject = this.#stream;
    await this.#video.play();
  }

  async capture(_atMs: number): Promise<Blob | null> {
    const video = this.#video;
    if (!video || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA) return null;

    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    if (canvas.width === 0 || canvas.height === 0) return null;

    const context = canvas.getContext('2d');
    if (!context) return null;
    context.drawImage(video, 0, 0, canvas.width, canvas.height);

    return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
  }

  onEnded(handler: () => void): () => void {
    this.#endedHandler = handler;
    return () => {
      if (this.#endedHandler === handler) this.#endedHandler = undefined;
    };
  }

  async stop(): Promise<void> {
    this.#video?.pause();
    if (this.#video) this.#video.srcObject = null;
    this.#video = undefined;
    for (const track of this.#stream?.getTracks() ?? []) track.stop();
    this.#stream = undefined;
  }
}
