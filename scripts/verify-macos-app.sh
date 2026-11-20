#!/usr/bin/env bash
# Verify the native macOS app package.
#
# On macOS this compiles and tests the Swift package, builds the app bundle,
# lints the plist, and verifies the ad-hoc signature. Compiling needs the
# macOS 15 SDK (Xcode 16 or newer) because the recorder guards macOS 15
# ScreenCaptureKit APIs with @available; the deployment floor stays macOS 14.
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

MIN_XCODE_VERSION="16.0"
MIN_MACOS_SDK_VERSION="15.0"

# Numeric dotted-version comparison: succeeds when "$1" is at least "$2".
version_at_least() {
  awk -v have="$1" -v want="$2" 'BEGIN {
    nh = split(have, h, ".")
    nw = split(want, w, ".")
    for (i = 1; i <= 3; i++) {
      hv = (i <= nh && h[i] ~ /^[0-9]+$/) ? h[i] + 0 : 0
      wv = (i <= nw && w[i] ~ /^[0-9]+$/) ? w[i] + 0 : 0
      if (hv > wv) exit 0
      if (hv < wv) exit 1
    }
    exit 0
  }'
}

# The ScreenCaptureKit recording APIs used by the app are macOS 15 SDK APIs.
# Fail before building or testing when the selected SDK is older, so the user
# gets one clear requirement instead of a wall of Swift availability errors.
require_macos_15_sdk() {
  local sdk_version xcode_version=""

  command -v xcrun >/dev/null 2>&1 ||
    fail "xcrun not found on PATH: install Xcode $MIN_XCODE_VERSION or newer (macOS $MIN_MACOS_SDK_VERSION SDK) or the matching Command Line Tools"

  sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  [[ -n "$sdk_version" ]] ||
    fail "could not determine the macOS SDK version: install Xcode $MIN_XCODE_VERSION or newer (macOS $MIN_MACOS_SDK_VERSION SDK) and select it with xcode-select -s"

  version_at_least "$sdk_version" "$MIN_MACOS_SDK_VERSION" ||
    fail "macOS SDK $sdk_version is too old: the ScreenCaptureKit recording APIs require the macOS $MIN_MACOS_SDK_VERSION SDK or newer (Xcode $MIN_XCODE_VERSION or newer). Select a newer Xcode with xcode-select -s"

  if command -v xcodebuild >/dev/null 2>&1; then
    xcode_version="$(xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2; exit}')" ||
      xcode_version=""
  fi

  if [[ -n "$xcode_version" ]]; then
    version_at_least "$xcode_version" "$MIN_XCODE_VERSION" ||
      fail "Xcode $xcode_version is too old: Xcode $MIN_XCODE_VERSION or newer (macOS $MIN_MACOS_SDK_VERSION SDK) is required for the ScreenCaptureKit recording APIs"
    note "Using Xcode $xcode_version with macOS SDK $sdk_version"
  else
    note "Using macOS SDK $sdk_version (Xcode version not detected)"
  fi
}

[[ -d "$APP_DIR" ]] || fail "missing native app package at apps/macos"

note "Checking Swift package structure and product"
require_file "$APP_DIR/Package.swift"
require_file "$INFO_PLIST"
require_file "$APP_DIR/Resources/AppIcon.svg"
require_file "$APP_DIR/Resources/AppIcon.icns"
require_file "$ROOT/scripts/generate-macos-app-icon.py"
require_file "$APP_DIR/README.md"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/RelayModels.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/RelayClient.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/RelayProcessController.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/KeychainStore.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/OpenCodeLocator.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/AppSettings.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeCaptureAnnotation.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeCaptureBundle.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeCaptureCommand.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeLiveAnnotation.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingBundle.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingFile.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingLifecycle.swift"
require_file "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingTempStore.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/HighliteMenuBarApp.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/AppDelegate.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/AppModel.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/NativeCaptureDraft.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/NativeCaptureService.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/NativeLiveAnnotationSession.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/NativeRecordingController.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/NativeRecordingDraft.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/NativeRecordingService.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/Views/AnnotationCanvas.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/Views/CaptureReviewView.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/Views/NativeLiveAnnotationBar.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/Views/RecordingSetupView.swift"
require_file "$APP_DIR/Sources/HighliteMenuBar/Views/RecordingReviewView.swift"

require_grep 'swift-tools-version:[[:space:]]*5\.9|tools:[[:space:]]*"5\.9"' "$APP_DIR/Package.swift"
# The deployment floor stays macOS 14; macOS 15 recording APIs are guarded with
# @available(macOS 15, *). Accept any macOS 14+ declaration (or newer during a
# transition), while the Darwin build paths enforce the macOS 15 SDK separately.
require_grep '\.macOS\((\.v1[4-9]|"1[4-9]\.[0-9]+")\)' "$APP_DIR/Package.swift"
require_grep "name:[[:space:]]*\"$APP_NAME\"" "$APP_DIR/Package.swift"
require_grep "HighliteMenuBarCore" "$APP_DIR/Package.swift"
[[ -d "$APP_DIR/Tests/HighliteMenuBarCoreTests" ]] ||
  fail "missing Tests/HighliteMenuBarCoreTests"
