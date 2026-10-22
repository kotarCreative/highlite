#!/usr/bin/env bash
#
# Set up a local Highlite capture → Parakeet → bundle and relay workflow on macOS.
#
#   bash scripts/setup-macos.sh [--install-prereqs] [--verify] [--skip-build]
#                               [--model 110m|0.6b] [--force]
#
# The script is idempotent: existing downloads and builds are reused unless
# --force is passed. Homebrew and the Xcode command line tools are the only
# prerequisites it will not install itself.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
PARAKEET_DIR="$CACHE_BASE/highlite/parakeet"
PARAKEET_BIN_DIR="$PARAKEET_DIR/bin"
PARAKEET_VERSION="${PARAKEET_VERSION:-v0.6.1}"
MODEL_NAME="tdt_ctc-110m-q8_0.gguf"
MODEL_LABEL="110m"

INSTALL_PREREQS=0
VERIFY=0
SKIP_BUILD=0
FORCE=0

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/setup-macos.sh [options]

Options:
  --install-prereqs   Install missing Homebrew packages (node, ffmpeg, pnpm, cmake)
                      and Rust via rustup. Homebrew itself must already exist.
  --verify            Run scripts/parakeet-e2e.mjs after setup.
  --skip-build        Do not run pnpm install/build.
  --model <name>      110m (default, small/fast) or 0.6b (tdt-0.6b-v2, accuracy).
  --force             Re-download the Parakeet CLI and model.
  -h, --help          Show this help.

Environment:
  PARAKEET_VERSION    parakeet.cpp release tag (default v0.6.1)
  XDG_CACHE_HOME      download cache root (default ~/.cache)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-prereqs) INSTALL_PREREQS=1 ;;
    --verify) VERIFY=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --force) FORCE=1 ;;
    --model)
      shift
      case "${1:-}" in
        110m) MODEL_LABEL="110m"; MODEL_NAME="tdt_ctc-110m-q8_0.gguf" ;;
        0.6b | 0.6b-v2) MODEL_LABEL="0.6b"; MODEL_NAME="tdt-0.6b-v2-q8_0.gguf" ;;
        *) die "--model must be 110m or 0.6b" ;;
      esac
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "this script targets macOS; use the compiler README otherwise."

case "$(uname -m)" in
  arm64)
    PARAKEET_ASSET="parakeet-${PARAKEET_VERSION}-bin-macos-metal-arm64.tar.gz"
    ;;
  x86_64)
    PARAKEET_ASSET="parakeet-${PARAKEET_VERSION}-bin-macos-cpu-x64.tar.gz"
    ;;
  *)
    die "unsupported macOS architecture: $(uname -m)"
    ;;
esac

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

if ! command -v brew >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Homebrew is required. Install it, then re-run this script:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
EOF
  exit 1
fi

if ! xcrun --find clang >/dev/null 2>&1; then
  die "install the Xcode command line tools first: xcode-select --install"
fi

if [[ "$INSTALL_PREREQS" -eq 1 ]]; then
  missing=()
  command -v node >/dev/null 2>&1 || missing+=("node")
  command -v ffmpeg >/dev/null 2>&1 || missing+=("ffmpeg")
  command -v pnpm >/dev/null 2>&1 || missing+=("pnpm")
  command -v cmake >/dev/null 2>&1 || missing+=("cmake")
  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Installing Homebrew packages: ${missing[*]}"
    brew install "${missing[@]}"
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    info "Installing Rust with rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi
fi

if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

command -v node >/dev/null 2>&1 || die "node is missing; re-run with --install-prereqs"
command -v pnpm >/dev/null 2>&1 || die "pnpm is missing; re-run with --install-prereqs"
command -v cargo >/dev/null 2>&1 || die "cargo is missing; re-run with --install-prereqs"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is missing; re-run with --install-prereqs"
command -v cmake >/dev/null 2>&1 || die "cmake is missing; re-run with --install-prereqs"

node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$node_major" -lt 22 ]]; then
  die "Node.js 22 or newer is required (found $(node --version))"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/highlite-setup.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

download() {
  local url="$1"
  local destination="$2"

  mkdir -p "$(dirname "$destination")"
  if [[ -s "$destination" && "$FORCE" -eq 0 ]]; then
    info "Using existing $(basename "$destination")"
    return
  fi

  info "Downloading $(basename "$destination")"
  rm -f "$destination.part"
  curl -fL --retry 5 --retry-delay 2 -o "$destination.part" "$url"
  mv "$destination.part" "$destination"
}

info "Repository: $REPO_ROOT"
info "Parakeet cache: $PARAKEET_DIR"

