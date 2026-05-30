#!/bin/bash
# meet-stop — gracefully stop the current recording (ad-hoc or calendar-armed).
# Sends SIGINT, which the recorder catches → finalizes audio.mp4 + transcribes + writes
# the transcript. Takes a few seconds to finish the transcription after it stops.
set -euo pipefail

if pgrep -f 'meetily-rec record' >/dev/null 2>&1; then
  pkill -INT -f 'meetily-rec record'
  echo "■ stopping — finalizing audio + transcribing (a few seconds)…"
  echo "  transcript lands under ~/opensource/vault/raw/meetings/ — then: /today meeting latest"
else
  echo "(no recording is currently running)"
fi
