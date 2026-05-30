#!/bin/bash
# meetily calendar source — Google Calendar via the `gws` CLI (the "gws-work" account).
# Prints today's TIMED events as TSV:  <start_epoch>\t<end_epoch>\t<title>
#
# `gws-work` is the shell alias `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws-eightfold gws`.
# launchd can't use shell aliases, so we set that env var explicitly here. The OAuth token
# is already cached in that config dir, so this runs unattended (no browser prompt).
set -uo pipefail

CFG="${MEETILY_GWS_CONFIG_DIR:-$HOME/.config/gws-eightfold}"
CAL="${MEETILY_GWS_CALENDAR:-primary}"

today=$(date +%Y-%m-%d)
tomorrow=$(date -v+1d +%Y-%m-%d)
off=$(date +%z); off="${off:0:3}:${off:3:2}"   # +0530 -> +05:30 (RFC3339)

GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CFG" gws calendar events list \
  --params "{\"calendarId\":\"$CAL\",\"timeMin\":\"${today}T00:00:00${off}\",\"timeMax\":\"${tomorrow}T00:00:00${off}\",\"singleEvents\":true,\"orderBy\":\"startTime\",\"maxResults\":50}" \
  --format json 2>/dev/null \
| python3 -c '
import sys, json, datetime
def epoch(dt):
    return int(datetime.datetime.fromisoformat(dt.replace("Z", "+00:00")).timestamp())
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for ev in data.get("items", []):
    s, e = ev.get("start", {}), ev.get("end", {})
    sd, ed = s.get("dateTime"), e.get("dateTime")
    if not sd or not ed:        # skip all-day / malformed
        continue
    # skip events the user only sees but did not accept (declined)
    declined = any(a.get("self") and a.get("responseStatus") == "declined"
                   for a in ev.get("attendees", []) or [])
    if declined:
        continue
    title = (ev.get("summary") or "meeting").replace("\t", " ").replace("\n", " ").strip()
    try:
        print(f"{epoch(sd)}\t{epoch(ed)}\t{title}")
    except Exception:
        continue
'
