//! Picsh: PhotoCraft on Android - platform shell only, no app logic.
//!
//! M1 milestone: cold boot of the real `PhotocraftApp` through `eframe::run_native`
//! with the filesystem `Services` subset (PORT-SPEC U-D mirror of the desktop
//! `services.rs`); no dialogs yet (Android pickers land in a later milestone).
//! Entry wiring mirrors `apps/photocraft/src/main.rs` minus the desktop-only
//! pieces (titlebars, monitors, GPU marker/sentinel, pref-file pre-pass).

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

#[cfg(target_os = "android")]
mod jni_bridge;
#[cfg(target_os = "android")]
mod services;
mod guard;

use log::LevelFilter;

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
/// GameActivity entry (android-activity 0.6.1 calls this on its own main thread).
/// May be re-entered on activity recreation: the logger and env bootstrapping are
/// idempotent there.
fn android_main(app: winit::platform::android::activity::AndroidApp) {
    // Panic must never unwind into Java frames (eframe-android-shell skill).
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(app)));
    if outcome.is_err() {
        log::error!("Picsh: android_main panicked; the activity ends without an abort");
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

    // Rendering plan, M1 form of desktop `gpu_startup::plan`: honor `WGPU_BACKEND`
    // env passthrough (wgpu selects the backend from it when the instance is built),
    // otherwise Automatic. No marker/sentinel state yet (later milestone).
    let env_backend = std::env::var("WGPU_BACKEND").ok().filter(|v| !v.trim().is_empty());
    let plan_reason = env_backend.as_ref().map(|v| format!("WGPU_BACKEND={v} overrides the backend"));

    // eframe 0.36.2 epi.rs: android_app is "required on Android to correctly create
    // the event loop" (decision 010). AndroidApp is Clone (android-activity 0.6.1).
    let options = eframe::NativeOptions {
        renderer: eframe::Renderer::Wgpu,
        android_app: Some(app.clone()),
        ..Default::default()
    };
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
            // Desktop main.rs's GPU status block, M1 form (auto preference, no marker logic).
            let selected = if env_backend.is_some() { "env".to_string() } else { "auto".to_string() };
            let mut fallback = plan_reason;
            app.perf.gpu_info.preference = "auto".to_string();
            app.perf.gpu_info.selected = selected;
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
            Ok(Box::new(app))
        }),
    );
    match result {
        Ok(()) => log::info!("Picsh: eframe loop returned cleanly"),
        Err(e) => log::error!("Picsh: eframe run failed: {e}"),
    }
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
