# meetily calendar arming layer

Always-on launchd agent that watches your calendar and auto-records meetings with
`meetily-rec`. One ephemeral recorder per meeting; transcripts land in the vault.

```
launchd (every 60s) → poller.sh → [event active now?] → meetily-rec record … → vault/raw/meetings/<date>-<slug>/transcript.md
                            ↑
                      MEETILY_CAL_CMD  (pluggable calendar source, TSV output)
```

## Calendar source (pick one) — DECISION PENDING

The poller is source-agnostic: `MEETILY_CAL_CMD` is any command that prints today's
timed events as TSV `<start_epoch>\t<end_epoch>\t<title>`.

**Option A — macOS Calendar via EventKit (default in install.sh).** Lightest: no
OAuth, no API keys. Reads Calendar.app, so any Google/iCloud/Exchange calendar that
*syncs into macOS Calendar.app* is visible. Needs: (1) your work calendar added to
Calendar.app (System Settings → Internet Accounts), (2) one-time Calendar permission
grant. `meetily-cal-events.swift` is compiled and wrapped in a signed `.app` (TCC
needs the Info.plist usage string).

**Option B — Google Calendar API via gcalcli.** Works regardless of macOS Calendar
sync; one-time OAuth. Install `gcalcli`, then set:
```bash
# ~/.local/share/meetily-rec/meetily-cal-events
#!/bin/bash
gcalcli --nocolor agenda "$(date +%Y-%m-%d) 00:00" "$(date +%Y-%m-%d) 23:59" --tsv \
  | awk -F'\t' 'NR>0 { /* convert start/end to epoch */ }'   # see gcalcli --tsv fields
```
(gcalcli `--tsv` emits start/end date+time columns; convert with `date -j -f`.)

## Install

```bash
./install.sh            # compile reader, install + load the LaunchAgent
./install.sh uninstall  # remove it
```

⚠️ **Do not install until the live `record` test confirms capture works.**

## Permissions (one-time)

- **meetily-rec.app**: Microphone + Screen Recording (for system audio). Grant by
  running it once via `open meetily-rec.app --args record …` and approving prompts,
  or approve when the poller first launches it.
- **meetily-cal-events.app**: Calendar. Approve on first run.
- Grants attach to the **bundle identity**; ad-hoc signing changes identity per
  rebuild, so re-grant after repackaging (or use a stable self-signed cert).

## Tunables (env vars; set in the LaunchAgent or poller)

| Var | Default | Meaning |
|---|---|---|
| `MEETILY_REC_BIN` | `…/dist/meetily-rec.app/Contents/MacOS/meetily-rec` | recorder binary |
| `MEETILY_CAL_CMD` | `~/.local/share/meetily-rec/meetily-cal-events` | event source (TSV) |
| `MEETILY_VAULT_MEETINGS` | `~/opensource/vault/raw/meetings` | output root |
| `MEETILY_LEAD` | `60` | start up to N s before event |
| `MEETILY_MIN_REMAIN` | `120` | skip if < N s remain |

## Behavior notes

- Locks (in `~/.local/state/meetily-rec/`): a **global single-recorder lock** (never two recorders at
  once — `meetily start` and the poller both respect it) + a **per-occurrence `rec_<key>.done`** marker
  written on successful completion, so a meeting that silence-stops mid-window is not re-armed. Stale
  markers (>2 days) are auto-pruned.
- Recording runs for the event's remaining duration (`--max-seconds`); ends on time
  even if the meeting overruns. Early-end leaves a slightly long recording (harmless).
- All-day events are skipped.
- Logs: `~/.local/state/meetily-rec/poller.log` and `rec_<key>.log` per meeting.
