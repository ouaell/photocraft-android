# Decision 006: Android entry wiring (M1-4b)

Date: 2026-10-20 — Milestone M1, task M1-4b.

## Question
How does the shell entry (`android/src/lib.rs` + `src/services.rs` + `src/jni_bridge.rs`)
behave at cold boot, given the desktop `apps/photocraft/src/main.rs` cannot run as-is?

## Sources
- `upstream/apps/photocraft/src/main.rs:375-454` (creation block: background_jobs, gpu_info,
  set_wgpu / DeviceHealth branches, fallback notice queue).
- `upstream/apps/photocraft/src/services.rs:198-205, 231-259, 377-447` (atomic writes,
  `save_through`, the closure set).
- `upstream/apps/photocraft/src/crash_guard.rs` (panic → `Err` contract).
- `upstream/crates/ui-egui/src/lib.rs:284-363` (service types).
- `upstream/crates/text/src/fonts.rs` (XDG_DATA_HOME scan), `app_dirs.rs` (PHOTOCRAFT_CONFIG_DIR).
- android-activity 0.6.1 `src/lib.rs` (dirs are `internal_data_path()` etc.; no getters; `#[derive(Debug, Clone)]` on AndroidApp).
- eframe 0.36.2 `epi.rs` (`NativeOptions.android_app`), rust-mobile/rust-android-examples `agdk-eframe/src/lib.rs` (`android_main` catch_unwind pattern).
- eframe-android-shell skill (panic hook via `log`, no panic escaping android_main).

## Decisions
1. **Entry**: `#[unsafe(no_mangle)] android_main(AndroidApp)` → `catch_unwind(AssertUnwindSafe(run))`
   → `install_logger()` (android_logger, tag `picsh`, regex feature off per decision 005) →
   resolve/create app dirs → `jni_bridge::bootstrap_env` → `eframe::run_native("Picsh", …)`.
   Logger before everything so panics/startup errors always land in logcat.
2. **Directories**: all under `AndroidApp::internal_data_path()` (the app-private `dataDir`):
   `config` (→`PHOTOCRAFT_CONFIG_DIR`, preferences.json), `files` (→`HOME`; `xdg/`
   subdirectory →`XDG_DATA_HOME`, with `xdg/fonts → /system/fonts` symlink, best-effort,
   so both bundled and system fonts are found), `cache` (→`TMPDIR`). Missing internal
   path ⇒ `Dirs::off()` placeholder paths + storage-off run (boot still logs; never aborts).
3. **Env is process-wide state set on the single main thread before eframe spawns any
   thread** (Rust 2024 `unsafe` `set_var` confined to `jni_bridge.rs` with invariant
   comments, BR-5). Same values re-set on activity recreation.
4. **Services (filesystem subset, desktop parity)**: `import`, `export`, `write`,
   `save_file` (worker-thread save with `SaveCtl`, exact `save_through` mirror), `encode_png`,
   `load_prefs`, `save_prefs`, `append_text`. All guarded by the shell's `guard()` clone of
   `crash_guard::guard`. Deferred to later milestones (later decisions): `file_dialog`
   (needs SAF pickers), clipboard, `open_url`, `screen_pick`, `system_theme`,
   `photoshop_shortcuts`, recovery/autosave block, `preset_store`, automation/*.
   Justification: those are each an Android API surface (SAF, Intents, JNI); M1 scope is
   cold boot + filesystem parity, and `Services` fields default to `None` without behavior drift.
5. **GPU plan, M1 form**: no marker/sentinel state (deserted on mobile until the sync
   milestone owns it); `WGPU_BACKEND` env passthrough recorded as `selected="env"` +
   `fallback="WGPU_BACKEND=<v> overrides the backend"` (desktop `gpu_startup::plan` wording);
   otherwise `selected="auto"`, no reason. Window adapter setup mirrors desktop main.rs:
   `set_adapter`, software-window fallback string, `set_wgpu(rs)` when hardware adapter ∧
   no `PHOTOCRAFT_CPU_CANVAS` ∧ prefs mode ≠ cpu (session defaults at creation; the saved
   prefs file loads on the first frame), else `DeviceHealth::watch(&rs.device)`.
   `PHOTOCRAFT_GPU_STARTUP_FAILURE` notice queueing mirrors desktop.
6. **Persistence**: no `persistence_path` (eframe's `storage_dir` is `None` on Android per
   eframe-android-shell skill). The persisted-state sanitization work belongs to the
   milestone that owns the persistence spec (M5); M1 launches start from defaults every time.
7. **Locale / RAM size**: not probed in M1 (needs JNI `getConfiguration` / ActivityManager);
   deferred to the jni_bridge milestone per PORT-SPEC SU-1. `PHOTOCRAFT_LOCALE` /
   `PHOTOCRAFT_RAM_MB` remain unset unless the CI matrix sets them.

## What would invalidate this
- android-activity renaming dir getters or eframe moving `android_app` (pinned-source check would fail).
- A build (M1-6) or emulator run (M1-7) showing a first-frames defect (R7 → new decision).
- A PORT-SPEC row mapping that requires a service we deferred (R16: reopen 006).
