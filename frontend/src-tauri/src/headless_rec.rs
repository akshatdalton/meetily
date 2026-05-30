//! meetily-rec — headless, calendar-armable meeting recorder + Whisper transcriber.
//!
//! Reuses Meetily's proven audio capture (macOS CoreAudio process-tap for system audio
//! + cpal microphone, professional mixing) and the bundled `WhisperEngine`, with NO Tauri
//! GUI, NO built-in LLM summarizer, NO SQLite. It records one meeting, finalizes `audio.mp4`,
//! transcribes it locally with Whisper (multilingual), and writes a plain-text transcript
//! into the Obsidian vault for Claude to read later.
//!
//! Subcommands:
//!   record       --name <title> [--out <dir>] [--max-seconds N] [--language L] [--model M] [--models-dir D]
//!   transcribe   --in <audio_file> --out <dir> [--name N] [--language L] [--model M] [--models-dir D]
//!   ensure-model [--model M] [--models-dir D]
//!
//! Stop a `record` with Ctrl-C (SIGINT) or `--max-seconds`.
//! Output: <out>/transcript.md  (+ <out>/metadata.json). The audio.mp4 stays in
//! ~/Movies/meetily-recordings/<name>/ and is referenced by path (keeps the vault text-only).
//!
//! NOTE: capturing mic + system audio on macOS requires TCC permissions, which are only
//! granted to a signed .app bundle carrying Info.plist usage strings. Run this binary from
//! inside the windowless `meetily-rec.app` bundle (see scripts/), not as a bare `cargo run`.

use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};

use app_lib::audio::decoder::decode_audio_file;
use app_lib::audio::recording_manager::RecordingManager;
use app_lib::whisper_engine::WhisperEngine;

/// Default Whisper model — multilingual, Metal-accelerated, ~8x realtime.
const DEFAULT_MODEL: &str = "large-v3-turbo";
/// Transcribe in fixed 60s windows (16 kHz mono) — bounds memory and avoids
/// depending on the crate-private VAD chunker. Whisper's native window is 30s.
const WINDOW_SAMPLES: usize = 60 * 16_000;

fn models_dir_default() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("meetily-rec")
        .join("models")
}

fn vault_meetings_default() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("opensource/vault/raw/meetings")
}

/// lowercase, non-alphanumeric → single dash, trimmed.
fn slugify(s: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    out.trim_matches('-').to_string()
}

/// Minimal `--key value` argument lookup.
fn arg(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1).cloned())
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = env_logger::try_init();
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("");

    let models_dir = arg(&args, "--models-dir")
        .map(PathBuf::from)
        .unwrap_or_else(models_dir_default);
    let model = arg(&args, "--model").unwrap_or_else(|| DEFAULT_MODEL.to_string());
    // language: None => auto-detect + transcribe in the spoken language (multilingual).
    // "auto-translate" => translate to English. "en"/"es"/... => force that language.
    let language = arg(&args, "--language");

    match cmd {
        "record" => {
            let name = arg(&args, "--name").unwrap_or_else(|| "meeting".to_string());
            let date = chrono::Local::now().format("%Y-%m-%d").to_string();
            let out = arg(&args, "--out").map(PathBuf::from).unwrap_or_else(|| {
                vault_meetings_default().join(format!("{}-{}", date, slugify(&name)))
            });
            let max_seconds: Option<u64> = arg(&args, "--max-seconds").and_then(|s| s.parse().ok());
            let stop_after_silence: Option<u64> =
                arg(&args, "--stop-after-silence").and_then(|s| s.parse().ok());
            cmd_record(&name, &out, max_seconds, stop_after_silence, &models_dir, &model, language).await
        }
        "transcribe" => {
            let input = arg(&args, "--in")
                .map(PathBuf::from)
                .ok_or_else(|| anyhow!("transcribe requires --in <audio_file>"))?;
            let out = arg(&args, "--out")
                .map(PathBuf::from)
                .ok_or_else(|| anyhow!("transcribe requires --out <dir>"))?;
            let name = arg(&args, "--name").unwrap_or_else(|| {
                input
                    .file_stem()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| "transcript".to_string())
            });
            ensure_model(&models_dir, &model).await?;
            let text = transcribe_file(&input, &models_dir, &model, language).await?;
            write_outputs(&out, &name, &text, &input, None, &model)?;
            println!("{}", out.join("transcript.md").display());
            Ok(())
        }
        "ensure-model" => {
            ensure_model(&models_dir, &model).await?;
            println!("model ready: {} in {}", model, models_dir.display());
            Ok(())
        }
        _ => {
            eprintln!(
                "meetily-rec — headless meeting recorder + Whisper transcriber\n\n\
                 USAGE:\n  \
                 meetily-rec record --name <title> [--out <dir>] [--max-seconds N] [--language L]\n  \
                 meetily-rec transcribe --in <audio> --out <dir> [--name N] [--language L]\n  \
                 meetily-rec ensure-model [--model M]\n\n\
                 Options: --model (default {}), --models-dir, --language (default: auto-detect)\n\
                 Stop a recording with Ctrl-C or --max-seconds.",
                DEFAULT_MODEL
            );
            std::process::exit(2);
        }
    }
}

