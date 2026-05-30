#!/bin/bash
# meetily calendar poller — invoked every 60s by launchd.
#
# Finds the calendar event active *right now* and, if it isn't already being
# recorded, spawns ONE ephemeral `meetily-rec record` for the remaining duration.
# One recorder process per meeting (dedup via a per-event pidfile). The recorder
# records → audio.mp4 → Whisper → transcript.md in the vault, then exits.
#
# Calendar source is pluggable: MEETILY_CAL_CMD must print today's events as TSV,
# one per line:   <start_epoch>\t<end_epoch>\t<title>
# (see meetily-cal-events.swift for the macOS Calendar/EventKit reader, or wire
#  gcalcli — see README.md). This script is source-agnostic.
set -uo pipefail

REC_BIN="${MEETILY_REC_BIN:-$HOME/opensource/meetily/frontend/src-tauri/dist/meetily-rec.app/Contents/MacOS/meetily-rec}"
CAL_CMD="${MEETILY_CAL_CMD:-$HOME/.local/share/meetily-rec/meetily-cal-events}"
VAULT_MEETINGS="${MEETILY_VAULT_MEETINGS:-$HOME/opensource/vault/raw/meetings}"
STATE_DIR="${MEETILY_STATE_DIR:-$HOME/.local/state/meetily-rec}"
LEAD="${MEETILY_LEAD:-60}"          # may start up to 60s before event start
MIN_REMAIN="${MEETILY_MIN_REMAIN:-120}"  # skip if <2min remain in the meeting
SILENCE="${MEETILY_SILENCE:-300}"   # auto-stop after this many seconds of NO speech (meeting wound down)
OVERRUN="${MEETILY_OVERRUN:-7200}"  # hard cap = scheduled-remaining + this, so meetings can RUN OVER the end time

mkdir -p "$STATE_DIR"
now=$(date +%s)

# Clean stale per-meeting markers (>2 days old) so they don't accumulate.
find "$STATE_DIR" -maxdepth 1 \( -name 'rec_*.done' -o -name 'rec_*.pid' \) -mtime +2 -delete 2>/dev/null || true

# GLOBAL single-recorder lock: never run two recorders at once (overlapping / double-booked
# meetings, or a manual `meetily start` already in progress). If anything is recording, skip
# all arming this cycle — record the active one, pick up the other when this one ends.
busy=0; pgrep -f 'meetily-rec record' >/dev/null 2>&1 && busy=1

[ -x "$REC_BIN" ] || { echo "$(date -Iseconds) ERROR recorder not found: $REC_BIN" >>"$STATE_DIR/poller.log"; exit 1; }
[ -x "$CAL_CMD" ] || command -v "$CAL_CMD" >/dev/null 2>&1 || { echo "$(date -Iseconds) ERROR cal source not found: $CAL_CMD" >>"$STATE_DIR/poller.log"; exit 1; }

"$CAL_CMD" 2>>"$STATE_DIR/poller.log" | while IFS=$'\t' read -r start end title; do
  [[ "$start" =~ ^[0-9]+$ ]] || continue
  [[ "$end" =~ ^[0-9]+$ ]] || continue
  [ -n "$title" ] || title="meeting"

  # active window is [start - LEAD, end)
  if [ "$now" -ge $((start - LEAD)) ] && [ "$now" -lt "$end" ]; then
    remain=$((end - now))
    [ "$remain" -lt "$MIN_REMAIN" ] && continue

    [ "$busy" = 1 ] && continue   # global lock: a recording is already in progress → one at a time

    key=$(printf '%s_%s' "$start" "$title" | shasum | cut -c1-12)
    # Per-occurrence lock: each meeting occurrence is recorded ONCE. The .done marker is
    # written only on successful completion (below), so a meeting that silence-stops
    # mid-window is NOT re-armed on the next poll.
    [ -f "$STATE_DIR/rec_${key}.done" ] && continue

    date_slug=$(date -r "$start" +%Y-%m-%d)
    slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
    out="$VAULT_MEETINGS/${date_slug}-${slug:-meeting}"

    # Hard cap = scheduled remaining + overrun buffer, so the meeting can run PAST its
    # scheduled end; the recorder actually stops once there's been SILENCE seconds of no
    # speech (meeting wound down), whichever comes first.
    cap=$((remain + OVERRUN))
    if [ "${MEETILY_DRY_RUN:-0}" = "1" ]; then
      echo "DRY-RUN would record '$title': --max-seconds $cap --stop-after-silence $SILENCE --out $out"
      echo "$(date -Iseconds) DRY-RUN '$title' (sched ${remain}s, cap ${cap}s) → $out" >>"$STATE_DIR/poller.log"
      continue
    fi
    # Spawn the recorder; on SUCCESSFUL completion (transcript written) drop a .done marker
    # so this occurrence is never re-armed. A failure leaves no marker → retried next poll.
    ( "$REC_BIN" record --name "$title" --max-seconds "$cap" --stop-after-silence "$SILENCE" --out "$out" \
        >"$STATE_DIR/rec_${key}.log" 2>&1 \
      && [ -f "$out/transcript.md" ] && touch "$STATE_DIR/rec_${key}.done" ) &
    echo $! >"$STATE_DIR/rec_${key}.pid"
    busy=1   # don't arm a second meeting in this same poll cycle
    echo "$(date -Iseconds) armed '$title' (sched ${remain}s, cap ${cap}s, stop-on-silence ${SILENCE}s) → $out (pid $!)" >>"$STATE_DIR/poller.log"
  fi
done
exit 0
