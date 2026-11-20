# Native macOS menu bar app

`apps/macos` is a Swift Package Manager app that supervises a local Highlite relay and
opens the relay's dashboard. It is a native loopback client, not a replacement for the
relay or the browser SDK. SwiftUI/AppKit live in the executable target; Foundation,
Security, and relay logic live in `HighliteMenuBarCore` so they can be tested without a
window server.

## Requirements

- macOS 14 or newer on Apple silicon or Intel.
- macOS 15 SDK (Xcode 16 or newer) to compile the recorder.
- Xcode command line tools / Swift 5.9 or newer.
- A Rust toolchain with Cargo.
- The repository's existing development prerequisites for the relay.

The app builds for the **native host architecture only**. It is not a universal binary.

## Build, run, and verify

```sh
pnpm build:macos
pnpm verify:macos
open dist/Highlite.app
```

Compiling the macOS 15 screen-recorder APIs needs the macOS 15 SDK (Xcode 16 or newer);
the built app still launches on macOS 14, where recording is disabled. `pnpm build:macos`
builds `highlite-relay` in release mode, builds the `HighliteMenuBar` product in release
mode, and assembles:

```text
dist/Highlite.app/
  Contents/
    Info.plist
    MacOS/HighliteMenuBar
    Resources/
      AppIcon.icns
      highlite-relay
```

It assembles a temporary sibling bundle, clears extended attributes, lints the plist,
checks the declared executable, and verifies that both binaries match the native host
architecture. It signs the relay sidecar explicitly first, verifies it, then signs and
verifies the app; it does not rely on `--deep` to discover nested code. Only after those
checks does it swap the new bundle into `dist/Highlite.app`, keeping the previous bundle
as a backup and restoring it if the final verification fails.

The signatures are **ad-hoc** and the app is **not notarized**. There is no Developer ID
signature, so Gatekeeper may require an explicit Open on first launch. Developer ID
signing and notarization are follow-up work.

`pnpm verify:macos` builds and tests the Swift package, rebuilds the bundle, lints the
plist with `plutil`, checks `CFBundleExecutable`, requires executable main and sidecar
files, verifies `lipo` architectures match the native host and each other, and verifies
the sidecar and app signatures explicitly.

On Linux, `pnpm verify:macos` performs static package checks only: required files,
product/target names, plist values, and the absence of focused-window APIs. **A Linux
pass is not proof that the app compiles or that Keychain, signing, or relay supervision
work.** Run the script on macOS before shipping.

## Relay lifecycle

The app starts its own relay and can attach to an existing one only after the stored read
token validates. Otherwise it reports a port/token conflict instead of taking over.

Relay lookup order:

1. `HIGHLITE_RELAY_BIN`
2. bundled `Contents/Resources/highlite-relay`
3. development `target/release/highlite-relay`

The app generates 32-byte hex read and ingest tokens on first run. It writes:

```text
~/Library/Application Support/Highlite/
  relay.env                 # mode 0600
  config/                   # mode 0700, relay provider/Jira configuration
  data/                     # compiled sessions and recipe runs
```

Startup uses `--env-file`, `--bind 127.0.0.1:<port>`, `--data-dir`, and `--config-dir`.
It does not pass `--ui`, because the dashboard is part of the app's client flow. The
initial relay environment allowlists the local demo development origin for browser
ingest:

```sh
HIGHLITE_RELAY_ALLOWED_HOSTS=127.0.0.1:<port>
HIGHLITE_RELAY_ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173
```

Vite's default development origin is `http://localhost:5173`. Add the exact scheme,
host, and port of any other browser host that uploads captures. Prefer HTTPS for
non-local origins.

The Overview **Site embed** card copies a script-tag snippet with the active relay
ingest endpoint and token. Enter the site's SDK asset path (the default is
`/assets/highlite.iife.js`) and serve `packages/sdk/dist/highlite.iife.js` from that
path before pasting the snippet.

The child environment omits `HIGHLITE_RELAY_*` and `HIGHLITE_CONFIG_DIR`, and augments
`PATH` with common OpenCode locations. Relay logs are bounded and never include tokens
or request bodies. An owned relay is stopped with **SIGINT**, matching the relay's
`ctrl_c` handler. The app never kills a relay it did not start.

## Credentials and storage

- **Read and ingest relay tokens:** macOS Keychain is the app's token store. The active
  values are also written into the relay env file because the child process needs them;
  they are not stored in UserDefaults or other app preferences.