require_file "$APP_DIR/Tests/HighliteMenuBarCoreTests/Fixtures/native-recording-manifest.json"

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
  'LSMinimumSystemVersion' \
  'LSUIElement' \
  'AppIcon.icns' \
  'NSAllowsLocalNetworking' \
  'NSMicrophoneUsageDescription'; do
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
    'CFBundleIconFile': 'AppIcon.icns',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
}
for key, wanted in expected.items():
    if value.get(key) != wanted:
        raise SystemExit(f'Info.plist {key} expected {wanted!r}, got {value.get(key)!r}')
minimum = str(value.get('LSMinimumSystemVersion', ''))
parts = minimum.split('.')
if not parts or not all(part.isdigit() for part in parts):
    raise SystemExit(
        f'Info.plist LSMinimumSystemVersion expected a macOS version, got {minimum!r}'
    )
normalized = tuple(int(part) for part in parts) + (0, 0)
if normalized[:2] < (14, 0):
    raise SystemExit(
        f'Info.plist LSMinimumSystemVersion expected macOS 14.0 or newer, got {minimum!r}'
    )
if value.get('NSAppTransportSecurity', {}).get('NSAllowsLocalNetworking') is not True:
    raise SystemExit('Info.plist must allow local networking')
microphone = value.get('NSMicrophoneUsageDescription')
if not isinstance(microphone, str) or not microphone.strip():
    raise SystemExit('Info.plist must explain microphone recording in NSMicrophoneUsageDescription')
PY
else
  note "python3 not found; plist key checks use text matching only"
fi

note "Checking the bundled highlighter icon"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$APP_DIR/Resources/AppIcon.icns" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, 'rb') as handle:
    data = handle.read()
if len(data) < 8 or data[:4] != b'icns':
    raise SystemExit(f'{path} is not an ICNS file')
declared = struct.unpack('>I', data[4:8])[0]
if declared != len(data):
    raise SystemExit(f'{path} has an inconsistent ICNS length')
required = {'icp4', 'icp5', 'icp6', 'ic07', 'ic08', 'ic09', 'ic10'}
found = set()
offset = 8
while offset < len(data):
    kind = data[offset:offset + 4].decode('ascii', 'replace')
    length = struct.unpack('>I', data[offset + 4:offset + 8])[0]
    if length < 8 or offset + length > len(data):
        raise SystemExit(f'{path} has an invalid ICNS element {kind}')
    found.add(kind)
    offset += length
missing = required - found
if missing:
    raise SystemExit(f'{path} is missing icon sizes: {", ".join(sorted(missing))}')
PY
else
  note "python3 not found; ICNS structure check skipped"
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

note "Checking the additive native recording artifact contract"
require_grep 'movieFileName[[:space:]]*=[[:space:]]*"recording.mp4"' \
  "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingBundle.swift"
require_grep 'posterFileName[[:space:]]*=[[:space:]]*"poster.png"' \
  "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingBundle.swift"
require_grep 'ManifestArtifacts' \
  "$APP_DIR/Sources/HighliteMenuBarCore/NativeRecordingBundle.swift"

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

require_macos_15_sdk

note "Building the Swift package (release)"
swift build --package-path "$APP_DIR" -c release --product "$APP_NAME"

note "Running the Swift package tests"
swift test --package-path "$APP_DIR"

note "Building and signing the app bundle"
bash "$ROOT/scripts/build-macos-app.sh"

MAIN_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SIDECAR_BIN="$APP_BUNDLE/Contents/Resources/highlite-relay"
ICON_BIN="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

note "Linting the bundled Info.plist and checking the declared executable and icon"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
BUNDLED_EXECUTABLE="$(
  plutil -extract CFBundleExecutable raw -o - "$APP_BUNDLE/Contents/Info.plist"
)"
BUNDLED_ICON="$(
  plutil -extract CFBundleIconFile raw -o - "$APP_BUNDLE/Contents/Info.plist"
)"
[[ "$BUNDLED_EXECUTABLE" == "$APP_NAME" ]] ||
  fail "CFBundleExecutable is '$BUNDLED_EXECUTABLE', expected '$APP_NAME'"
[[ "$BUNDLED_ICON" == "AppIcon.icns" ]] ||
  fail "CFBundleIconFile is '$BUNDLED_ICON', expected 'AppIcon.icns'"
[[ -x "$MAIN_BIN" ]] || fail "missing executable Contents/MacOS/$APP_NAME"
[[ -x "$SIDECAR_BIN" ]] || fail "missing executable Contents/Resources/highlite-relay"
[[ -f "$ICON_BIN" ]] || fail "missing icon Contents/Resources/AppIcon.icns"

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
