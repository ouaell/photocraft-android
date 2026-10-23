//! Picsh: PhotoCraft on Android - platform shell only, no app logic.
//!
//! M1 milestone: cold boot of the real `PhotocraftApp` through `eframe::run_native`
//! with the filesystem `Services` subset (PORT-SPEC U-D mirror of the desktop
//! `services.rs`); no dialogs yet (Android pickers land in a later milestone).
//! Entry wiring mirrors `apps/photocraft/src/main.rs` minus the desktop-only
//! pieces (titlebars, monitors, pref-file pre-pass); the desktop GPU probe
//! ladder has its own Android counterpart in `gpu_ladder.rs` (decision 011
//! amendment 3), which hands the validated device to eframe.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

#[cfg(target_os = "android")]
mod gpu_ladder;
#[cfg(target_os = "android")]
mod jni_bridge;
#[cfg(target_os = "android")]
mod services;
mod guard;

use log::LevelFilter;

#[cfg(target_os = "android")]
use libc;

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
/// GameActivity entry (android-activity 0.6.1 calls this on its own main thread).
///
/// Re-entry (decision 011 amendment 3): winit allows exactly one event loop per
/// process, so a finished run (Back key, or a caught failure) cannot run eframe
/// again in the same process; this entry therefore ends the process explicitly
/// below, and Android starts the next activity launch in a fresh process with a
/// clean GPU ladder.
///
/// The run ends without manual state to flush: the preferences are written by
/// UPSTREAM itself, per frame, through `services.save_prefs` (pinned
/// `upstream/crates/ui-egui/src/prefs_ui.rs:427` -> `persist()`:466 ->
/// `write_prefs`:519), and the M1 shell wires no autosave service
/// (`services.autosave` is None - the pinned ui-egui autosave runs only where
/// that service is set). eframe's own persistence is NOT involved: upstream
/// implements no `eframe::App::save`, and eframe logs "Saving disabled: Failed
/// to find path to data_dir" on Android. A pending upstream save RETRY
/// (prefs_ui.rs:492-513) is lost by the exit - the write itself is atomic
/// (`services.rs` writes through a temp file), so only a failed write is at
/// risk, and the next launch re-persists the changed revision.
fn android_main(app: winit::platform::android::activity::AndroidApp) {
    // Panic must never unwind into Java frames (eframe-android-shell skill).
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(app)));
    if outcome.is_err() {
        log::error!("Picsh: android_main panicked; the activity ends without an abort");
    }
    log::info!("Picsh: android_main done; exiting the process for a clean next launch");
    libc::_exit(0);
}

/// The shell's app wrapper: it adds the Android Back key to the upstream app
/// and changes nothing else.
///
/// Android delivers Back as a key event (`KEYCODE_BACK` -> winit's
/// `NamedKey::BrowserBack` -> egui's `Key::BrowserBack`; the AGDK's
/// GameActivity hands the key to the game instead of letting the framework
/// finish the activity, so nothing ends the run on its own - decision 011
/// amendment 5). The app-level meaning of "the user asked to leave" is the
/// same as on the desktop, where closing the window asks the root viewport to
/// close (`egui::ViewportCommand::Close`). Upstream's close guard
/// (`discard_ui::guard_window_close`) then decides what leaving means: unsaved
/// work gets the prompt, and once leaving is settled the platform quit in
/// `Services::quit` ends the app (the shell's quit hook ends the process,
/// because on Android a closed eframe window does not end the app: winit's
/// Android backend never exits its event loop on its own).
struct PlatformApp {
    inner: photocraft_ui_egui::PhotocraftApp,
    /// Whether a Back press may still ask the app to close (cleared while the
    /// key is held, so a key repeat cannot ask twice in a row).
    back_armed: bool,
}

