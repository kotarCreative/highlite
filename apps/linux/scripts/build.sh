#!/usr/bin/env bash
# Build the Linux desktop shell and the relay binary it supervises.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

cargo build --manifest-path "$root/Cargo.toml" --release -p highlite-relay
cargo build --manifest-path "$root/apps/linux/Cargo.toml" --release

echo "relay:  $root/target/release/highlite-relay"
echo "shell:  $root/apps/linux/target/release/highlite-desktop"
echo
echo "Run from source with:"
echo "  HIGHLITE_RELAY_BIN=$root/target/release/highlite-relay \\"
echo "    $root/apps/linux/target/release/highlite-desktop"
