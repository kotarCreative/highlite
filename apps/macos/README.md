# HighliteMenuBar

Native macOS 14 menu bar wrapper for the Highlite capture relay. It supervises a
loopback relay, exposes the session dashboard, configures Jira and OpenCode
recipes, and presents a mandatory native review window before any OpenCode
prompt is sent.

The app is a Swift Package Manager executable (`HighliteMenuBar`) plus a small
Foundation/Security core (`HighliteMenuBarCore`) that is testable without
SwiftUI. It does not generate an Xcode project.

## Requirements

- macOS 14 or newer
- Swift 5.9+ / Xcode Command Line Tools
- Rust toolchain for building `highlite-relay`
- A local `opencode` v2 CLI for OpenCode recipe work

## Build and test

From the repository root:

```sh
cargo build --release -p highlite-relay
swift build --package-path apps/macos -c release --product HighliteMenuBar
swift test --package-path apps/macos
bash scripts/build-macos-app.sh
```

The packaging script assembles `dist/Highlite.app`, copies the relay to
`Contents/Resources/highlite-relay`, lints the plist, and applies an ad-hoc
signature. Verify with:

```sh
bash scripts/verify-macos-app.sh
plutil -lint dist/Highlite.app/Contents/Info.plist
codesign --verify --deep --strict dist/Highlite.app
open dist/Highlite.app
```

On Linux, `scripts/verify-macos-app.sh` performs static structure and safety
checks only. It cannot compile Swift, exercise Keychain, or prove the app bundle
runs.

## First launch and relay lifecycle

Launching the app opens the dashboard and adds a sparkles icon to the menu bar.
Closing the dashboard leaves the app and relay running. Open the app again
(including with `open dist/Highlite.app`) or choose **Open Dashboard** from the
menu bar to bring the dashboard back, including when it is minimized.

The app resolves the relay binary in this order:

1. The binary path in Settings
2. `HIGHLITE_RELAY_BIN`
3. `Contents/Resources/highlite-relay` in the app bundle
4. A development `target/release/highlite-relay` above the working directory

Relay state lives under `~/Library/Application Support/Highlite/`:

```text
relay.env        mode 0600, token, origin, and narration configuration
config/          mode 0700, relay provider and Jira private files
data/            compiled captures and recipe runs
transcription/   mode 0700, app-managed Parakeet engine, model, and decoder
```

On first start the app generates 32-byte hex read and ingest tokens, stores them
in Keychain (`com.highlite.menubar.relay`), and mirrors them into `relay.env` for
the relay process. Valid existing token lines (including comma-separated token
lists), unrelated env settings, and existing provider/Jira files are preserved.
Invalid or oversize token values are replaced with the selected valid token so
the app and relay cannot remain permanently mismatched. The env file is written
through a mode-0600 temporary file in the same directory and atomically renamed;
symlink destinations are rejected.

### Narration provisioning

On first launch the app provisions local Parakeet narration when no custom
transcriber is configured. It downloads in the background while the dashboard
and relay remain usable:

- `parakeet-cli` v0.6.1 (MIT), using the Metal arm64 archive on Apple silicon or
  the CPU x86_64 archive on Intel;
- the English NVIDIA Parakeet TDT-CTC 110M Q8_0 GGUF from a pinned
  `mudler/parakeet-cpp-gguf` revision (CC-BY-4.0); and
- FFmpeg 7.1 universal2 from the pinned `EricEngineering/ffmpeg-macos-lgpl`
  release (LGPL v2.1+, no GPL or nonfree components). The decoder handles
  WebM/Opus, Ogg, and MP4/AAC recordings.

Every download is checked against a pinned SHA-256 before use. Archives are
unpacked into a private staging directory, verified, and only then activated
with an atomic `transcription/current` link. The complete engine directory is
preserved, including any `.dylib` files shipped with future engine releases. The
re-downloadable `transcription/` directory is excluded from Time Machine backups.
A failed download, checksum, or validation leaves the previous installation and
`relay.env` untouched; the Settings panel offers a bounded retry.

```text
transcription/
  current -> installations/<install-id>
  installations/<install-id>/
    engine/<engine-root>/   parakeet-cli, parakeet-server, LICENSE
    model/                  tdt_ctc-110m-q8_0.gguf
    decoder/                ffmpeg and ffprobe
    licenses/               NOTICE.txt, LICENSE-MIT-parakeet.cpp.txt,
                            LICENSE-LGPL-2.1.txt, LICENSE-CC-BY-4.0.txt
    installation.json       pinned hashes and install metadata
```

