//! GPU adapter preflight ladder (decision 011 amendment 3, user option 5).
//!
//! `apps/photocraft/src/gpu_startup.rs` probes backends headless and hands a
//! validated device to the window; on Android the window comes from the eframe
//! event loop, so the probe runs here, before `run_native`: each rung creates a
//! real wgpu instance/adapter/device for exactly one backend, validates it with
//! a small buffer round trip, and the first validating rung is handed to eframe
//! via `egui_wgpu::WgpuSetup::Existing` (egui-wgpu 0.36.2 setup.rs: for
//! `Existing`, `WgpuSetup::new_instance()` returns `existing.instance.clone()`,
//! and the window surface is created from that same instance, so the surface,
//! adapter and device stay mutually consistent). A rung that fails here is
//! recorded verbatim and the next rung is tried; if every rung fails, eframe's
//! own default setup runs and would fail the same way the desktop app would.
//!
//! Crash safety (SU-8, minimal M1 form): each probe writes a marker file in the
//! config directory (upstream's `gpu-starting.json` name and location; the M1
//! content is the plain rung name, not the desktop JSON) and the marker is
//! cleared when the rung validates or the ladder ends. A stale marker left by a
//! previous start means that start died inside the driver during that probe, so
//! the rung is skipped this launch. An advisory `File::try_lock` is held for the
//! whole ladder, so two shell processes must not skip each other's rungs (the
//! desktop marker lock does the same). M1 limitation, recorded in decision 011:
//! a hard crash AFTER a rung validated (surface creation, first frames) is not
//! covered yet; desktop's Sentinel owns that state machine.
//!
//! No async runtime is added: `pollster` is not on the shell's allowlist
//! (`scripts/scope-guard.sh`), eframe blocks on the very same request futures
//! with pollster itself, and native wgpu request futures complete promptly
//! (wgpu 30.0.1 `Device::noop` poll-onces `request_adapter`/`request_device`
//! with a noop waker). The executor below still waits properly on a real waker,
//! so a `Pending` first poll cannot spin or be missed.

use eframe::egui_wgpu::{WgpuSetup, WgpuSetupExisting};
use std::fs::{File, OpenOptions, TryLockError};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::task::{Context, Poll, Wake, Waker};

/// What the ladder decided for this launch.
pub struct Outcome {
    /// `Some(WgpuSetup::Existing)` when a rung validated - hand this to eframe.
    /// `None` keeps eframe's own default setup (no rungs to try, or all failed).
    pub setup: Option<WgpuSetup>,
    /// The validating rung's name (`"vulkan"`/`"gl"`), for System Info "Selected".
    pub selected: Option<&'static str>,
    /// Every skip/rejection reason in order, for logcat and System Info "Fallback".
    pub notes: Vec<String>,
}

/// Run the ladder. `config_dir` holds the probe marker (`None`: no marker duty);
/// `env_backend` is the trimmed `WGPU_BACKEND` value, if the user forced one.
pub fn run(config_dir: Option<&Path>, env_backend: Option<&str>) -> Outcome {
    let mut notes: Vec<String> = Vec::new();
    let (stale, mut marker) = Marker::open(config_dir);
    let rungs = rungs(env_backend, &mut notes);
    for &(name, backends) in &rungs {
        if stale.as_deref() == Some(name) {
            let reason = format!("a previous start died while starting on {name}");
            log::warn!("Picsh: gpu ladder: rung {name}: skipped: {reason}");
            notes.push(format!("{name}: skipped: {reason}"));
            continue;
        }
        marker.write(name);
        log::info!("Picsh: gpu ladder: probing {name}");
        match probe(name, backends) {
            Ok((instance, adapter, device, queue)) => {
                marker.clear();
                log::info!("Picsh: gpu ladder: selected {name}");
                return Outcome {
                    setup: Some(WgpuSetup::Existing(WgpuSetupExisting {
                        instance,
                        adapter,
                        device,
                        queue,
                    })),
                    selected: Some(name),
                    notes,
                };
            }
            Err(reason) => {
                log::warn!("Picsh: gpu ladder: rung {name}: rejected: {reason}");
                notes.push(format!("{name}: rejected: {reason}"));
            }
        }
    }
    marker.clear();
    if !rungs.is_empty() {
        log::warn!("Picsh: gpu ladder: all rungs rejected; using the default eframe setup");
        notes.push("all rungs rejected; using the default eframe setup".to_string());
    }
    Outcome { setup: None, selected: None, notes }
}

/// The rungs to try, in order: Vulkan then GL (desktop gpu_startup's ladder,
/// minus DX12/Metal which do not exist on Android). An env value the ladder has
/// no rung for is recorded and left to eframe's default setup.
fn rungs(env_backend: Option<&str>, notes: &mut Vec<String>) -> Vec<(&'static str, eframe::wgpu::Backends)> {
    match env_backend.map(str::trim).filter(|value| !value.is_empty()) {
        None => vec![
            ("vulkan", eframe::wgpu::Backends::VULKAN),
            ("gl", eframe::wgpu::Backends::GL),
        ],
        Some(value) => match value.to_ascii_lowercase().as_str() {
            "vulkan" => vec![("vulkan", eframe::wgpu::Backends::VULKAN)],
            "gles" | "opengl" | "gl" => vec![("gl", eframe::wgpu::Backends::GL)],
            "auto" => vec![
                ("vulkan", eframe::wgpu::Backends::VULKAN),
                ("gl", eframe::wgpu::Backends::GL),
            ],
            other => {
                log::warn!("Picsh: gpu ladder: WGPU_BACKEND={other} has no preflight rung; the default eframe setup handles it");
                notes.push(format!("WGPU_BACKEND={other} has no preflight rung; the default eframe setup handles it"));
                Vec::new()
            }
        },
    }
}

