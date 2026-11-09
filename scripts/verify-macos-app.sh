#!/usr/bin/env bash
# Verify the native macOS app package.
#
# On macOS this compiles and tests the Swift package, builds the app bundle,
# lints the plist, and verifies the ad-hoc signature.
#
# On Linux this performs static package checks only. Passing here is NOT proof
# that the Swift app compiles, that Keychain works, or that the bundle is valid.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
APP_BUNDLE="$ROOT/dist/Highlite.app"
INFO_PLIST="$APP_DIR/Resources/Info.plist"
APP_NAME="HighliteMenuBar"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: ${1#"$ROOT/"}"
}

require_grep() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" || fail "expected pattern '$pattern' in ${file#"$ROOT/"}"
}

[[ -d "$APP_DIR" ]] || fail "missing native app package at apps/macos"

note "Checking Swift package structure and product"
require_file "$APP_DIR/Package.swift"
require_file "$INFO_PLIST"
require_file "$APP_DIR/README.md"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/RelayModels.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/RelayClient.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/RelayProcessController.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/KeychainStore.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/OpenCodeLocator.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/AppSettings.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/HighliteMenuBarApp.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/AppDelegate.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/AppModel.swift"

require_grep 'swift-tools-version:[[:space:]]*5\.9|tools:[[:space:]]*"5\.9"' "$APP_DIR/Package.swift"
require_grep '\.macOS\(\.v14\)' "$APP_DIR/Package.swift"
require_grep "name:[[:space:]]*\"$APP_NAME\"" "$APP_DIR/Package.swift"
require_grep "HighliteMenuBarCore" "$APP_DIR/Package.swift"
[[ -d "$APP_DIR/Tests/HighliteMenuBarCoreTests" ]] ||
  fail "missing Tests/HighliteMenuBarCoreTests"

note "Checking initial browser ingest origins"
for origin in 'http://localhost:5173' 'http://127.0.0.1:5173'; do
  grep -R -q "$origin" "$APP_DIR/Sources" ||
    fail "initial app settings must allow the local demo origin: $origin"
done

note "Checking Info.plist keys"
for expected in \
  'com.highlite.menubar' \
  'HighliteMenuBar' \
  'APPL' \
  '0.1.0' \
  '14.0' \
  'LSUIElement' \
  'NSAllowsLocalNetworking'; do
  grep -q "$expected" "$INFO_PLIST" || fail "Info.plist is missing expected value: $expected"
done

if command -v python3 >/dev/null 2>&1; then
  python3 - "$INFO_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as handle:
    value = plistlib.load(handle)

expected = {
    'CFBundleIdentifier': 'com.highlite.menubar',
    'CFBundleExecutable': 'HighliteMenuBar',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
}
for key, wanted in expected.items():
    if value.get(key) != wanted:
        raise SystemExit(f'Info.plist {key} expected {wanted!r}, got {value.get(key)!r}')
if value.get('NSAppTransportSecurity', {}).get('NSAllowsLocalNetworking') is not True:
    raise SystemExit('Info.plist must allow local networking')
PY
else
  note "python3 not found; plist key checks use text matching only"
fi

note "Checking for forbidden focused-window and scripting APIs"
forbidden="$(
  grep -R -n -E 'frontmostApplication|AXUIElement|NSAppleScript|osascript|System Events|session/active' \
    "$APP_DIR/Sources" 2>&1 || true
)"
if [[ -n "$forbidden" ]]; then
  printf '%s\n' "$forbidden" >&2
  fail "native app sources reference a forbidden focused-window or scripting API"
fi

note "Checking packaging scripts and build-architecture documentation"
require_file "$ROOT/scripts/build-macos-app.sh"
bash -n "$ROOT/scripts/build-macos-app.sh"
bash -n "$ROOT/scripts/verify-macos-app.sh"
grep -q 'host architecture only' "$ROOT/docs/macos-app.md" ||
  fail "docs/macos-app.md must document the native-host-only build architecture"
if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/scripts/opencode-recipe-smoke.mjs"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat <<EOF

Static checks passed on $(uname -s).

This is NOT proof the native app compiles. Swift build/test, Keychain access,
app-bundle assembly, plist linting with plutil, ad-hoc codesign, and runtime
relay supervision were not exercised. Run this script on macOS before shipping.
EOF
  exit 0
fi

for tool in swift plutil codesign lipo; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found on PATH: $tool"
done

note "Building the Swift package (release)"
swift build --package-path "$APP_DIR" -c release --product "$APP_NAME"

note "Running the Swift package tests"
swift test --package-path "$APP_DIR"

note "Building and signing the app bundle"
bash "$ROOT/scripts/build-macos-app.sh"

MAIN_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SIDECAR_BIN="$APP_BUNDLE/Contents/Resources/highlite-relay"

note "Linting the bundled Info.plist and checking the declared executable"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
BUNDLED_EXECUTABLE="$(
  plutil -extract CFBundleExecutable raw -o - "$APP_BUNDLE/Contents/Info.plist"
)"
[[ "$BUNDLED_EXECUTABLE" == "$APP_NAME" ]] ||
  fail "CFBundleExecutable is '$BUNDLED_EXECUTABLE', expected '$APP_NAME'"
[[ -x "$MAIN_BIN" ]] || fail "missing executable Contents/MacOS/$APP_NAME"
[[ -x "$SIDECAR_BIN" ]] || fail "missing executable Contents/Resources/highlite-relay"

note "Checking native architecture consistency"
HOST_ARCH="$(uname -m)"
APP_ARCHS="$(lipo -archs "$MAIN_BIN")"
RELAY_ARCHS="$(lipo -archs "$SIDECAR_BIN")"
[[ "$APP_ARCHS" == "$HOST_ARCH" ]] ||
  fail "$APP_NAME architecture '$APP_ARCHS' does not match native host '$HOST_ARCH'"
[[ "$RELAY_ARCHS" == "$HOST_ARCH" ]] ||
  fail "relay architecture '$RELAY_ARCHS' does not match native host '$HOST_ARCH'"
[[ "$APP_ARCHS" == "$RELAY_ARCHS" ]] ||
  fail "app and relay architectures differ: '$APP_ARCHS' vs '$RELAY_ARCHS'"
printf '    host=%s app=%s relay=%s\n' "$HOST_ARCH" "$APP_ARCHS" "$RELAY_ARCHS"

note "Verifying the relay sidecar and app signatures explicitly"
codesign --verify --strict --verbose=2 "$SIDECAR_BIN"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

cat <<EOF

macOS verification passed for $APP_BUNDLE

The signature is ad-hoc and the app is not notarized. This check confirms the
bundle is internally consistent; it does not establish Gatekeeper trust.
EOF
