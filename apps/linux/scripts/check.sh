#!/usr/bin/env bash
# Linux-only formatting, lint, and test gate. The root pnpm check does not
# include this standalone workspace.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

cargo build --manifest-path "$root/Cargo.toml" -p highlite-relay
cargo fmt --manifest-path "$root/apps/linux/Cargo.toml" -- --check
cargo clippy --manifest-path "$root/apps/linux/Cargo.toml" --all-targets -- -D warnings
cargo test --manifest-path "$root/apps/linux/Cargo.toml"

echo "Linux shell checks passed."