if [[ ! -x "$PARAKEET_BIN_DIR/parakeet-cli" || "$FORCE" -eq 1 ]]; then
  parakeet_url="https://github.com/mudler/parakeet.cpp/releases/download/${PARAKEET_VERSION}/${PARAKEET_ASSET}"
  archive="$PARAKEET_DIR/$PARAKEET_ASSET"
  download "$parakeet_url" "$archive"

  mkdir -p "$tmp_dir/parakeet" "$PARAKEET_BIN_DIR"
  tar -xzf "$archive" -C "$tmp_dir/parakeet"
  parakeet_binary="$(find "$tmp_dir/parakeet" -type f -name parakeet-cli -perm -111 | head -n 1)"
  if [[ -z "$parakeet_binary" ]]; then
    parakeet_binary="$(find "$tmp_dir/parakeet" -type f -name parakeet-cli | head -n 1)"
  fi
  [[ -n "$parakeet_binary" ]] || die "the Parakeet archive did not contain parakeet-cli"
  install -m 0755 "$parakeet_binary" "$PARAKEET_BIN_DIR/parakeet-cli"
  xattr -d com.apple.quarantine "$PARAKEET_BIN_DIR/parakeet-cli" 2>/dev/null || true
else
  info "Using existing parakeet-cli"
fi

model_path="$PARAKEET_DIR/$MODEL_NAME"
model_url="https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/${MODEL_NAME}"
download "$model_url" "$model_path"

model_size="$(stat -f%z "$model_path" 2>/dev/null || echo 0)"
if [[ "$model_size" -lt 50000000 ]]; then
  die "$model_path looks incomplete ($model_size bytes); re-run with --force"
fi

info "Checking the Parakeet binary and model"
"$PARAKEET_BIN_DIR/parakeet-cli" info "$model_path" >/dev/null 2>&1 ||
  die "parakeet-cli could not load the model (Gatekeeper, an unsupported macOS version, or a bad download)"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  info "Installing workspace dependencies"
  (cd "$REPO_ROOT" && pnpm install)

  info "Building the SDK"
  (cd "$REPO_ROOT" && pnpm build)

  info "Building the compiler and relay"
  (cd "$REPO_ROOT" && pnpm build:rust)
fi

compiler="$REPO_ROOT/target/release/highlite-compiler"
[[ -x "$compiler" ]] || die "the compiler was not built at $compiler"
relay="$REPO_ROOT/target/release/highlite-relay"
[[ -x "$relay" ]] || die "the relay was not built at $relay"
"$relay" --help >/dev/null || die "the relay binary could not start at $relay"

if [[ "$VERIFY" -eq 1 ]]; then
  info "Running the Parakeet e2e"
  (
    cd "$REPO_ROOT"
    HIGHLITE_COMPILER="$compiler" \
      HIGHLITE_PARAKEET_BIN="$PARAKEET_BIN_DIR/parakeet-cli" \
      HIGHLITE_PARAKEET_MODEL="$model_path" \
      node scripts/parakeet-e2e.mjs
  )
fi

cat <<EOF

Setup complete.

  parakeet-cli : $PARAKEET_BIN_DIR/parakeet-cli
  model ($MODEL_LABEL) : $model_path
  compiler     : $compiler
  relay        : $relay
  SDK asset    : $REPO_ROOT/packages/sdk/dist/highlite.iife.js

Run the local ASR e2e:

  HIGHLITE_PARAKEET_BIN="$PARAKEET_BIN_DIR/parakeet-cli" \\
  HIGHLITE_PARAKEET_MODEL="$model_path" \\
  pnpm test:parakeet

Capture in another project:

  1. Copy the SDK asset to that project's public directory:
       cp "$REPO_ROOT/packages/sdk/dist/highlite.iife.js" /path/to/project/public/
  2. Add the dev-only script tag from the root README and call capture.export().
  3. Unpack the downloaded ZIP and compile it:
       "$compiler" bundle ./capture --out ./bundle \\
         --transcribe parakeet \\
         --parakeet "$PARAKEET_BIN_DIR/parakeet-cli" \\
         --parakeet-model "$model_path"

The bundle's summary.md, contact-sheet.png, and frames/ are ready for an agent.

Run the relay (create the env file once and replace the tokens and hosts):

  cp "$REPO_ROOT/crates/highlite-relay/relay.env.example" "$REPO_ROOT/relay.env"
  chmod 600 "$REPO_ROOT/relay.env"
  pnpm relay -- --env-file "$REPO_ROOT/relay.env"

The relay compiles uploaded sessions into the same bundle layout and can POST
signed completion webhooks; configure it entirely through relay.env.
EOF
