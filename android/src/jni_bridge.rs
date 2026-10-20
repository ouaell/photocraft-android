//! The single place the shell writes process environment variables (BR-5).
//!
//! `std::env::set_var` is `unsafe` in Rust 2024: it mutates process-wide state
//! that other threads may read. Invariant: `bootstrap_env` runs exactly once per
//! `android_main` entry, on the GameActivity main thread, BEFORE eframe spawns
//! its render/worker threads, and no other thread of this process exists yet
//! (winit/eframe are created inside `eframe::run_native`, which `bootstrap_env`
//! returns before). All values are JVM-validated filesystem paths from
//! `android-activity`, so no embedded NUL or invalid name reaches the setter.

use crate::services::Dirs;
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

/// SAFETY: happens on the single GameActivity main thread before any other
/// thread of this process is spawned (module docs); names are compile-time
/// literals without NUL; values come from `AndroidApp`'s JVM-validated paths.
/// Re-running on activity recreation sets the same values, never interleaved
/// with another writer.
fn set(name: &str, value: &Path) {
    unsafe { std::env::set_var(name, value) };
}
