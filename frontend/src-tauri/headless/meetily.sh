#!/bin/bash
# meetily — control the headless meeting recorder.
#
#   meetily start [name...]   start an ad-hoc recording (mic+system; auto-stops on silence)
#   meetily stop  [--wait]    stop the current recording (finalize + transcribe)
#   meetily status            is a recording running? + calendar-agent state + recent meetings
#
# Calendar meetings record automatically via launchd. Manual recordings respect the same
# single-recorder lock as the poller: only ONE recording runs at a time.
set -uo pipefail

APP="${MEETILY_REC_APP:-$HOME/opensource/meetily/frontend/src-tauri/dist/meetily-rec.app}"
VAULT="${MEETILY_VAULT_MEETINGS:-$HOME/opensource/vault/raw/meetings}"
STATE="${MEETILY_STATE_DIR:-$HOME/.local/state/meetily-rec}"
SILENCE="${MEETILY_SILENCE:-300}"
CAP="${MEETILY_ADHOC_CAP:-10800}"
mkdir -p "$STATE"

sub="${1:-}"; [ $# -gt 0 ] && shift

case "$sub" in
  start)
    name="${*:-adhoc}"
    if pgrep -f 'meetily-rec record' >/dev/null 2>&1; then
      echo "⚠ a recording is already running (calendar or manual) — 'meetily stop' it first."; exit 1
    fi
    [ -d "$APP" ] || { echo "✗ recorder not found at $APP (build: headless/build.sh)"; exit 1; }
    slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//'); [ -n "$slug" ] || slug=adhoc
    out="$VAULT/$(date +%F)-$slug"
    open "$APP" --args record --name "$name" --max-seconds "$CAP" --stop-after-silence "$SILENCE" --out "$out"
    echo "● recording '$name' (mic + system audio) → $out/transcript.md"
    echo "  stop:  meetily stop       (or it auto-stops ${SILENCE}s after it goes quiet)"
    ;;
  stop)
    wait=0; [ "${1:-}" = "--wait" ] && wait=1
    if ! pgrep -f 'meetily-rec record' >/dev/null 2>&1; then echo "(no recording is running)"; exit 0; fi
    pkill -INT -f 'meetily-rec record'
    echo "■ stopping — finalizing + transcribing locally (~10-60s; longer meetings take longer)…"
    if [ "$wait" = 1 ]; then
      printf "  waiting"
      for _ in $(seq 1 120); do pgrep -f 'meetily-rec record' >/dev/null 2>&1 || break; sleep 2; printf "."; done
      printf "\n"
      latest=$(ls -dt "$VAULT"/*/ 2>/dev/null | head -1)
      [ -n "$latest" ] && echo "  ✓ done → ${latest}transcript.md" || echo "  done — check $VAULT"
      echo "  summarize:  /today meeting latest"
    else
      echo "  transcript → $VAULT/<today>-<name>/transcript.md   then: /today meeting latest"
      echo "  ('meetily stop --wait' blocks until the transcript is written.)"
    fi
    ;;
  status)
    if pgrep -fl 'meetily-rec record' >/dev/null 2>&1; then
      echo "● recording IN PROGRESS:"; pgrep -fl 'meetily-rec record' | sed 's/^/    /'
    else
      echo "○ idle (no recording running)"
    fi
    echo -n "calendar agent: "; launchctl list 2>/dev/null | grep -q meetily.poller && echo "loaded ✓" || echo "NOT loaded"
    echo "recent meetings in vault:"
    ls -dt "$VAULT"/*/ 2>/dev/null | head -5 | sed 's/^/    /' || echo "    (none yet)"
    ;;
  *)
    cat <<'USAGE'
meetily — headless meeting recorder
  meetily start [name]    start an ad-hoc recording (auto-stops on silence)
  meetily stop [--wait]   stop the current recording (finalize + transcribe)
  meetily status          is it recording? + calendar-agent state + recent meetings
Calendar meetings record automatically (launchd). Only one recording runs at a time.
USAGE
    [ -z "$sub" ] && exit 0 || exit 2
    ;;
esac