/// Create instance/adapter/device for one backend and validate them with a
/// buffer round trip. Every failure is returned as a string (wgpu's own
/// wording) for logcat and System Info; nothing here may panic the process -
/// the validation error scope catches what a panicking handler would have
/// caught, so a degenerate adapter is a clean rung rejection.
fn probe(
    name: &'static str,
    backends: eframe::wgpu::Backends,
) -> Result<(eframe::wgpu::Instance, eframe::wgpu::Adapter, eframe::wgpu::Device, eframe::wgpu::Queue), String> {
    // Instance construction mirrors egui-wgpu 0.36.2's own CreateNew descriptor
    // (setup.rs `without_display_handle`), pinned to this rung's backend so the
    // rungs stay isolated from each other.
    let instance = eframe::wgpu::Instance::new(eframe::wgpu::InstanceDescriptor {
        backends,
        flags: eframe::wgpu::InstanceFlags::from_build_config().with_env(),
        backend_options: eframe::wgpu::BackendOptions::from_env_or_default(),
        memory_budget_thresholds: eframe::wgpu::MemoryBudgetThresholds::default(),
        display: None,
    });
    let adapter = block_on(instance.request_adapter(&eframe::wgpu::RequestAdapterOptions {
        power_preference: eframe::wgpu::PowerPreference::HighPerformance,
        compatible_surface: None,
        force_fallback_adapter: false,
        apply_limit_buckets: false,
    }))
    .map_err(|e| format!("adapter request: {e}"))?;
    let info = adapter.get_info();
    log::info!(
        "Picsh: gpu ladder: rung {name}: adapter {} device_type {:?} backend {:?} driver {} {}",
        info.name, info.device_type, info.backend, info.driver, info.driver_info
    );
    // SU-9 unchanged: exactly what the desktop app would request for this
    // adapter (photocraft_ui_egui::gpu_canvas::device_limits); no clamp.
    let required_limits = photocraft_ui_egui::gpu_canvas::device_limits(&adapter);
    let (device, queue) = block_on(adapter.request_device(&eframe::wgpu::DeviceDescriptor {
        label: Some("Picsh gpu ladder device"),
        required_limits,
        ..Default::default()
    }))
    .map_err(|e| format!("device request: {e}"))?;
    round_trip(&device, &queue)?;
    Ok((instance, adapter, device, queue))
}

/// The rung's device must actually move data: write marker bytes into a
/// mapped-at-creation source buffer, GPU-copy them, map the target back and
/// compare. Validation errors (e.g. the api-31 SwiftShader Vulkan adapter's
/// "Buffer size 64 is greater than the maximum buffer size (0)") are captured
/// by the validation error scope instead of panicking.
fn round_trip(device: &eframe::wgpu::Device, queue: &eframe::wgpu::Queue) -> Result<(), String> {
    let scope = device.push_error_scope(eframe::wgpu::ErrorFilter::Validation);
    let direct = round_trip_ops(device, queue);
    let captured = block_on(scope.pop());
    match (direct, captured) {
        (Err(reason), _) => Err(reason),
        (Ok(()), Some(error)) => Err(format!("{error}")),
        (Ok(()), None) => Ok(()),
    }
}