- **Relay env file:** mode `0600`; configuration directory mode `0700`.
- **AI provider credentials:** the relay's existing private plaintext
  `<config-dir>/providers.json`. The app can edit them through the relay API but does
  not read the file directly and does not claim Keychain protection for these keys.
- **Jira credentials:** the relay's existing private plaintext
  `<config-dir>/jira-recipe.json`. Same caveat.
- **OpenCode authentication:** managed by the OpenCode CLI. The app and relay store no
  OpenCode token.

Provider saves are labelled **Saved, not verified**. Blank API-key fields are omitted
rather than sent as empty strings. Jira token fields follow the same rule. Back up and
protect the relay config and data directories; they can contain compiled capture text
and generated drafts.

## UI

The dashboard opens on launch at roughly 1040×760 content size. Closing it keeps the app
in the menu bar without a Dock icon. Opening the app again (including
`open dist/Highlite.app`) restores and focuses the dashboard at a usable size, even if it
was closed or minimized.

The sidebar and detail enforce one shared minimum: 180pt sidebar + 780pt detail + the
split-view divider. The window's minimum content size includes that divider so resizing
cannot clip either column. The **Sessions** list and detail panes fill the remaining
height and scroll independently. The sidebar is fixed and visible; the dashboard removes
the default toolbar hide/show control.

The app installs the standard Edit menu so **Cmd+V**, **Cmd+C**, **Cmd+X**, and
**Cmd+A** reach the focused text field. API-key fields accept paste while remaining
masked; copying or cutting secrets remains subject to macOS secure-field restrictions.

The menu bar uses the highlighter symbol and shows relay status, a pending-suggestion
badge, and actions to open the dashboard, capture a still, record the screen, start or
stop the relay, and quit. While recording, it shows a red **● REC** indicator and
**Stop Recording** in the same status menu.

The app bundle carries a matching highlighter icon. `Resources/AppIcon.svg` is the
vector source, `Resources/AppIcon.icns` is the generated multi-resolution Mac icon, and
`pnpm generate:macos-icon` (or `scripts/generate-macos-app-icon.py`) regenerates the ICNS after vector changes. The
packaging script copies it to `Contents/Resources/AppIcon.icns`, and `Info.plist`
declares it as `CFBundleIconFile`. Normal builds use the committed ICNS; only changing
the icon artwork requires `rsvg-convert` or ImageMagick.

Page titles use a translucent yellow marker stroke behind ink text. The marker opacity
stays low enough that Dark Aqua's light ink remains readable, while active tools and
primary actions keep the full-strength highlighter yellow.

The dashboard covers:

- **Overview** and recent activity.
- **Sessions** with compiled bundle access.
- **Providers** — add, edit, make default, disconnect.
- **Jira recipe** — connection test, project/issue-type selection, prompt, publish mode,
  separate AI-image and Jira-attachment opt-ins, selected attachment review, and extra
  fields JSON.
- **OpenCode recipe** — required directory, discovery version and eligible sessions,
  prompt, auto-draft, and enable/save.
- **Settings** — relay and local path settings, plus narration setup status,
  download progress, retry, and installed-license notices.

The narration card shows waiting/checking, downloading or verifying with byte
progress, **Ready** with the installed model path, **Preserved relay.env
configuration** when `relay.env` already defines a transcriber command or
Parakeet paths outside the app's directory, and a failed state with a bounded
retry. The preserved state is not a readiness claim: the app skips and does not
verify those settings, so narration depends on the named commands and files.

Session detail exposes Jira draft/edit/publish, attachment selection and per-file upload
results, and OpenCode suggestion/override/confirm.
The interface explains that OpenCode routing is metadata-only and never auto-submits.

### Native still capture

**Capture Screen…** in the menu bar starts the macOS interactive capture UI
(`/usr/sbin/screencapture -i -x -t png`). The user drags a region or presses Space to
choose a window; there is no background screen monitoring, focused-window query, or
Accessibility dependency. Screen Recording permission is managed by macOS in
**System Settings → Privacy & Security → Screen Recording**.

