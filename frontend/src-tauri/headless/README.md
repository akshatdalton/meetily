# meetily-rec — headless, calendar-armed meeting recorder

> Custom fork work on branch `custom/meetily-rec-2026-05-29`. **This is the master reference** —
> read it first when continuing this work in a new session.
> Full decision/learning history lives in the Obsidian vault:
> `~/opensource/vault/wiki/projects/meetily/initiatives/meetily-calendar-daemon/`
> (`charter.md`, `decisions.md`, `learnings.md`, `runbook.md`).

## What this is

A background tool that auto-records your meetings around your **Google Calendar** and writes a
local **transcript** into your vault — no GUI, no cloud. It reuses Meetily v0.3.0's proven Rust
audio capture (CoreAudio system-audio tap + cpal mic + mixing) and its bundled Whisper engine, but
runs headless so a scheduler can drive it. Built so **Claude can read/summarize your meetings** from
the vault on demand.

```
launchd (every 60s) ──► poller.sh ──► [meeting active now?] ──► meetily-rec record … (one per meeting)
                            ▲                                          │ mic + system audio
                     gws-work calendar                                 ▼
                     (cal-source-gws.sh)                        audio.mp4 ──► Whisper (Metal) ──► transcript.md
                                                                                                   │
                                                          ~/opensource/vault/raw/meetings/<date>-<slug>/
```

## The three layers

1. **Recorder** — `meetily-rec` (Rust bin, `src/headless_rec.rs`). `record` captures mic+system,
   finalizes `audio.mp4`, transcribes, writes `transcript.md`. Also `transcribe --in <file>` and
   `ensure-model`. Ships as a windowless signed `.app` (TCC needs a bundle).
2. **Arming** — `headless/calendar/` (launchd + `poller.sh` + a calendar source). Spawns one
   ephemeral recorder per meeting; see `calendar/README.md`.
3. **Vault + Claude** — transcripts land in `~/opensource/vault/raw/meetings/`; Claude summarizes on
   demand (e.g. via `/today`).

## Build

```bash
./build.sh            # debug (fast); ./build.sh release for optimized
```
Outputs the signed bundle at `../dist/meetily-rec.app`.

### Build gotchas (all handled by `build.sh`, but know them)
- **Full Xcode required** — dep `cidre` (system-audio tap) runs `xcodebuild`. Command Line Tools
  alone fail. After installing Xcode: `sudo xcodebuild -runFirstLaunch` (installs CoreSimulator;
  without it `cidre` fails). Build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **`headless` feature gates out `run()`** — the GUI `generate_handler!` won't compile via a bare
  bin build, and the recorder doesn't need it. Always `--features headless`.
- **Two gitignored stubs** (recreated by `build.sh`): `frontend/out/index.html` (satisfies
  `generate_context!`) and `binaries/llama-helper-aarch64-apple-darwin` (satisfies `tauri_build`'s
  externalBin check; we never run it). `binaries/ffmpeg-*` is auto-downloaded by `build.rs`.
- **ffmpeg is bundled into the `.app`** (`package.sh`) so it works without `$PATH` — required under
  launchd, whose minimal PATH lacks `/opt/homebrew/bin`.

## Install (go live)

```bash
# 1) Grant the BUNDLE mic + screen-recording (so launchd can capture unattended).
#    Run once via `open` so TCC attributes to the bundle, then approve the prompts:
open ../dist/meetily-rec.app --args record --name perm-test --max-seconds 8 --out /tmp/perm-test
#    Also enable "meetily-rec" under System Settings → Privacy & Security → Screen & System Audio Recording.

# 2) Install the calendar arming (no sudo!). Defaults to the gws-work Google Calendar source.
cd calendar && ./install.sh          # uninstall: ./install.sh uninstall
```

## How it survives a restart

- The **LaunchAgent** (`~/Library/LaunchAgents/com.akshatdalton.meetily.poller.plist`, `RunAtLoad`
  + `StartInterval 60`) is loaded automatically at **login** after every reboot — no action needed.
- The **gws OAuth token** is cached in `~/.config/gws-eightfold/` and auto-refreshes → calendar keeps
  working across reboots with no re-auth.
- **TCC grants** (mic, screen-recording) persist in the system TCC database across reboots.
- The Whisper model (`~/Library/Application Support/meetily-rec/models/`) and the `.app` are on disk.
- ⚠️ **Caveat — rebuilds, not restarts:** the `.app` is ad-hoc signed, so its identity changes when
  you rebuild/repackage. After a rebuild you must re-grant mic/screen TCC once. A plain restart does
  NOT require this. (If you `cargo clean`, also rebuild: `./build.sh` then re-grant.)

## Calendar source — `gws-work` (default)

`gws-work` = the shell alias `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws-eightfold gws`
(work = Eightfold). The poller can't use shell aliases, so `cal-source-gws.sh` sets that env var
explicitly and calls `gws calendar events list … --format json`, emitting TSV `start\tend\ttitle`
(skips all-day + declined events). Token is already cached → unattended. To switch to macOS Calendar
(EventKit) instead: `MEETILY_CAL_SOURCE=eventkit ./install.sh`. Details: `calendar/README.md`.

## Overrun handling (meetings that run long)

The recorder does **not** stop at the scheduled end. `poller.sh` passes
`--stop-after-silence 300 --max-seconds <scheduled + 7200>`, so it keeps recording until there have
been **5 minutes of no speech** (VAD-driven — the meeting actually wound down), with a 2-hour hard
cap as a safety net. Tune via `MEETILY_SILENCE` / `MEETILY_OVERRUN` (see `calendar/README.md`).

## File map

```
headless/
  README.md            ← this file (master reference)
  CHANGELOG.md         ← dated change log
  build.sh             ← reproducible build (stubs → cargo → package)
  package.sh           ← assemble + ad-hoc-sign meetily-rec.app (bundles ffmpeg)
  Info.plist           ← bundle Info.plist (mic/screen usage strings, LSUIElement)
  meetily-rec.entitlements
  calendar/
    poller.sh                 ← launchd brain: active meeting → spawn recorder (overrun-aware)
    cal-source-gws.sh         ← Google Calendar via gws-work (default source)
    meetily-cal-events.swift  ← macOS Calendar / EventKit source (alternative)
    com.akshatdalton.meetily.poller.plist
    install.sh                ← install/uninstall the LaunchAgent + source
    README.md                 ← calendar-layer details
```
Rust changes are in `../src/headless_rec.rs` (the bin) plus additive `*_headless` methods in
`../src/audio/recording_{saver,manager}.rs`, a `headless` feature in `../Cargo.toml`, and a
`#[cfg(not(feature = "headless"))]` on `run()` in `../src/lib.rs`.

## Extending (next session ideas)

- `/today` integration to surface new `raw/meetings/*/transcript.md` for on-demand summaries.
- Release build + swap the installed `.app` (then re-grant TCC once).
- Per-meeting summary generation (was deferred for v1 — Claude summarizes on demand instead).
- Speaker diarization (not in upstream Community Edition).
- Robustness: install the `.app` to a stable path so `cargo clean` can't break the poller.
