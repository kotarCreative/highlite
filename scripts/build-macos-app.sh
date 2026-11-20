#!/usr/bin/env bash
# Build the native Highlite menu bar app and a distributable (ad-hoc signed) bundle.
#
# This script only runs on macOS with a Rust toolchain, Swift 5.9+, and the
# macOS 15 SDK (Xcode 16 or newer). The recorder compiles macOS 15
# ScreenCaptureKit APIs behind @available(macOS 15, *), so the SDK must be 15+
# even though the app's deployment floor stays macOS 14.
# It builds for the host CPU architecture; it is not a universal binary and it
# does not notarize the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
APP_NAME="HighliteMenuBar"
APP_BUNDLE="$ROOT/dist/Highlite.app"
TMP_BUNDLE="$ROOT/dist/.Highlite.app.tmp.$$"
BACKUP_BUNDLE="$ROOT/dist/.Highlite.app.backup.$$"
INFO_PLIST="$APP_DIR/Resources/Info.plist"
APP_ICON="$APP_DIR/Resources/AppIcon.icns"
RELAY_BIN="$ROOT/target/release/highlite-relay"
SWAP_DONE=0
FINAL_VERIFIED=0

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
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
# Fail before any build work when the selected SDK is older, so the user gets
# one clear requirement instead of a wall of Swift availability errors.
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

cleanup() {
  local status=$?
  trap - EXIT

  if [[ -e "$TMP_BUNDLE" ]]; then
    rm -rf -- "$TMP_BUNDLE"
  fi

  if [[ "$SWAP_DONE" == "1" && "$FINAL_VERIFIED" != "1" ]]; then
    # Never leave a half-verified bundle in the final location.
    rm -rf -- "$APP_BUNDLE"
    if [[ -e "$BACKUP_BUNDLE" ]]; then
      mv "$BACKUP_BUNDLE" "$APP_BUNDLE"
    fi
  elif [[ -e "$BACKUP_BUNDLE" ]]; then
    if [[ ! -e "$APP_BUNDLE" ]]; then
      mv "$BACKUP_BUNDLE" "$APP_BUNDLE"
    else
      rm -rf -- "$BACKUP_BUNDLE"
    fi
  fi

  exit "$status"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "the native menu bar app can only be built on macOS (current system: $(uname -s))"
fi

require_macos_15_sdk

for tool in cargo swift plutil codesign install lipo xattr; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found on PATH: $tool"
done

[[ -d "$APP_DIR" ]] || fail "missing Swift package at $APP_DIR"
[[ -f "$APP_DIR/Package.swift" ]] || fail "missing $APP_DIR/Package.swift"
[[ -f "$INFO_PLIST" ]] || fail "missing $INFO_PLIST"
[[ -f "$APP_ICON" ]] || fail "missing $APP_ICON"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64 | x86_64) ;;
  *) fail "unsupported host architecture: $ARCH" ;;
esac

note "Building highlite-relay (release, native $ARCH)"
cargo build --manifest-path "$ROOT/Cargo.toml" --release -p highlite-relay
[[ -x "$RELAY_BIN" ]] || fail "relay build did not produce $RELAY_BIN"

note "Building $APP_NAME (release, native $ARCH)"
swift build --package-path "$APP_DIR" -c release --product "$APP_NAME"
BIN_DIR="$(swift build --package-path "$APP_DIR" -c release --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_NAME"
[[ -x "$APP_BIN" ]] || fail "Swift build did not produce $APP_BIN"

mkdir -p "$ROOT/dist"
# Only the exact temp path for this run is removed. The previous app bundle is
# moved aside after the replacement has been assembled, linted, and signed.
rm -rf -- "$TMP_BUNDLE"