fn round_trip_ops(device: &eframe::wgpu::Device, queue: &eframe::wgpu::Queue) -> Result<(), String> {
    const SIZE: u64 = 64;
    let mut bytes = [0u8; 64];
    for (i, byte) in bytes.iter_mut().enumerate() {
        *byte = (i as u8).wrapping_mul(37).wrapping_add(0x80);
    }
    let source = device.create_buffer(&eframe::wgpu::BufferDescriptor {
        label: Some("Picsh gpu ladder probe source"),
        size: SIZE,
        usage: eframe::wgpu::BufferUsages::COPY_SRC,
        mapped_at_creation: true,
    });
    {
        let mut view = source.get_mapped_range_mut(0..SIZE).map_err(|e| format!("mapped write: {e}"))?;
        (&mut *view).copy_from_slice(&bytes);
    }
    source.unmap();
    let target = device.create_buffer(&eframe::wgpu::BufferDescriptor {
        label: Some("Picsh gpu ladder probe target"),
        size: SIZE,
        usage: eframe::wgpu::BufferUsages::MAP_READ | eframe::wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&eframe::wgpu::CommandEncoderDescriptor {
        label: Some("Picsh gpu ladder probe encoder"),
    });
    encoder.copy_buffer_to_buffer(&source, 0, &target, 0, SIZE);
    queue.submit([encoder.finish()]);
    let mapped = Arc::new(AtomicBool::new(false));
    let flag = mapped.clone();
    target.map_async(eframe::wgpu::MapMode::Read, 0..SIZE, move |result| {
        flag.store(result.is_ok(), Ordering::Release);
    });
    device
        .poll(eframe::wgpu::PollType::wait_indefinitely())
        .map_err(|e| format!("poll: {e}"))?;
    if !mapped.load(Ordering::Acquire) {
        return Err("map callback did not fire while polling".to_string());
    }
    let view = target.get_mapped_range(0..SIZE).map_err(|e| format!("mapped read: {e}"))?;
    let ok = &*view == &bytes[..];
    drop(view);
    target.unmap();
    if !ok {
        return Err("the copied bytes do not match".to_string());
    }
    Ok(())
}

/// Single-threaded, std-only blocking executor for wgpu's native request
/// futures. A waker sets a flag behind a mutex and notifies a condvar; the
/// loop polls, then sleeps on the flag. Lock poisoning cannot abort the
/// probe: a poisoned mutex is unwrapped to its inner value (upstream-style
/// `PoisonError::into_inner`), since the critical sections are two
/// assignments whose state is recoverable by re-reading the flag.
fn block_on<F: Future>(future: F) -> F::Output {
    struct WakeFlag {
        set: Mutex<bool>,
        cv: Condvar,
    }
    impl WakeFlag {
        fn set_flag(&self) {
            let mut set = self.set.lock().unwrap_or_else(PoisonError::into_inner);
            *set = true;
            self.cv.notify_all();
        }
    }
    impl Wake for WakeFlag {
        fn wake(self: Arc<Self>) {
            self.set_flag();
        }
        fn wake_by_ref(self: &Arc<Self>) {
            self.set_flag();
        }
    }

    let mut future = std::pin::pin!(future);
    let flag = Arc::new(WakeFlag { set: Mutex::new(false), cv: Condvar::new() });
    let waker = Waker::from(flag.clone());
    let mut cx = Context::from_waker(&waker);
    loop {
        if let Poll::Ready(value) = future.as_mut().poll(&mut cx) {
            return value;
        }
        let mut set = flag.set.lock().unwrap_or_else(PoisonError::into_inner);
        while !*set {
            set = flag.cv.wait(set).unwrap_or_else(PoisonError::into_inner);
        }
        *set = false;
    }
}

/// The crash-safe probe marker: upstream's `gpu-starting.json` name and
/// location (apps/photocraft/src/gpu_startup.rs, config directory), minimal M1
/// content - the plain rung name. The whole ladder holds an advisory
/// `File::try_lock`; without the lock (missing dir, open error, or another
/// shell process holding it) nothing is written and nothing is skipped.
struct Marker {
    /// `None`: no config dir, open error, or lock busy - nothing is written.
    file: Option<File>,
    path: Option<PathBuf>,
}

impl Marker {
    /// Open the marker: (stale content of a previous start, if any, marker).
    fn open(config_dir: Option<&Path>) -> (Option<String>, Marker) {
        let Some(dir) = config_dir else {
            return (None, Marker { file: None, path: None });
        };
        let path = dir.join("gpu-starting.json");
        let dead = Marker { file: None, path: Some(path.clone()) };
        let mut file = match OpenOptions::new().read(true).write(true).create(true).truncate(false).open(&path) {
            Ok(file) => file,
            Err(e) => {
                log::warn!("Picsh: gpu ladder: cannot open the probe marker {}: {e}", path.display());
                return (None, dead);
            }
        };
        match file.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                log::info!("Picsh: gpu ladder: probe marker {} is locked by another shell process; its rung records are not consulted", path.display());
                return (None, dead);
            }
            Err(TryLockError::Error(e)) => {
                log::warn!("Picsh: gpu ladder: cannot lock the probe marker {}: {e}", path.display());
                return (None, dead);
            }
        }
        let mut text = String::new();
        let _ = file.read_to_string(&mut text);
        let stale = text.trim().is_empty().not().then(|| text.trim().to_string());
        (stale, Marker { file: Some(file), path: Some(path) })
    }

    /// Record the rung a probe is about to start (crash-safety point).
    fn write(&mut self, rung: &str) {
        let Some(file) = self.file.as_mut() else {
            return;
        };
        if let Err(e) = (|| -> std::io::Result<()> {
            file.seek(SeekFrom::Start(0))?;
            file.write_all(rung.as_bytes())?;
            file.set_len(rung.len() as u64)?;
            file.flush()
        })() {
            log::warn!("Picsh: gpu ladder: cannot write the probe marker: {e}");
        }
    }

    /// The ladder no longer needs crash safety (rung validated or all rejected).
    fn clear(&mut self) {
        if self.file.is_none() {
            return; // we never owned the marker; never touch the other process's file
        }
        if let Some(path) = &self.path {
            if let Err(e) = std::fs::remove_file(path) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    log::warn!("Picsh: gpu ladder: cannot clear the probe marker: {e}");
                }
            }
        }
        self.file = None;
        self.path = None;
    }
}
