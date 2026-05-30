# Changelog — `meetily-rec` headless recorder (custom fork)

Branch `custom/meetily-rec-2026-05-29` (off upstream v0.3.0). All changes are additive /
feature-gated so the upstream GUI build stays intact and upstream pulls remain clean.

## 2026-05-30

### Added
- **`meetily-rec` headless binary** (`src/headless_rec.rs`, new `[[bin]]`): records mic + system
  audio with no Tauri GUI, finalizes `audio.mp4`, transcribes locally with Whisper
  (`large-v3-turbo`, Metal), writes `transcript.md` to the Obsidian vault. Subcommands:
  `record`, `transcribe`, `ensure-model`.
- **Overrun-aware stop**: `--stop-after-silence <s>` — keeps recording PAST the scheduled meeting
  end and stops only after `s` seconds of no speech (VAD-driven), bounded by `--max-seconds` hard
  cap. (Requested: meetings run over; don't cut them off.)
- **Calendar arming layer** (`headless/calendar/`): `poller.sh` (launchd, every 60s) spawns one
  ephemeral recorder per active meeting; `cal-source-gws.sh` (Google Calendar via the `gws-work`
  account, no new auth); `meetily-cal-events.swift` (EventKit alternative); launchd plist;
  `install.sh`.
- **Packaging** (`headless/package.sh`): assembles a windowless, ad-hoc-signed `meetily-rec.app`
  with mic/screen-recording usage strings + a bundled, PATH-independent ffmpeg.
- **`headless/build.sh`**: reproducible build (recreates gitignored stubs → cargo → package).
- **Manual control command** (`headless/meetily.sh` → `~/.local/bin/meetily`): `meetily start [name]`
  records a surprise huddle via the bundle (reuses TCC grants), auto-stops on silence;
  `meetily stop [--wait]` stops early; `meetily status` shows state + recent meetings. Respects the
  single-recorder lock. (Renamed from the earlier `meet-now`/`meet-stop`.)
- **Lock hardening** (`poller.sh`): global single-recorder lock (no two recorders at once for
  overlapping/double-booked meetings) + a per-occurrence `.done` marker written on successful
  completion (so a meeting that silence-stops mid-window is NOT re-armed on the next poll).
- **`MEETILY_DRY_RUN`** mode in `poller.sh` (validate arming without recording / debugging).
- **`/today` integration** (in the personal `today` skill, not this repo): surfaces recorded
  transcripts (transcript without `summary.md` = pending) + `/today meeting <slug|latest>` to
  summarize on demand and route action items → tickets / decisions → learnings.

### Shipped
- Installed live (launchd agent loaded, gws-work source, mic+screen TCC granted). First real auto-
  record: Mon 2026-06-01 "TM India Retro". Old `/Applications/Meetily.app` removed (→ Trash).

### Changed (additive, upstream untouched)
- `src/audio/recording_saver.rs`: + `stop_and_save_headless()` (finalize without an `AppHandle`).
- `src/audio/recording_manager.rs`: + `save_recording_headless()`.
- `Cargo.toml`: + `[[bin]] meetily-rec`, + `headless` feature.
- `src/lib.rs`: `#[cfg(not(feature = "headless"))]` on `run()` so the headless build skips the GUI
  command surface.

### Validated
- Real-audio capture (mic + system "SAMSUNG", English+Hindi) → accurate transcript.
- Whisper path on Metal (M3 Pro), auto language detection, graceful CoreML-absent fallback.
- `gws-work` calendar query against the live Eightfold calendar; parser skips all-day + declined.
- Overrun/silence-stop arguments; full record→stop→transcribe loop.

### Build environment notes
- Requires full **Xcode** (dep `cidre` runs `xcodebuild`) + `sudo xcodebuild -runFirstLaunch`.
- `binaries/llama-helper-*` stub + `frontend/out/` stub are required at build time (recreated by
  `build.sh`; both are gitignored).
- Build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cargo build --bin meetily-rec --features headless`.