`<engine-root>` is the directory the release archive already contains; it is
`parakeet-v0.6.1-bin-macos-metal-arm64` on Apple silicon and
`parakeet-v0.6.1-bin-macos-cpu-x64` on Intel. The archive is not flattened, so
`parakeet-cli` lives inside that directory rather than directly under `engine/`.

After a successful install the app writes these keys into `relay.env`:

```dotenv
HIGHLITE_RELAY_PARAKEET_BIN=.../transcription/current/engine/<engine-root>/parakeet-cli
HIGHLITE_RELAY_PARAKEET_MODEL=.../transcription/current/model/tdt_ctc-110m-q8_0.gguf
HIGHLITE_RELAY_FFMPEG=.../transcription/current/decoder/ffmpeg
```

The application support path contains a space, so the app writes these values
quoted; the relay accepts quoted env-file paths with spaces.

Existing configuration wins:

- A non-empty `HIGHLITE_RELAY_TRANSCRIBER_COMMAND` or `HIGHLITE_ASR_COMMAND`
  disables automatic provisioning. The app does not overwrite it.
- Parakeet paths already set outside the app's `transcription/` directory are
  preserved and disable automatic provisioning.
- A custom `HIGHLITE_RELAY_FFMPEG` is preserved; the app still writes the
  Parakeet engine and model keys.
- Unrelated `relay.env` lines, comments, tokens, origins, and provider/Jira files
  are preserved.

Highlite does not verify preserved settings. A preserved transcriber command is
run by the relay exactly as written. Preserved Parakeet paths are passed to the
relay as-is; incomplete or missing files produce a narration warning on the
capture instead of blocking the upload. A broken explicit transcriber command
still fails that upload. The Settings panel therefore labels this state
**Preserved relay.env configuration**, not ready.

Only the relay process that the app owns is restarted after configuration. An
attached external relay is never stopped or signalled; restart it yourself to
load the new environment. If narration is still downloading when a capture is
uploaded, the relay keeps the audio and records a warning that narration was not
transcribed.

To force a fresh install, quit the app, remove
`~/Library/Application Support/Highlite/transcription`, and launch again. A
restart with a valid installation does not re-download; it checks the install
metadata, executable bits, and model size instead. Full checksums are verified
when an artifact is installed, not on every launch.

Settings shows the current state, download progress, the installed model, a
Reveal button, and the engine/model/decoder license notice. The install keeps
the complete MIT, LGPL-2.1, and CC-BY-4.0 texts next to that notice. No capture
audio is sent to the model or decoder providers; they supply files only.

Settings changes preflight the selected binary before stopping a healthy relay.
The new configuration is persisted only after the replacement relay starts, and
a failed apply attempts to restore the previous relay and keeps the previous
stored settings.

The relay is launched without a shell:

```text
highlite-relay --env-file <relay.env> --bind 127.0.0.1:<port>
               --data-dir <data> --config-dir <config>
```

The child environment strips `HIGHLITE_RELAY_*` and `HIGHLITE_CONFIG_DIR`, adds
an augmented `PATH` for Homebrew, local, Bun, and `~/.opencode/bin`, and sets
`NO_COLOR=1`.

Startup checks `/healthz` and then an authenticated `/v1/sessions` request:

- A healthy relay that accepts the stored read token is attached to as an
  **external** relay. The app never stops or signals that process.
- A service on the port that fails health or authentication produces a conflict
  message. The app does not start a second relay on that port.
- When the port is free, the app starts and owns its bundled relay, waits for
  health and authentication, then enables the dashboard.

Stopping an owned relay sends `SIGINT`, matching the relay's graceful shutdown
handler. The app only kills the exact PID it launched. An external relay is
detached, never killed.

The default local port is `8787`. The default browser-origin allowlist is
`http://localhost:5173,http://127.0.0.1:5173` so the local demo ingest works out
of the box. Both values are editable in Settings. The native app itself does not
send an `Origin` header.

## Dashboard

The menu bar shows relay status, a pending-suggestion count, dashboard,
start/stop, settings, and quit.

Standard macOS editing shortcuts work in focused text fields, including **Cmd+V**
to paste API keys into secure fields. Secure fields keep secrets masked and retain
the system restrictions on copying or cutting their contents.

The dashboard contains:

