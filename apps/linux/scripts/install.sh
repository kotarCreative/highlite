#!/usr/bin/env bash
# Install the Linux shell for the current user. This deliberately does not
# enable autostart; add a desktop autostart entry yourself if you want one.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
prefix="${PREFIX:-$HOME/.local}"
build=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="${2:?--prefix needs a path}"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    -h|--help)
      sed -n '1,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$build" == 1 ]]; then
  "$root/apps/linux/scripts/build.sh"
fi

shell="$root/apps/linux/target/release/highlite-desktop"
relay="$root/target/release/highlite-relay"
[[ -x "$shell" ]] || { echo "Missing $shell; run without --no-build." >&2; exit 1; }
[[ -x "$relay" ]] || { echo "Missing $relay; run without --no-build." >&2; exit 1; }

install -d "$prefix/bin" "$prefix/lib/highlite" "$prefix/share/applications"
install -Dm755 "$shell" "$prefix/bin/highlite-desktop"
install -Dm755 "$relay" "$prefix/lib/highlite/highlite-relay"

for size in 128 256 512; do
  install -Dm644 "$root/apps/linux/assets/icons/highlite-$size.png" \
    "$prefix/share/icons/hicolor/${size}x${size}/apps/com.highlite.Highlite.png"
done

desktop="$prefix/share/applications/com.highlite.Highlite.desktop"
cat >"$desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Highlite
GenericName=Capture Relay
Comment=Local capture relay and session dashboard
Exec="$prefix/bin/highlite-desktop"
Icon=com.highlite.Highlite
Terminal=false
Categories=Development;
StartupNotify=true
StartupWMClass=Highlite-desktop
Keywords=Highlite;capture;sessions;relay;
EOF
chmod 0644 "$desktop"

if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -f -t "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Installed Highlite under $prefix"
echo "  $prefix/bin/highlite-desktop"
echo "  $prefix/lib/highlite/highlite-relay"
echo "  $desktop"
echo "Autostart was not enabled."
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Note: $prefix/bin is not on PATH; the desktop entry uses an absolute Exec path." ;;
esac