impl eframe::App for PlatformApp {
    fn logic(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        let held = ctx.input(|i| i.key_down(egui::Key::BrowserBack));
        if !held {
            self.back_armed = true;
        }
        if self.back_armed && ctx.input(|i| i.key_pressed(egui::Key::BrowserBack)) {
            self.back_armed = false;
            log::info!("Picsh: Back key pressed; asking the app to close");
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
        eframe::App::logic(&mut self.inner, ctx, frame);
    }

    fn ui(&mut self, ui: &mut egui::Ui, frame: &mut eframe::Frame) {
        eframe::App::ui(&mut self.inner, ui, frame);
    }

    fn raw_input_hook(&mut self, ctx: &egui::Context, raw_input: &mut egui::RawInput) {
        eframe::App::raw_input_hook(&mut self.inner, ctx, raw_input);
    }
}

#[cfg(target_os = "android")]
fn run(app: winit::platform::android::activity::AndroidApp) {
    // Knobs may include RUST_LOG, so they land before the logger binds its filter.
    jni_bridge::apply_asset_knobs(&app);
    install_logger();

    let dirs = match services::app_dirs(&app) {
        Ok(dirs) => dirs,
        Err(e) => {
            log::error!("Picsh: no internal data directory ({e}); storage is unavailable this run");
            services::Dirs::off()
        }
    };
    jni_bridge::bootstrap_env(&dirs);
    log::info!(
        "Picsh {} on Android: config={} files={} cache={}",
        env!("CARGO_PKG_VERSION"),
        dirs.config.display(),
        dirs.files.display(),
        dirs.cache.display()
    );
    // PB-9 evidence: TMPDIR is set to cacheDir in bootstrap_env; log the value std
    // actually resolves so the [U] premise is proven from the device, not from prose.
    log::info!("Picsh: temp_dir={}", std::env::temp_dir().display());

    // Rendering plan, M1 form of desktop `gpu_startup::plan`: honor `WGPU_BACKEND`
    // env passthrough (the ladder maps it to its rung list), otherwise Automatic.
    let env_backend = std::env::var("WGPU_BACKEND").ok().filter(|v| !v.trim().is_empty());
    let plan_reason = env_backend.as_ref().map(|v| format!("WGPU_BACKEND={v} overrides the backend"));

    // Decision 011 amendment 3 (user option 5): the adapter ladder runs BEFORE
    // eframe, headless - Vulkan, then GL, each with a real device validated by a
    // buffer round trip; the first validating rung is handed to eframe through
    // `WgpuSetup::Existing`, so the window runs on exactly the validated device.
    // Rejections are recorded verbatim for logcat and System Info, and the
    // crash-safe marker keeps a start that died inside a driver from blocking
    // the next one. The shell requests no lower limits than upstream (SU-9):
    // the preflight device request is exactly `gpu_canvas::device_limits`.
    let ladder = gpu_ladder::run(Some(&dirs.config), env_backend.as_deref());

    // eframe 0.36.2 epi.rs: android_app is "required on Android to correctly create
    // the event loop" (decision 010). AndroidApp is Clone (android-activity 0.6.1).
    let mut options = eframe::NativeOptions {
        renderer: eframe::Renderer::Wgpu,
        android_app: Some(app.clone()),
        ..Default::default()
    };
    // Hand off the validated setup when the ladder selected a rung; otherwise
    // eframe's default setup stands (upstream-identical failure mode: eframe's
    // own request would fail the same way and be recorded as a run failure).
    if let Some(setup) = ladder.setup.clone() {
        options.wgpu_options.wgpu_setup = setup;
    }
    log::info!("Picsh: run_native starts (WGPU_BACKEND={:?}, PHOTOCRAFT_CPU_CANVAS={:?})", env_backend, std::env::var_os("PHOTOCRAFT_CPU_CANVAS"));
    let result = eframe::run_native(
        "Picsh",
        options,
        Box::new(move |cc| {
            let services = services::native(&dirs);
            let mut app = photocraft_ui_egui::PhotocraftApp::new(photocraft_engine::Session::new(), services);
            // Long commands and file opens must never freeze the Android frame loop (#210);
            // PHOTOCRAFT_INLINE_JOBS stays available for CI debugging like on the desktop.
            app.background_jobs = std::env::var_os("PHOTOCRAFT_INLINE_JOBS").is_none();
            // Desktop main.rs's GPU status block: the ladder's selection is the
            // "Selected" line; the plan note plus every ladder skip/rejection is
            // the "Fallback" record (decision 011 amendment 3).
            let selected = ladder.selected.unwrap_or(if env_backend.is_some() { "env" } else { "auto" });
            let mut fallback_parts: Vec<String> = Vec::new();
            if let Some(reason) = plan_reason.clone() {
                fallback_parts.push(reason);
            }
            fallback_parts.extend(ladder.notes.iter().cloned());
            let mut fallback = (!fallback_parts.is_empty()).then(|| fallback_parts.join("; "));
            app.perf.gpu_info.preference = "auto".to_string();
            app.perf.gpu_info.selected = selected.to_string();
            app.perf.gpu_info.fallback = fallback.clone();
            app.perf.gpu_info.canvas = "cpu".to_string();
            let mode = app.session.prefs().performance.effective_rendering_mode();
            if let Some(rs) = cc.wgpu_render_state.clone() {
                app.perf.gpu_info.set_adapter(&rs.adapter.get_info());
                let got = rs.adapter.get_info();
                log::info!(
                    "Picsh: wgpu adapter {} device_type {:?} backend {:?} driver {} {}",
                    got.name, got.device_type, got.backend, got.driver, got.driver_info
                );
                // Decision 011 amendment 3: no clamp - the device was requested in
                // the preflight ladder with exactly gpu_canvas::device_limits(adapter)
                // (SU-9) and egui runs on that same device through WgpuSetup::Existing;
                // a degenerate adapter (api-31's SwiftShader Vulkan) is rejected by
                // the ladder, so no clamped device is ever created. When NO rung
                // validated, eframe created the device with its OWN descriptor
                // (egui's limits, not device_limits) - the log line says which of
                // the two it was, so the record cannot be misread.
                let helper = photocraft_ui_egui::gpu_canvas::device_limits(&rs.adapter);
                let defaults = eframe::wgpu::Limits::default();
                let a = rs.adapter.limits();
                log::info!(
                    "Picsh: device request: created_by={}; Limits::default {{ max_texture_dimension_2d: {}, max_buffer_size: {}, max_storage_buffer_binding_size: {} }}; device_limits {{ max_texture_dimension_2d: {}, max_buffer_size: {} }}; adapter {{ max_texture_dimension_2d: {}, max_buffer_size: {}, max_storage_buffer_binding_size: {} }}",
                    if ladder.setup.is_some() { "ladder (device_limits)" } else { "eframe default (no ladder rung validated)" },
                    defaults.max_texture_dimension_2d, defaults.max_buffer_size, defaults.max_storage_buffer_binding_size,
                    helper.max_texture_dimension_2d, helper.max_buffer_size,
                    a.max_texture_dimension_2d, a.max_buffer_size, a.max_storage_buffer_binding_size
                );
                let software_window = got.device_type == eframe::wgpu::DeviceType::Cpu;
                if software_window && mode != photocraft_engine::prefs::RenderingMode::Cpu {
                    app.perf.gpu_info.fallback = Some("No compatible hardware graphics adapter; using software graphics.".to_string());
                }
                if !software_window
                    && std::env::var_os("PHOTOCRAFT_CPU_CANVAS").is_none()
                    && mode != photocraft_engine::prefs::RenderingMode::Cpu
                {
                    app.set_wgpu(rs);
                } else {
                    // The window still draws with wgpu: record its errors instead of panicking.
                    let _ = photocraft_ui_egui::gpu_canvas::DeviceHealth::watch(&rs.device);
                }
            }
            fallback = app.perf.gpu_info.fallback.clone();
            let fallback_reason = std::env::var("PHOTOCRAFT_GPU_STARTUP_FAILURE").ok().or_else(|| {
                (app.perf.gpu_info.canvas == "cpu" && mode != photocraft_engine::prefs::RenderingMode::Cpu).then_some(fallback).flatten()
            });
            if let Some(reason) = fallback_reason {
                photocraft_ui_egui::gpu_status::queue_fallback_notice(&mut app, &reason);
            }
            // Help > System Info exactly as desktop gpu_status.rs renders it (English
            // by definition; gpu_status.rs:62-64). On the 320 px AVD menu automation for
            // Help is unreliable, so CI captures the same content from logcat instead:
            // fallback/lost state is already baked into the fields above at this point.
            for line in photocraft_ui_egui::gpu_status::system_info(&app) {
                log::info!("Picsh: SystemInfo: {line}");
            }
            maybe_test_crash(&dirs.config);
            Ok(Box::new(PlatformApp { inner: app, back_armed: true }))
        }),
    );
    match result {
        Ok(()) => log::info!("Picsh: eframe loop returned cleanly"),
        Err(e) => log::error!("Picsh: eframe run failed: {e}"),
    }
}

/// CI knob `PHOTOCRAFT_TEST_CRASH` (debug-only rungCrash asset, decision 011
/// amendment 3): after the ready evidence above (device request + System Info)
/// is logged, end the process the way a hard driver crash would, so the
/// crash-relaunch scenario proves the relaunch path. One-shot: the marker file
/// in the config directory is written BEFORE the panic, so the relaunch starts
/// without the knob's effect (uninstalling the app clears the marker).
/// `panic_any` keeps the payload greppable in logcat; the unwind is caught in
/// android_main, which then exits the process.
#[cfg(target_os = "android")]
#[allow(clippy::panic)]
fn maybe_test_crash(config_dir: &std::path::Path) {
    if std::env::var_os("PHOTOCRAFT_TEST_CRASH").is_none() {
        return;
    }
    let marker = config_dir.join("picsh-test-crash.txt");
    if marker.exists() {
        log::info!("Picsh: PHOTOCRAFT_TEST_CRASH already fired once (marker {}); staying up", marker.display());
        return;
    }
    if let Err(e) = std::fs::write(&marker, b"PHOTOCRAFT_TEST_CRASH\n") {
        // Without the marker the knob would fire again on the relaunch, and the
        // re-entry gate could never be green - so the crash is skipped instead.
        log::warn!("Picsh: could not write the crash marker {e}; the forced crash is skipped");
        return;
    }
    log::error!("Picsh: PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now");
    std::panic::panic_any("PHOTOCRAFT_TEST_CRASH");
}

/// Logcat routing for every `log` record of the shell and of the upstream crates.
/// `RUST_LOG` (set in CI matrices) refines per-target levels. Regex filter
/// directives stay off: android_logger runs with default features disabled
/// (decision 005).
#[cfg(target_os = "android")]
fn install_logger() {
    let mut filter = android_logger::FilterBuilder::new();
    if let Ok(v) = std::env::var("RUST_LOG") {
        if !v.trim().is_empty() {
            filter.parse(&v);
        }
    } else {
        filter.parse("debug,wgpu_core=warn,wgpu_hal=warn,naga=warn");
    }
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(LevelFilter::Debug)
            .with_tag("picsh")
            .with_filter(filter.build()),
    );
    std::panic::set_hook(Box::new(|info| {
        log::error!("Picsh: Rust panic: {info}");
    }));
}
