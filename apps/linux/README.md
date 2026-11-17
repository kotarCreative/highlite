# Highlite Linux desktop shell

A first Linux desktop increment for Highlite. It is a small GTK 3 + WebKitGTK
window with a real `StatusNotifierItem` (system tray) icon. It supervises its
own loopback `highlite-relay` child and reuses the existing branded relay
dashboard rather than duplicating the macOS dashboard or recorder.

This is an MVP, not macOS parity. It is intentionally isolated under
`apps/linux/` and has its own Cargo workspace and lockfile, so it does not add
Linux desktop dependencies to the root relay/compiler build.

## What works

- Tray icon through the host's StatusNotifierWatcher/StatusNotifierHost. On
  Omarchy this is the quickshell bar; no GNOME AppIndicator extension is
  assumed. The implementation is `ksni` over D-Bus, not XEmbed.
- Tray status line and tooltip: stopped, starting, running (loopback port), or
  needs attention.
- Tray actions: **Open Dashboard**, **Start Relay**, **Stop Relay**,
  **Restart Relay**, and **Quit Highlite**. Left-click activates the window.
- A native GTK status page while the relay is starting or stopped, including a
  retry button and the private capture directory.
- Embedded WebKitGTK dashboard at `http://127.0.0.1:<port>/#token=…` once the
  relay is healthy and the app-owned read token authenticates.
- Closing the window hides it while the tray is available. With no working
  tray host, closing the window quits instead of leaving an unreachable app.
- Single instance through `GtkApplication`/GApplication. Launching the app again
  activates the primary window; it does not start a second relay.
- Owned relay lifecycle: the app spawns the relay itself, only stops that child,
  forwards SIGTERM first, and uses `PR_SET_PDEATHSIG` so a crashed shell does not
  leave a relay behind.
- Private configuration and data:
  - `~/.config/highlite/linux/relay.env` (mode 0600)
  - `~/.config/highlite/linux/` provider/Jira config for this app (mode 0700)
  - `~/.local/share/highlite/linux/` capture data (mode 0700)
  - `HIGHLITE_DESKTOP_CONFIG_DIR` and `HIGHLITE_DESKTOP_DATA_DIR` override the
    roots for isolated runs and tests.
- 32-byte random read and ingest tokens, generated from `/dev/urandom`. The
  relay runs with `--ui` on an ephemeral loopback port with explicit
  `HIGHLITE_RELAY_ALLOWED_HOSTS` and `HIGHLITE_RELAY_ALLOWED_ORIGINS`.
- Token-bearing startup output from the relay is redacted before it reaches the
  app log. The app prints only `relay ready at http://127.0.0.1:<port>/ (token
  withheld)`.
- WebView hardening: ephemeral WebKit context, no developer extras, no console
  messages to stdout, no page cache, and a navigation policy that allows only
  the owned `127.0.0.1:<port>` origin and `about:blank`. Other `http`, `https`,
  and `mailto` URLs are handed to the system browser; `file:` and other schemes
  are blocked.
- Relay binary resolution:
  1. `HIGHLITE_RELAY_BIN`
  2. `highlite-relay` next to the app binary
  3. `../lib/highlite/highlite-relay` / `../libexec/highlite/highlite-relay`
  4. `target/{release,debug}/highlite-relay` in this repository
  5. `highlite-relay` on `PATH`
- Branded Linux icons derived from `apps/macos/Resources/AppIcon.svg` plus a
  small transparent tray marker. The macOS icon pipeline is untouched.

## Build requirements

The app needs GTK 3 and WebKitGTK 4.1 development files. It deliberately does
not need libappindicator: tray support is pure Rust over D-Bus.

Arch Linux / Omarchy:

```sh
# Usually already installed on Omarchy.
sudo pacman -S --needed gtk3 webkit2gtk-4.1
```

Debian/Ubuntu:

```sh
sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev
```

The standalone workspace uses the repository's Rust 2024 toolchain.

## Build and run from source

```sh
cargo build -p highlite-relay
cargo build --manifest-path apps/linux/Cargo.toml
HIGHLITE_RELAY_BIN="$PWD/target/debug/highlite-relay" \
  apps/linux/target/debug/highlite-desktop
```

Or use the helper, which builds release binaries:

```sh
apps/linux/scripts/build.sh
HIGHLITE_RELAY_BIN="$PWD/target/release/highlite-relay" \
  apps/linux/target/release/highlite-desktop
```

On first launch the app opens its own dashboard. It does not import
`~/.config/highlite` from the relay CLI or macOS app; this MVP keeps provider
and Jira configuration in `~/.config/highlite/linux` so a first run cannot
consume live integrations.

If `highlite-relay` is missing, the window shows the exact remediation instead
of exiting silently. Set `HIGHLITE_RELAY_BIN` or install the bundled relay with
the install script.

## Install for the current user

```sh
apps/linux/scripts/install.sh
```

This installs:

```text
~/.local/bin/highlite-desktop
~/.local/lib/highlite/highlite-relay
~/.local/share/applications/com.highlite.Highlite.desktop
~/.local/share/icons/hicolor/{128,256,512}x*/apps/com.highlite.Highlite.png
```

The install is opt-in and does **not** enable autostart. The desktop entry uses
an absolute `Exec` path so it works even when `~/.local/bin` is not on `PATH`.
A system-wide prefix can be selected with `--prefix`, but the script itself does
not use sudo.