/// Record mic + system audio until Ctrl-C / max-seconds, finalize audio.mp4, transcribe, write vault outputs.
async fn cmd_record(
    name: &str,
    out: &Path,
    max_seconds: Option<u64>,
    stop_after_silence: Option<u64>,
    models_dir: &Path,
    model: &str,
    language: Option<String>,
) -> Result<()> {
    // Fetch the model up front so post-recording transcription is fast.
    ensure_model(models_dir, model)
        .await
        .context("ensuring whisper model is available")?;

    let mut mgr = RecordingManager::new();
    mgr.set_meeting_name(Some(name.to_string()));
    let stop_desc = match (max_seconds, stop_after_silence) {
        (Some(m), Some(s)) => format!(" — auto-stops after {}s of silence (hard cap {}s)", s, m),
        (None, Some(s)) => format!(" — auto-stops after {}s of silence", s),
        (Some(m), None) => format!(" — stops after {}s", m),
        (None, None) => String::new(),
    };
    eprintln!("● recording '{}' (mic + system audio). Ctrl-C to stop{}.", name, stop_desc);

    let mut seg_rx = mgr
        .start_recording_with_defaults_and_auto_save(true)
        .await
        .context(
            "failed to start recording — check microphone & screen-recording permission \
             (run inside the signed meetily-rec.app bundle, not bare `cargo run`)",
        )?;
    // Track the last time speech (a VAD segment) was observed so we can auto-stop after a
    // sustained SILENCE — i.e. keep recording THROUGH a scheduled-end overrun and only stop
    // once the meeting actually winds down. Also drains the channel so the pipeline's
    // transcription sender doesn't error.
    let last_activity = std::sync::Arc::new(std::sync::Mutex::new(std::time::Instant::now()));
    {
        let la = last_activity.clone();
        tokio::spawn(async move {
            while seg_rx.recv().await.is_some() {
                if let Ok(mut g) = la.lock() {
                    *g = std::time::Instant::now();
                }
            }
        });
    }

    let start = std::time::Instant::now();
    let hard_cap = max_seconds.map(std::time::Duration::from_secs);
    let silence = stop_after_silence.map(std::time::Duration::from_secs);
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(5));
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                eprintln!("\n■ stopping (Ctrl-C)");
                break;
            }
            _ = ticker.tick() => {
                let now = std::time::Instant::now();
                if let Some(cap) = hard_cap {
                    if now.duration_since(start) >= cap {
                        eprintln!("■ stopping (hard cap {}s reached)", cap.as_secs());
                        break;
                    }
                }
                if let Some(sil) = silence {
                    let la = last_activity.lock().map(|g| *g).unwrap_or(now);
                    if now.duration_since(la) >= sil {
                        eprintln!("■ stopping ({}s of silence — meeting wound down)", sil.as_secs());
                        break;
                    }
                }
            }
        }
    }

    // Capture duration BEFORE flushing (state is cleared during force-flush).
    let duration = mgr.get_active_recording_duration();
    mgr.stop_streams_and_force_flush()
        .await
        .context("stopping audio streams")?;
    let saved = mgr
        .save_recording_headless(duration)
        .await
        .context("finalizing audio.mp4")?;
    let meeting_folder = mgr.get_meeting_folder();
    drop(mgr);

    let audio_path = match saved {
        Some(p) => PathBuf::from(p),
        None => meeting_folder
            .as_ref()
            .map(|f| f.join("audio.mp4"))
            .ok_or_else(|| anyhow!("recording produced no audio file"))?,
    };
    eprintln!(
        "✓ audio saved: {} ({:.0}s)",
        audio_path.display(),
        duration.unwrap_or(0.0)
    );

    eprintln!("⤷ transcribing with whisper '{}' …", model);
    let text = transcribe_file(&audio_path, models_dir, model, language)
        .await
        .context("transcription failed")?;

    write_outputs(out, name, &text, &audio_path, duration, model)?;
    println!("{}", out.join("transcript.md").display());
    Ok(())
}

