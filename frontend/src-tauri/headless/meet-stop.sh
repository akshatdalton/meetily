#!/bin/bash
# meet-stop — gracefully stop the current recording (ad-hoc or calendar-armed).
# Sends SIGINT, which the recorder catches → finalizes audio.mp4 + transcribes locally
# + writes the transcript. Transcription runs AFTER stop and takes ~10-60s (it loads
# Whisper + transcribes the whole meeting), so the transcript appears a bit later —
# that's normal.
#
#   meet-stop          # stop, print where the transcript will land (returns immediately)
#   meet-stop --wait   # stop, then block until the transcript is written and print its path
set -uo pipefail
WAIT=0; [ "${1:-}" = "--wait" ] && WAIT=1
MEETINGS="$HOME/opensource/vault/raw/meetings"

if ! pgrep -f 'meetily-rec record' >/dev/null 2>&1; then
  echo "(no recording is currently running)"
  exit 0
fi

pkill -INT -f 'meetily-rec record'
echo "■ stopping — finalizing the mp4 + transcribing locally (~10-60s; longer meetings take longer)."

if [ "$WAIT" = 1 ]; then
  printf "  waiting"
  for _ in $(seq 1 120); do
    pgrep -f 'meetily-rec record' >/dev/null 2>&1 || break
    sleep 2; printf "."
  done
  printf "\n"
  latest=$(ls -dt "$MEETINGS"/*/ 2>/dev/null | head -1)
  if [ -n "$latest" ] && [ -f "$latest/transcript.md" ]; then
    echo "  ✓ done → ${latest}transcript.md"
    echo "  summarize:  /today meeting latest"
  else
    echo "  done — check $MEETINGS (then /today meeting latest)"
  fi
else
  echo "  transcript will appear at: $MEETINGS/<today>-<name>/transcript.md"
  echo "  then summarize with:       /today meeting latest"
  echo "  (use 'meet-stop --wait' to block until the transcript is written.)"
fi