## Configuration and security notes

`relay.env` is app-owned for the keys the app needs: bind address, data/config
roots, UI enablement, tokens, allowed host, and allowed origin. Unknown lines
and comments are preserved so optional relay settings can live in the same file.
Existing valid read/ingest token values are preserved across launches; invalid
or empty values are regenerated. The file is written through a mode-0600
temporary file in the same directory and atomically renamed. Symlink
destinations are rejected.

The app removes ambient `HIGHLITE_*` variables from the relay child so a shell
or previous installation cannot silently override the app-owned env file. The
relay child runs under umask 077 for its config and data files.

The dashboard token is loaded into `sessionStorage` by the existing web UI and
removed from the URL fragment. The WebView uses an ephemeral data context so
the token is not persisted to disk. The token is never printed by the desktop
shell and is redacted from relay stderr. It is still present in `relay.env`
because the relay requires it there; that file is private to the user.

Navigation is restricted to the owned loopback origin. External links are
opened by the system browser. Download behavior inside the WebView is not part
of this MVP and should be treated as untested.

## Tests

Fast unit tests and real-relay integration tests, plus the Linux-only formatting
and clippy gate:

```sh
apps/linux/scripts/check.sh
```

The integration tests start a real `highlite-relay` on an isolated port and
check health, read/ingest token separation, env/data permissions, missing
binary handling, port conflicts, and that stopping the owned child leaves no
process behind. They locate the relay through `HIGHLITE_RELAY_BIN` or the
repository build; build it first with `cargo build -p highlite-relay`.

End-to-end desktop smoke test (needs a graphical session with a
StatusNotifierWatcher and `busctl`, `curl`, and Python 3):

```sh
apps/linux/scripts/smoke.sh
```

The smoke test uses a unique application id (`HIGHLITE_DESKTOP_APP_ID`, test
only; the installed app uses `com.highlite.Highlite`), private temporary
config/data, a fresh port, and checks:

- relay readiness and `/healthz`;
- authorized and unauthenticated dashboard API access;
- config/data/env permissions;
- token redaction in the app log;
- StatusNotifierItem registration with the running watcher;
- tray menu labels and real Stop Relay / Start Relay menu actions;
- duplicate launch activates the primary without creating a second relay;
- SIGTERM stops the shell and its owned relay.

If the desktop has no StatusNotifierWatcher, the smoke test stops with a clear
failure rather than claiming the tray works. `--allow-missing-tray` runs the
same lifecycle and menu-object checks in a degraded mode; it still exercises
Stop Relay and Start Relay through the item's D-BusMenu, but skips the
host-registration assertion.

## Manual verification

1. Start the app from a terminal or the installed desktop entry.
2. Confirm the highlighter marker appears in the bar's tray area and the
   tooltip says `Highlite` with `Relay running on 127.0.0.1:<port>`.
3. Click the marker; the dashboard window should appear.
4. Open the tray menu and choose **Stop Relay**; the window should switch to the
   native status page and the relay process should disappear.
5. Choose **Start Relay**; a new port and dashboard should appear.
6. Launch the app a second time; the existing window should focus and only one
   `highlite-relay` child should exist.
7. Choose **Quit Highlite**; both shell and owned relay should exit.

Visual verification requires actually viewing the bar/window. An automated
screenshot is not part of the smoke test because compositor screenshot support
varies by session and must not be assumed.

## Known gaps / macOS parity

- No macOS Settings, OpenCode review window, activity view, narration/Parakeet
  provisioning, embed snippet generator, or capture launcher is implemented
  natively. The embedded relay dashboard provides the existing sessions, Jira,
  OpenCode, provider, and activity screens that the relay already serves.
- No autostart toggle. The install script never enables it.
- No native notifications, status-bar menu extras beyond the SNI menu, global
  shortcuts, login item, updater, code signing, or packaged `.deb`/Flatpak/AppImage
  yet.
- No Windows shell. The architecture remains open to a shared shell later, but
  this increment is Linux-only.
- No sharing of the macOS app's Keychain-backed tokens or its provider config.
  Linux tokens live in the mode-0600 relay env file.
- Browser downloads from the dashboard (for example bundle ZIPs) are delegated
  to WebKit's default behavior and are not covered by tests.
- The relay is expected to be a local development/production binary. A packaged
  release should bundle and sign it deliberately; the install helper currently
  copies an unsigned local build.
- Wayland focus stealing prevention may require the compositor to honor the
  activation request when raising an already-hidden window. The app requests
  presentation; it does not force focus.

## Icon assets

`assets/highlite.svg` is derived from
`apps/macos/Resources/AppIcon.svg`. Regenerate the committed PNGs with:

```sh
apps/linux/scripts/generate-icons.sh
```

This requires `rsvg-convert`. The tray SVG is
`assets/highlite-tray.svg`; the generated 22/24/32/44/48/64 px PNGs are embedded
in the binary as StatusNotifier pixmaps.

## Licensing

The Linux shell source is MIT, matching the repository. It uses GTK 3 and
WebKitGTK under their respective licenses, and `ksni` (Unlicense) for the
StatusNotifierItem implementation. The highlighter artwork is part of the
Highlite brand assets in this repository.
