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