The review window previews the PNG and offers the browser SDK's full annotation set:
freehand, circle, arrow, and highlight. Draw any number of annotations directly on the
image, switch tools between strokes, and use **Undo** or **Clear** to revise them. A
short note is required. Saving builds a two-entry ZIP (`manifest.json` and `capture.png`)
and sends it to the local relay's existing `POST /v1/sessions` ingest endpoint with the
stored ingest token. The relay then compiles it through the same manifest/keyframe
pipeline as a browser capture. The app deletes its temporary screenshot after uploading;
the still path does not embed a website, record microphone audio, read the page DOM, or
call Jira/OpenCode/provider APIs itself.

The note becomes the session title and the target label used by the compiled summary.
The relay sees the unflattened screenshot plus the normalized annotations, so the
canonical compiler remains the only annotation renderer. All annotations are attached to
the single still keyframe in draw order and are burned into it together, matching the
browser capture contract.

### Native screen recording (macOS 15+)

On macOS 15 or newer, **Record Screen…** opens an explicit setup window; on macOS 14 the
item is disabled and still capture remains available. The microphone switch is off by
default; turning it on is the only way Highlite requests microphone audio, and
`NSMicrophoneUsageDescription` explains that use to macOS. System audio is never
captured. **Choose Window or Display…** opens the macOS 15 system content picker and
limits the recording to one chosen window or display.

Stopping finalizes an MP4 and opens a native review window. The recorder also stops itself
at its 45-second or 48-MiB budget and opens the same review. The window plays the movie
with AVKit, shows the still poster for an optional highlight rectangle, requires a note,
and uploads only after **Save to Highlite**. The ZIP is additive to the still contract:

```text
manifest.json       durationMs, poster keyframe, target, optional annotation
poster.png          still poster used as the keyframe image
recording.mp4       full movie
recording.m4a       only when microphone audio was enabled
```

The manifest identifies the media as `artifacts.video = "recording.mp4"` and optional
`artifacts.audio`. A poster highlight is stored as a normalized annotation and burned
into the compiled keyframe, matching the still-capture pipeline. The app does not launch
a downstream Jira, OpenCode, or provider action; configured relay recipes react to the
ingested session as they do for any capture.

One screen flow is active at a time. The still-capture picker and review, recording
setup, active recording, and recording review are mutually exclusive. Saving failure
retains the review and temporary files for a retry; cancel, dismiss, or successful save
stops playback and deletes the temporary recording directory. Launch is treated as the
single-instance boundary: every leftover app-prefixed `HighliteRecording-*` directory is
removed before recording can start. Run only one Highlite instance at a time.

