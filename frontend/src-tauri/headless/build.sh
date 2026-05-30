#!/bin/bash
# Reproducible build of the headless meetily-rec recorder + signed .app bundle.
#
#   ./build.sh            # debug build (fast)
#   ./build.sh release    # optimized build
#
# Prereqs (one-time): full Xcode (cidre needs xcodebuild) + `sudo xcodebuild -runFirstLaunch`,
# rustup, cmake (brew install cmake). See README.md "Build gotchas".
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"     # frontend/src-tauri/headless
ST="$(cd "$HERE/.." && pwd)"              # frontend/src-tauri
PROFILE="${1:-debug}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$DEVELOPER_DIR" ] || { echo "✗ Xcode not found at $DEVELOPER_DIR — cidre needs full Xcode"; exit 1; }
command -v cargo >/dev/null || { echo "✗ cargo not found — install rustup"; exit 1; }
command -v cmake >/dev/null || { echo "✗ cmake not found — brew install cmake (whisper-rs needs it)"; exit 1; }

# 1) Recreate the gitignored build stubs (see README.md "Build gotchas"):
#    generate_context!() in app_lib::run() needs frontendDist (../out) to exist at compile time.
mkdir -p "$ST/../out"
[ -f "$ST/../out/index.html" ] || printf '<!doctype html><title>meetily</title>meetily headless\n' > "$ST/../out/index.html"
#    tauri_build validates the llama-helper externalBin exists; we don't use it → tiny stub.
mkdir -p "$ST/binaries"
if [ ! -e "$ST/binaries/llama-helper-aarch64-apple-darwin" ]; then
  printf '#!/bin/sh\nexit 0\n' > "$ST/binaries/llama-helper-aarch64-apple-darwin"
  chmod +x "$ST/binaries/llama-helper-aarch64-apple-darwin"
fi
#    (binaries/ffmpeg-aarch64-apple-darwin is auto-downloaded by build.rs at build time.)

# 2) Build the headless binary. Metal auto-enabled on macOS; the GUI run() is gated out.
cd "$ST"
FLAGS=""; [ "$PROFILE" = "release" ] && FLAGS="--release"
echo "→ cargo build --bin meetily-rec --features headless $FLAGS"
cargo build --bin meetily-rec --features headless $FLAGS

# 3) Package the signed .app (bundles ffmpeg, ad-hoc sign). See package.sh.
"$HERE/package.sh" "$PROFILE"
echo "✓ build complete ($PROFILE) → $ST/dist/meetily-rec.app"
