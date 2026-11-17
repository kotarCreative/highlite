#!/usr/bin/env bash
# Regenerate committed Linux icons from the shared Highlite brand source.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
linux="$root/apps/linux"
macos_svg="$root/apps/macos/Resources/AppIcon.svg"
tray_svg="$linux/assets/highlite-tray.svg"

command -v rsvg-convert >/dev/null || {
  echo "rsvg-convert is required (librsvg2-bin on Debian/Ubuntu, librsvg on Arch)." >&2
  exit 1
}
[[ -f "$macos_svg" ]] || { echo "Missing $macos_svg" >&2; exit 1; }
[[ -f "$tray_svg" ]] || { echo "Missing $tray_svg" >&2; exit 1; }

# Keep the Linux app icon derived from the macOS vector source. Do not edit the
# macOS icns pipeline from here.
cp "$macos_svg" "$linux/assets/highlite.svg"
for size in 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$macos_svg" -o "$linux/assets/icons/highlite-$size.png"
done
for size in 22 24 32 44 48 64; do
  rsvg-convert -w "$size" -h "$size" "$tray_svg" -o "$linux/assets/icons/highlite-tray-$size.png"
done

echo "Regenerated Linux icons under $linux/assets/icons"