note "Assembling $TMP_BUNDLE"
install -d "$TMP_BUNDLE/Contents/MacOS" "$TMP_BUNDLE/Contents/Resources"
install -m 755 "$APP_BIN" "$TMP_BUNDLE/Contents/MacOS/$APP_NAME"
install -m 644 "$INFO_PLIST" "$TMP_BUNDLE/Contents/Info.plist"
install -m 644 "$APP_ICON" "$TMP_BUNDLE/Contents/Resources/AppIcon.icns"
install -m 755 "$RELAY_BIN" "$TMP_BUNDLE/Contents/Resources/highlite-relay"

MAIN_BIN="$TMP_BUNDLE/Contents/MacOS/$APP_NAME"
SIDECAR_BIN="$TMP_BUNDLE/Contents/Resources/highlite-relay"
BUNDLED_EXECUTABLE="$(
  plutil -extract CFBundleExecutable raw -o - "$TMP_BUNDLE/Contents/Info.plist"
)"
BUNDLED_ICON="$(
  plutil -extract CFBundleIconFile raw -o - "$TMP_BUNDLE/Contents/Info.plist"
)"
[[ "$BUNDLED_EXECUTABLE" == "$APP_NAME" ]] ||
  fail "Info.plist CFBundleExecutable is '$BUNDLED_EXECUTABLE', expected '$APP_NAME'"
[[ "$BUNDLED_ICON" == "AppIcon.icns" ]] ||
  fail "Info.plist CFBundleIconFile is '$BUNDLED_ICON', expected 'AppIcon.icns'"
[[ -f "$TMP_BUNDLE/Contents/Resources/AppIcon.icns" ]] ||
  fail "assembled app icon is missing"
[[ -x "$MAIN_BIN" ]] || fail "assembled app executable is missing or not executable"
[[ -x "$SIDECAR_BIN" ]] || fail "assembled relay sidecar is missing or not executable"

plutil -lint "$TMP_BUNDLE/Contents/Info.plist"

APP_ARCHS="$(lipo -archs "$MAIN_BIN")"
RELAY_ARCHS="$(lipo -archs "$SIDECAR_BIN")"
[[ "$APP_ARCHS" == "$ARCH" ]] ||
  fail "$APP_NAME architecture '$APP_ARCHS' does not match native host '$ARCH'"
[[ "$RELAY_ARCHS" == "$ARCH" ]] ||
  fail "relay architecture '$RELAY_ARCHS' does not match native host '$ARCH'"
[[ "$APP_ARCHS" == "$RELAY_ARCHS" ]] ||
  fail "app and relay architectures differ: '$APP_ARCHS' vs '$RELAY_ARCHS'"

note "Clearing extended attributes before signing"
xattr -cr "$TMP_BUNDLE"

note "Signing the relay sidecar explicitly, then the app (ad-hoc, not notarized)"
codesign --force --sign - "$SIDECAR_BIN"
codesign --verify --strict --verbose=2 "$SIDECAR_BIN"
codesign --force --sign - "$TMP_BUNDLE"
codesign --verify --strict --verbose=2 "$TMP_BUNDLE"

note "Swapping the verified bundle into place"
if [[ -e "$APP_BUNDLE" ]]; then
  mv "$APP_BUNDLE" "$BACKUP_BUNDLE"
fi
mv "$TMP_BUNDLE" "$APP_BUNDLE"
SWAP_DONE=1

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --verify --strict --verbose=2 "$APP_BUNDLE/Contents/Resources/highlite-relay"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
FINAL_VERIFIED=1

if [[ -e "$BACKUP_BUNDLE" ]]; then
  rm -rf -- "$BACKUP_BUNDLE"
fi

cat <<EOF

Built $APP_BUNDLE

Architecture: native host only ($ARCH), not universal.
Signing: ad-hoc only. The relay sidecar and app were signed and verified
separately. The app is not notarized and has no Developer ID signature, so
Gatekeeper may require an explicit Open on first launch.
The bundled relay is at Contents/Resources/highlite-relay.
Launch it with: open "$APP_BUNDLE"
EOF