- **Overview**: relay state, version, endpoint, tokens, site embed script,
  setup counts, relay log.
- **Sessions**: capture metadata, Jira draft review/edit/publish, OpenCode run
  review, exact prompt preview, eligible targets.
- **Activity**: metadata-only `/v1/activity`.
- **Providers**: add, edit, change default, disconnect. API keys use
  `SecureField`; a blank key is omitted, so editing preserves the stored key.
  Saving labels credentials as "Saved, not verified".
- **Jira recipe**: connection test, project and issue-type discovery, extra
  fields JSON, prompt, automatic/manual publication, image opt-in.
- **OpenCode recipe**: exact absolute project directory, optional CLI path,
  real `opencode api server.info` validation, discovery, candidate limit,
  instructions, enable and auto-draft toggles.
- **Settings**: port, origins, binary path, narration setup status and retry,
  private paths, token copy actions, and suggestion-popup history.

Provider and Jira credentials remain the relay's existing private files. The app
does not read them, migrate them to Keychain, or claim Keychain protection for
them. Only the relay bearer tokens are in Keychain.

## Jira flow

1. Configure a default AI provider.
2. Enter the Jira Cloud site URL, account email, and API token.
3. Test the connection to fetch real projects.
4. Choose a project, load issue types, and choose a type.
5. Save. A blank token is omitted; the relay reuses the saved token only when
   the site URL and email still match.
6. Generate a draft from a session, edit the summary/description, save the
   revision, then publish through an explicit confirmation alert.

Publishing is revision-checked by the relay. An ambiguous publish is shown as
`publish-unknown` and is not retried automatically.

## OpenCode flow

1. Configure a default AI provider.
2. Set an **absolute** project directory. This field is required when enabled.
   Only root OpenCode sessions whose `location.directory` exactly equals it are
   eligible; subtrees and subagent sessions are excluded.
3. Optionally set the CLI path. Validation runs `opencode api server.info`
   locally without a shell; the path must be absolute, a command name, or empty.
4. Save and discover. The relay invokes the authenticated OpenCode CLI and
   returns the real CLI version, eligible session metadata, and projects.
5. Start analysis from a session. Routing receives only a bounded capture
   excerpt and candidate metadata. It never creates a session.
6. A newly `suggested` run opens the native confirmation window. Manual review
   is also available from Sessions, Activity, the menu bar, and Overview.

The confirmation window shows:

- the exact immutable `promptPreview`
- the AI confidence and reason, if any
- a target chooser limited to eligible discovered sessions
- the selected target title, directory, and session ID

Nothing is submitted until **Send to OpenCode…** is confirmed again in the
window's alert. Deferring performs no API call: the run stays `suggested`, the
badge remains, and the review key is persisted so the same revision does not
interrupt again. Clearing popup history in Settings re-enables notifications for
still-pending runs. There is no automatic retry for `submit-unknown`.

After a clear rejection, the relay pins the run to the target that was actually
sent. The native retry window therefore locks its picker to that target; changing
targets requires regenerating the suggestion. Terminal `submitted` and
`submit-unknown` runs are never offered for re-analysis.

## Security boundaries

- No focused-window detection and no Accessibility, AppleScript, or OpenCode
  active-session API.
- No automatic OpenCode submission.
- Relay transport is loopback HTTP only. `URLSession` is ephemeral, cookies and
  credential storage are disabled, and redirects are rejected.
- Error messages expose relay `{ "error": "..." }` text, never bearer tokens,
  request bodies, prompts, or raw OpenCode stdout/stderr.
- Relay child output is bounded and redacts both relay tokens. Request bodies are
  never logged.
- The app is ad-hoc signed, unsandboxed, and not notarized.

## Tests

The core test target includes fixture decoding, typed API request shapes, blank
secret omission, safe HTTP errors, no-redirect behavior, environment-file
permissions/token preservation/replacement, symlink rejection, settings
preflight/rollback ordering, provider id/endpoint rules, Jira input trimming,
pinned OpenCode retry targets, supervisor startup cancellation, conflict retry,
owned-child cleanup, CLI path resolution, `server.info` probing, and bundled/dev
relay lookup.

```sh
swift test --package-path apps/macos
```

## Known macOS-only verification

Swift builds, SwiftUI type checking, Keychain access, `Process` signaling,
`NSStatusItem`/window activation, plist linting, code signing, and end-to-end
relay supervision can only be exercised on macOS. A Linux static check is not a
compilation or runtime guarantee.
