#!/bin/bash
# Assemble a windowless, ad-hoc-signed meetily-rec.app so macOS will grant
# microphone + system-audio (screen-recording) TCC permissions to the headless recorder.
#
# A bare CLI binary has no Info.plist, so macOS cannot show the permission prompts and
# capture returns silence. Wrapping it in a signed .app bundle fixes that.
#
# Usage:  ./package.sh [debug|release]   (default: debug)
# Build the binary first:  cargo build --bin meetily-rec --features headless [--release]
set -euo pipefail

PROFILE="${1:-debug}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_TAURI="$(cd "$HERE/.." && pwd)"
# The cargo target dir is at the WORKSPACE root (frontend/src-tauri is a workspace member),
# with a fallback to a per-package target dir just in case.
WS_ROOT="$(cd "$SRC_TAURI/../.." && pwd)"
BIN="$WS_ROOT/target/$PROFILE/meetily-rec"
[ -x "$BIN" ] || BIN="$SRC_TAURI/target/$PROFILE/meetily-rec"
APP="$SRC_TAURI/dist/meetily-rec.app"

if [ ! -x "$BIN" ]; then
  echo "✗ binary not found: $BIN"
  echo "  build it first:  cargo build --bin meetily-rec --features headless${PROFILE:+ ($PROFILE)}"
  exit 1
fi

echo "→ assembling $APP  (from $PROFILE binary)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/meetily-rec"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# Bundle a known-good ffmpeg NEXT TO the binary so the recorder finds it via
# find_ffmpeg_path priority-1 (current_exe dir) — no dependency on $PATH, which
# matters under launchd (its minimal PATH lacks /opt/homebrew/bin).
FFMPEG_SRC="$SRC_TAURI/binaries/ffmpeg-aarch64-apple-darwin"
if [ -x "$FFMPEG_SRC" ]; then
  cp "$FFMPEG_SRC" "$APP/Contents/MacOS/ffmpeg"
  echo "→ bundled ffmpeg from $FFMPEG_SRC"
else
  echo "⚠ no bundled ffmpeg at $FFMPEG_SRC; recorder will fall back to \$PATH ffmpeg"
fi

# Ad-hoc sign. No hardened runtime (--options runtime) so the bundled ffmpeg helper
# isn't rejected by library validation. Sign the inner ffmpeg first, then the bundle.
echo "→ ad-hoc codesigning (inner ffmpeg, then app)"
[ -f "$APP/Contents/MacOS/ffmpeg" ] && codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
codesign --force \
  --sign - \
  --entitlements "$HERE/meetily-rec.entitlements" \
  "$APP"
codesign --verify --verbose "$APP" || true

echo
echo "✓ built $APP"
echo
echo "NOTE: ad-hoc signing identity changes per rebuild, so macOS may re-prompt for"
echo "      permissions after each repackage. For persistent grants, sign with a stable"
echo "      self-signed certificate instead of '-'."
echo
echo "Test the WHISPER path (no permissions needed):"
echo "  \"$APP/Contents/MacOS/meetily-rec\" transcribe --in /tmp/meetily-smoke.wav --out /tmp/mrec-test"
echo
echo "Test a LIVE recording (TCC prompts appear on first launch; attribute to the bundle):"
echo "  open \"$APP\" --args record --name \"Test Meeting\" --max-seconds 30 --out /tmp/mrec-live"
echo "  # then read /tmp/mrec-live/transcript.md"
