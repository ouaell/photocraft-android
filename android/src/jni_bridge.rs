//! The single place the shell writes process environment variables (BR-5).
//!
//! `std::env::set_var` is `unsafe` in Rust 2024: it mutates process-wide state
//! that other threads may read. Invariant: `bootstrap_env` and `apply_asset_knobs`
//! run exactly once per `android_main` entry, on the GameActivity main thread,
//! BEFORE eframe spawns its render/worker threads, and no other thread of this
//! process exists yet. Values: JVM-validated filesystem paths from
//! `android-activity` and compile-time-safe constants; each key is matched
//! against a fixed allowlist, so nothing else reaches the setter. Re-running on
//! activity recreation re-sets the same values.

use crate::services::Dirs;
use std::ffi::CStr;
use std::path::Path;

/// Set the process environment the pinned upstream code reads at any later time:
/// `PHOTOCRAFT_CONFIG_DIR` (upstream `app_dirs.rs`), `HOME`, `TMPDIR` and
/// `XDG_DATA_HOME` (crates/text/src/fonts.rs scans `$XDG_DATA_HOME/fonts`),
/// plus the CPU-canvas ladder knobs the CI matrix sets itself
/// (`PHOTOCRAFT_CPU_CANVAS`, `WGPU_BACKEND`). Locale and RAM-size probes need
/// JNI APIs and stay unset until the later milestone (decision 006).
pub fn bootstrap_env(dirs: &Dirs) {
    set("PHOTOCRAFT_CONFIG_DIR", &dirs.config);
    set("HOME", &dirs.files);
    set("TMPDIR", &dirs.cache);
    set("XDG_DATA_HOME", &dirs.files.join("xdg"));
}

/// Behavior knobs for the emulator matrix (`docs/decisions/009-ci-env-knobs.md`):
/// delivered as an uncompressed asset (`picsh-knobs.txt`, one `KEY=VALUE` per
/// line) because a Zygote-spawned process cannot receive shell-set env vars in
/// CI. Keys outside the allowlist are logged and skipped, and the file is
/// optional (no knobs: a silent no-op).
pub fn apply_asset_knobs(app: &winit::platform::android::activity::AndroidApp) {
    const PREFIX: &CStr = c"picsh-knobs.txt";
    let manager = app.asset_manager();
    let Some(asset) = manager.open(PREFIX) else {
        return;
    };
    let mut asset = asset;
    let bytes = match asset.buffer() {
        Ok(bytes) => bytes,
        Err(e) => {
            log::warn!("Picsh: could not buffer the picsh-knobs.txt asset: {e}");
            return;
        }
    };
    for line in std::str::from_utf8(bytes).unwrap_or_default().lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            log::warn!("Picsh: picsh-knobs.txt line without '=' is skipped: {line}");
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        if !knob_allowed(key) {
            log::warn!("Picsh: picsh-knobs.txt key {key} is outside the knob allowlist; skipped");
            continue;
        }
        set(key, std::path::Path::new(value));
        log::info!("Picsh: asset knob {key}={value} applied");
    }
}

/// Only the enum knobs the emulator rungs rely on may come from the asset;
/// everything else stays compile-time or default (defense in depth: the asset
/// must never grow into a config file). `PHOTOCRAFT_TEST_CRASH` is the one-shot
/// forced-crash knob of the re-entry CI scenario (decision 011 amendment 3).
fn knob_allowed(key: &str) -> bool {
    matches!(
        key,
        "WGPU_BACKEND"
            | "PHOTOCRAFT_CPU_CANVAS"
            | "RUST_LOG"
            | "WGPU_VALIDATION_INDIRECT_CALL"
            | "PHOTOCRAFT_TEST_CRASH"
    )
}

/// SAFETY: happens on the single GameActivity main thread before any other
/// thread of this process is spawned (module docs); names are compile-time
/// literals or allowlisted operator keys; values come from `AndroidApp`'s
/// JVM-validated paths or the bundled uncompressed knob asset. Re-running on
/// activity recreation sets the same values, never interleaved with another
/// writer.
fn set(name: &str, value: &Path) {
    unsafe { std::env::set_var(name, value) };
}
