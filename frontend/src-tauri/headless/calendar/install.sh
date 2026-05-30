#!/bin/bash
# Install the meetily calendar arming layer (LaunchAgent + poller + calendar source).
#
#   ./install.sh                              # Google Calendar via gws-work (default)
#   MEETILY_CAL_SOURCE=eventkit ./install.sh  # macOS Calendar via EventKit instead
#   ./install.sh uninstall                    # unload + remove
#
# DO NOT run until the live `record` test has confirmed capture works.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.akshatdalton.meetily.poller"
SHARE="$HOME/.local/share/meetily-rec"
STATE="$HOME/.local/state/meetily-rec"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
SOURCE="${MEETILY_CAL_SOURCE:-gws}"

if [ "${1:-}" = "uninstall" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✓ uninstalled $LABEL (left $SHARE and $STATE in place)"
  exit 0
fi

mkdir -p "$SHARE" "$STATE" "$AGENTS"

# 1) Install the calendar source → $SHARE/meetily-cal-events (prints TSV: start\tend\ttitle).
case "$SOURCE" in
  gws)
    echo "→ source: Google Calendar via gws-work (token already cached — no new auth)"
    cp "$HERE/cal-source-gws.sh" "$SHARE/meetily-cal-events"
    chmod +x "$SHARE/meetily-cal-events"
    if "$SHARE/meetily-cal-events" >/dev/null 2>&1; then
      echo "  ✓ gws calendar query OK"
    else
      echo "  ⚠ gws query failed — check: gws-work calendar calendars list"
    fi
    ;;
  eventkit)
    echo "→ source: macOS Calendar via EventKit (needs a one-time Calendar permission grant)"
    swiftc -O "$HERE/meetily-cal-events.swift" -o "$SHARE/meetily-cal-events.bin"
    APP="$SHARE/meetily-cal-events.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
    cp "$SHARE/meetily-cal-events.bin" "$APP/Contents/MacOS/meetily-cal-events"
    cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>meetily-cal-events</string>
  <key>CFBundleIdentifier</key><string>com.akshatdalton.meetily-cal-events</string>
  <key>CFBundleExecutable</key><string>meetily-cal-events</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsUsageDescription</key><string>meetily reads your calendar to auto-record scheduled meetings.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>meetily reads your calendar to auto-record scheduled meetings.</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    cat >"$SHARE/meetily-cal-events" <<SH
#!/bin/bash
exec "$APP/Contents/MacOS/meetily-cal-events" "\$@"
SH
    chmod +x "$SHARE/meetily-cal-events"
    ;;
  *)
    echo "unknown MEETILY_CAL_SOURCE=$SOURCE (use: gws | eventkit)"; exit 1;;
esac

# 2) Install poller + LaunchAgent (rewrite placeholders to absolute paths).
cp "$HERE/poller.sh" "$SHARE/poller.sh"; chmod +x "$SHARE/poller.sh"
sed -e "s#__POLLER__#$SHARE/poller.sh#g" -e "s#__STATE__#$STATE#g" \
    "$HERE/com.akshatdalton.meetily.poller.plist" >"$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

# 3) Install the manual control command (meetily start/stop/status) to ~/.local/bin (on PATH).
mkdir -p "$HOME/.local/bin"
cp "$HERE/../meetily.sh" "$HOME/.local/bin/meetily"
chmod +x "$HOME/.local/bin/meetily"
rm -f "$HOME/.local/bin/meet-now" "$HOME/.local/bin/meet-stop"   # superseded by `meetily`

echo "✓ installed $LABEL (polls every 60s; source=$SOURCE)"
echo "  manual: meetily start [name] / meetily stop / meetily status   (ad-hoc huddles → vault → /today meeting latest)"
echo "  poller: $SHARE/poller.sh    logs: $STATE/poller.log"
echo
echo "ONE-TIME: grant Microphone + Screen Recording to meetily-rec.app (so launchd can"
echo "capture unattended) by running it once via 'open' and approving the prompts:"
echo "  open '$HOME/opensource/meetily/frontend/src-tauri/dist/meetily-rec.app' --args record --name perm-test --max-seconds 5 --out /tmp/perm-test"
