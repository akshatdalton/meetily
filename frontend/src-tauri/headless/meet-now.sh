#!/bin/bash
# meet-now — start an AD-HOC meeting recording (e.g. a surprise Slack huddle not on
# your calendar). Records mic + system audio, transcribes locally, writes to the vault.
# Auto-stops after ~5 min of silence; stop early with `meet-stop`.
#
#   meet-now [name...]      # default name: "adhoc"
#
# Launches via the meetily-rec.app BUNDLE (open), so it reuses the mic + screen-recording
# TCC grants you gave the bundle. (A bare shell run would attribute TCC to your terminal.)
set -euo pipefail

APP="${MEETILY_REC_APP:-$HOME/opensource/meetily/frontend/src-tauri/dist/meetily-rec.app}"
VAULT="${MEETILY_VAULT_MEETINGS:-$HOME/opensource/vault/raw/meetings}"
SILENCE="${MEETILY_SILENCE:-300}"
CAP="${MEETILY_ADHOC_CAP:-10800}"   # 3h hard-cap safety net

name="${*:-adhoc}"
slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
[ -n "$slug" ] || slug="adhoc"
out="$VAULT/$(date +%F)-${slug}"

[ -d "$APP" ] || { echo "✗ meetily-rec.app not found at $APP (build it: headless/build.sh)"; exit 1; }
if pgrep -f 'meetily-rec record' >/dev/null 2>&1; then
  echo "⚠ a recording is already running — 'meet-stop' to end it first. Not starting another."
  exit 1
fi

open "$APP" --args record --name "$name" --max-seconds "$CAP" --stop-after-silence "$SILENCE" --out "$out"
echo "● recording '$name' (mic + system audio)"
echo "  → transcript: $out/transcript.md"
echo "  stop early:   meet-stop      (else auto-stops ${SILENCE}s after it goes quiet)"
echo "  summarize:    /today meeting $(date +%F)-${slug}   (or: /today meeting latest)"