The native recording approach is inspired by Kit Langton's Scrawl at pinned revision
[`b5fa0705f6e5724ede414727797b4b6ed274d3d2`](https://github.com/kitlangton/scrawl/tree/b5fa0705f6e5724ede414727797b4b6ed274d3d2).
No Scrawl code is copied, and Highlite makes no claim of compatibility with Scrawl's
schema, bundle format, or processing interfaces; the `0.1.0` Highlite manifest and ZIP
contract remain authoritative.

## Pending suggestions

The app polls activity (or recipe runs) for new OpenCode `suggested` runs and deduplicates
by `sessionId + revision + updatedAtMs`. If the dashboard is open it selects the session
and shows the review sheet; otherwise it activates the app and opens the real dashboard
with the pending details.

**Defer** leaves the run `suggested`; it remains in the relay and the badge stays. The
confirmation sheet shows the target title, exact directory, and the stored
`promptPreview`. Nothing is submitted without that confirmation. There is no
focused-window detection: an unrelated OpenCode session in another window never becomes
the target.

## Package layout

```text
apps/macos/
  Package.swift
  Resources/
    Info.plist
    AppIcon.svg
    AppIcon.icns
  Sources/
    HighliteMenuBarCore/
      RelayModels.swift
      RelayClient.swift
      RelayProcessController.swift
      RelayEnvironment.swift
      KeychainStore.swift
      OpenCodeLocator.swift
      AppSettings.swift
      JSONValue.swift
      NativeCaptureAnnotation.swift
      NativeCaptureBundle.swift
      NativeCaptureCommand.swift
      NativeRecordingBundle.swift
      NativeRecordingTempStore.swift
    HighliteMenuBar/
      HighliteMenuBarApp.swift
      AppDelegate.swift
      AppModel.swift
      NativeCaptureDraft.swift
      NativeCaptureService.swift
      NativeRecordingController.swift
      NativeRecordingDraft.swift
      Views/
        AnnotationCanvas.swift
        CaptureReviewView.swift
        RecordingReviewView.swift
        RecordingSetupView.swift
  Tests/HighliteMenuBarCoreTests/
  README.md
```

`Package.swift` uses Swift tools 5.9, `.macOS(.v14)`, and the executable product
`HighliteMenuBar`. The bundle identifier is `com.highlite.menubar`, it is an agent app
(`LSUIElement`), local networking is allowed for loopback relay traffic, and
`NSMicrophoneUsageDescription` explains the opt-in microphone recording. The app keeps
its macOS 14 floor: macOS 15 ScreenCaptureKit recorder types are guarded with
`@available(macOS 15, *)`, and the Record Screen item is disabled on macOS 14.

## Manual verification

After launching from `dist/Highlite.app`:

1. The dashboard opens at roughly 1040×760 content size, centered, with a non-empty
   content area (not a title-bar-only window), and the relay starts with a reachable
   status indicator. Select **Sessions** with at least one capture and confirm the
   session list and detail panes fill the window height and scroll independently. Shrink
   the window to its minimum and confirm the sidebar and detail still fit without
   horizontal clipping. Close the dashboard and run `open dist/Highlite.app` again; it
   should reopen at a usable size without starting another app or relay. Minimize it and
   repeat; it should restore and focus.
2. Tokens exist only in Keychain, `relay.env` is `0600`, and the config directory is
   `0700`.
3. Provider and Jira setup can be saved and reports **Saved, not verified** where
   applicable.
   Paste a dummy key into each API-key field with **Cmd+V** (do not save it); it
   should remain masked. Check **Cmd+A** and replacement paste, and verify that
   copy/paste still works in ordinary text fields. Repeat in the provider editor sheet.
4. Configure the OpenCode directory, run discovery, and confirm the version and eligible
   sessions.
5. Capture a session and let the recipe create a pending suggestion.
6. Confirm that an unrelated OpenCode session in another window does not become the
   target and nothing is sent before confirmation. Confirm the confirmation window opens
   at roughly 820×700, and that it keeps a usable size when a later suggestion reuses the
   same window.
7. Confirm the chosen session receives exactly the previewed prompt.
8. Defer a suggestion, restart the app, and confirm the pending run persists.
9. Inspect `/v1/activity` and confirm no prompt text, drafts, capture summaries, or
   credentials appear.
10. Choose **Capture Screen…**, grant Screen Recording if macOS asks, capture a region,
    draw a freehand stroke, a circle, an arrow, and a highlight (using Undo and Clear at
    least once), enter a note, and save. Confirm the new session appears in Sessions with
    the note as its title, and that a bundle downloads with one keyframe containing all
    four annotation kinds. Cancel a second capture from the system UI and confirm no
    session is created.
11. Choose **Record Screen…**. Confirm microphone audio is off by default. Pick one
    window or display from the system picker and confirm the menu bar shows **● REC**
    and **Stop Recording**. Stop, play the movie in the review window, mark the poster,
    enter a note, and save. Confirm the new session and a bundle whose manifest names
    `recording.mp4` and whose ZIP contains the movie, poster, and manifest. Repeat with
    the microphone switch on and confirm macOS asks for permission and the ZIP adds
    `recording.m4a`. Confirm there is no system-audio track.
12. With a recording active, confirm **Capture Screen…** and **Record Screen…** cannot
    start a second flow. Cancel a recording review and confirm the temporary
    `HighliteRecording-*` directory is gone. Force-quit during a recording, relaunch,
    and confirm an older app-prefixed temporary directory is swept while a fresh one is
    left alone.
13. Quit the app and confirm the owned relay stops gracefully.

## Limitations

- macOS 14+; ad-hoc signed and not notarized.
- Screen recording requires macOS 15+ and the macOS 15 SDK. Still capture remains
  available on macOS 14.
- No sandbox/App Store packaging in this slice.
- Native still capture has no microphone, DOM, browser embed, or background monitoring.
  Native recording captures one window or display and an optional microphone track; it
  never records system audio, DOM, or other windows, and only one screen flow can run at
  a time. Relay-side tests cover copying the referenced video and audio artifacts into
  the compiled bundle.
- Existing OpenCode sessions only; no creation of new sessions.
- No exactly-once OpenCode delivery. Ambiguous submissions become `submit-unknown` and
  must be checked manually.
- The web relay UI stays Jira-only; OpenCode configuration lives in the native app.