/// Ensure `ggml-<model>.bin` exists in `models_dir`, downloading it if missing.
async fn ensure_model(models_dir: &Path, model: &str) -> Result<()> {
    std::fs::create_dir_all(models_dir).ok();
    let model_file = models_dir.join(format!("ggml-{}.bin", model));
    if model_file.exists() {
        return Ok(());
    }
    eprintln!(
        "downloading whisper model '{}' (~1.6GB, first run only) → {}",
        model,
        models_dir.display()
    );
    let engine = WhisperEngine::new_with_models_dir(Some(models_dir.to_path_buf()))
        .context("init whisper engine for download")?;
    engine.discover_models().await.ok();
    let cb: Option<Box<dyn Fn(u8) + Send>> = Some(Box::new(|p| {
        eprint!("\r  {}%   ", p);
    }));
    engine
        .download_model(model, cb)
        .await
        .with_context(|| format!("downloading whisper model '{}'", model))?;
    eprintln!("\r  download complete       ");
    Ok(())
}

/// Decode an audio file to 16 kHz mono, then transcribe it in fixed windows with Whisper.
async fn transcribe_file(
    input: &Path,
    models_dir: &Path,
    model: &str,
    language: Option<String>,
) -> Result<String> {
    // decode_audio_file is synchronous (symphonia) — run it off the async runtime.
    let input_buf = input.to_path_buf();
    let decoded = tokio::task::spawn_blocking(move || decode_audio_file(&input_buf))
        .await
        .context("audio decode task panicked")?
        .with_context(|| format!("decoding {}", input.display()))?;
    let samples = decoded.to_whisper_format(); // 16 kHz mono f32
    if samples.is_empty() {
        return Err(anyhow!("decoded audio is empty"));
    }

    let engine = WhisperEngine::new_with_models_dir(Some(models_dir.to_path_buf()))
        .context("init whisper engine")?;
    engine.discover_models().await.context("discovering models")?;
    engine
        .load_model(model)
        .await
        .with_context(|| format!("loading whisper model '{}'", model))?;

    let total = (samples.len() + WINDOW_SAMPLES - 1) / WINDOW_SAMPLES;
    let mut text = String::new();
    for (i, chunk) in samples.chunks(WINDOW_SAMPLES).enumerate() {
        eprint!("\r  transcribing window {}/{} …", i + 1, total);
        let part = engine
            .transcribe_audio(chunk.to_vec(), language.clone())
            .await
            .with_context(|| format!("transcribing window {}", i + 1))?;
        let part = part.trim();
        if !part.is_empty() {
            if !text.is_empty() {
                text.push(' ');
            }
            text.push_str(part);
        }
    }
    eprintln!("\r  transcribed {} window(s)              ", total);
    Ok(text)
}

/// Write transcript.md + metadata.json into the vault meeting directory.
fn write_outputs(
    out: &Path,
    name: &str,
    text: &str,
    audio_path: &Path,
    duration: Option<f64>,
    model: &str,
) -> Result<()> {
    std::fs::create_dir_all(out).with_context(|| format!("creating output dir {}", out.display()))?;
    let now = chrono::Local::now();
    let dur_str = duration
        .map(|d| format!("{:.0}", d))
        .unwrap_or_else(|| "unknown".to_string());
    let body = if text.is_empty() {
        "_(no speech transcribed)_"
    } else {
        text
    };

    let md = format!(
        "---\n\
         meeting: {name}\n\
         date: {date}\n\
         duration_seconds: {dur}\n\
         audio: {audio}\n\
         model: {model}\n\
         source: meetily-rec\n\
         transcribed_at: {ts}\n\
         ---\n\n\
         # {name}\n\n\
         _{date} · {dur}s · audio: `{audio}`_\n\n\
         ## Transcript\n\n\
         {body}\n",
        name = name,
        date = now.format("%Y-%m-%d %H:%M"),
        dur = dur_str,
        audio = audio_path.display(),
        model = model,
        ts = now.to_rfc3339(),
        body = body,
    );
    std::fs::write(out.join("transcript.md"), md).context("writing transcript.md")?;

    let meta = serde_json::json!({
        "meeting": name,
        "date": now.to_rfc3339(),
        "duration_seconds": duration,
        "audio_file": audio_path.to_string_lossy(),
        "model": model,
        "source": "meetily-rec",
    });
    std::fs::write(
        out.join("metadata.json"),
        serde_json::to_string_pretty(&meta)?,
    )
    .context("writing metadata.json")?;
    Ok(())
}
