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
    // PB-9 evidence: TMPDIR is set to cacheDir in bootstrap_env; log the value std
    // actually resolves so the [U] premise is proven from the device, not from prose.
    log::info!("Picsh: temp_dir={}", std::env::temp_dir().display());

    // Rendering plan, M1 form of desktop `gpu_startup::plan`: honor `WGPU_BACKEND`
    // env passthrough (wgpu selects the backend from it when the instance is built),
    // otherwise Automatic. No marker/sentinel state yet (later milestone).
    let env_backend = std::env::var("WGPU_BACKEND").ok().filter(|v| !v.trim().is_empty());
    let plan_reason = env_backend.as_ref().map(|v| format!("WGPU_BACKEND={v} overrides the backend"));

    // eframe 0.36.2 epi.rs: android_app is "required on Android to correctly create
    // the event loop" (decision 010). AndroidApp is Clone (android-activity 0.6.1).
    let mut options = eframe::NativeOptions {
        renderer: eframe::Renderer::Wgpu,
        android_app: Some(app.clone()),
        ..Default::default()
    };
    // SU-9/F26 parity with gpu_startup.rs::configure: the device must be requested
    // through the upstream public helper `gpu_canvas::device_limits(adapter)` (egui's
    // base limits with the adapter's own texture and buffer sizes) rather than eframe's
    // default descriptor capped to egui's 8192 px texture (egui-wgpu 0.36.2
    // setup.rs:260-277). Decision 011 amendment: on api-31 the Vulkan SwiftShader
    // adapter reports max_storage_buffer_binding_size 0, so the helper's egui base
    // (128 MiB) would fail device creation before any window exists ("better than
    // allowed 0"; the desktop app would fail identically on that adapter). The shell
    // therefore clamps the helper's answer per hardware with wgpu's own public
    // `Limits::or_worse_values_from` (wgpu 30.0.1: "for clamping requests for values
    // beyond the supported limits") so no requested limit exceeds the chosen adapter.
    // Desktop-only pieces of gpu_startup::configure (Windows Intel DX12 default, Mac
    // indirect-validation skip, marker-on-adapter hook) have no Android counterpart
    // at M1 (decision 011).
    if let eframe::egui_wgpu::WgpuSetup::CreateNew(create) = &mut options.wgpu_options.wgpu_setup {
        create.device_descriptor = std::sync::Arc::new(|adapter| eframe::wgpu::DeviceDescriptor {
            label: Some("photocraft wgpu device"),
            required_limits: photocraft_ui_egui::gpu_canvas::device_limits(adapter).or_worse_values_from(&adapter.limits()),
            ..Default::default()
        });
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
                // Decision 011: what we request vs what upstream requires next to it.
                // The desktop app asks device_limits(adapter) (adapter's own texture
                // and buffer sizes); the shell additionally clamps every field down to
                // the chosen adapter (or_worse_values_from) because api-31's SwiftShader
                // reports storage binding 0: before this clamp the egui base request
                // failed device creation there ("better than allowed 0").
                let helper = photocraft_ui_egui::gpu_canvas::device_limits(&rs.adapter);
                let requested = helper.clone().or_worse_values_from(&rs.adapter.limits());
                let defaults = eframe::wgpu::Limits::default();
                let a = rs.adapter.limits();
                log::info!(
                    "Picsh: device request: Limits::default {{ max_texture_dimension_2d: {}, max_buffer_size: {}, max_storage_buffer_binding_size: {} }}; device_limits {{ max_texture_dimension_2d: {}, max_buffer_size: {} }}; requested {{ max_texture_dimension_2d: {}, max_buffer_size: {}, max_storage_buffer_binding_size: {} }}; adapter {{ max_texture_dimension_2d: {}, max_buffer_size: {}, max_storage_buffer_binding_size: {} }}",
                    defaults.max_texture_dimension_2d, defaults.max_buffer_size, defaults.max_storage_buffer_binding_size,
                    helper.max_texture_dimension_2d, helper.max_buffer_size,
                    requested.max_texture_dimension_2d, requested.max_buffer_size, requested.max_storage_buffer_binding_size,
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
