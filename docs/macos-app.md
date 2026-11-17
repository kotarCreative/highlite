# Native macOS menu bar app

`apps/macos` is a Swift Package Manager app that supervises a local Highlite relay and
opens the relay's dashboard. It is a native loopback client, not a replacement for the
relay or the browser SDK. SwiftUI/AppKit live in the executable target; Foundation,
Security, and relay logic live in `HighliteMenuBarCore` so they can be tested without a
window server.

## Requirements

- macOS 14 or newer on Apple silicon or Intel.
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

`pnpm build:macos` builds `highlite-relay` in release mode, builds the `HighliteMenuBar`
product in release mode, and assembles:

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
badge, and actions to open the dashboard, start or stop the relay, and quit.

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
    HighliteMenuBar/
      HighliteMenuBarApp.swift
      AppDelegate.swift
      AppModel.swift
      Views/
  Tests/HighliteMenuBarCoreTests/
  README.md
```

`Package.swift` uses Swift tools 5.9, `.macOS(.v14)`, and the executable product
`HighliteMenuBar`. The bundle identifier is `com.highlite.menubar`, it is an agent app
(`LSUIElement`), and local networking is allowed for loopback relay traffic.

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
10. Quit the app and confirm the owned relay stops gracefully.

## Limitations

- macOS 14+ only; ad-hoc signed and not notarized.
- No sandbox/App Store packaging in this slice.
- Existing OpenCode sessions only; no creation of new sessions.
- No exactly-once OpenCode delivery. Ambiguous submissions become `submit-unknown` and
  must be checked manually.
- The web relay UI stays Jira-only; OpenCode configuration lives in the native app.
