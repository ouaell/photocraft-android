---
name: eframe-android-shell
description: Use when writing, reviewing or debugging the Rust Android shell that wraps PhotocraftApp - android_main, eframe NativeOptions.android_app, GameActivity, soft keyboard/IME bridge, touch gesture arbitration, pen/mouse/keyboard forwarding, window insets, SAF file picker, text clipboard, lifecycle, Back, fonts and environment knobs. Contains verified facts about eframe 0.36.2, winit 0.30.13, egui 0.36.2 and android-activity 0.6.1 on Android.
---

# Rust shell around PhotocraftApp on Android

Facts below were read from the locked crate sources; items tagged **[U]** are not yet proven and are settled by the milestone named in `PLAN.md`. If this file disagrees with the source of the locked versions, the source wins.

## Entry and build
- eframe 0.36.2 features `android-game-activity` / `android-native-activity`; `NativeOptions.android_app: Option<AndroidApp>` is **required** (run fails without it); `App::raw_input_hook(&mut self, ctx, &mut RawInput)` is the injection point.
- android-activity 0.6.1 needs `androidx.games:games-activity:4.4.0` (mismatch = `UnsatisfiedLinkError`; do **not** enable Prefab). Recommended chain: Gradle project + `cargo ndk -t <abi> -o app/src/main/jniLibs/ build` + `./gradlew build`. `cargo-apk` cannot resolve AARs. Start from the official `rust-android-examples/agdk-eframe` layout and update versions from official docs (`android docs`).
- Build recipe parity (PORT-SPEC BR-1…7): `--release --locked`, `heif` feature, `CRAFT_FONTS_DIR` + `CRAFT_FONTS_REQUIRED=1`, upstream's `[profile.release]` copied (profiles are not inherited), NDK ≥ r28.

## What winit 0.30.13 does and does not do on Android
- Touch: Down/Up/Move/Cancel only; `Force::Normalized(pointer.pressure())`; **only the latest sample** per event (no historical/batched samples).
- **No** mouse hover/wheel/buttons (source: `_ => None // TODO mouse events`), no cursor icon, no min-size, no drag-and-drop, no modifier reporting.
- `set_ime_allowed(true/false)` calls `show/hide_soft_input`, but GameActivity **text-input events are not handled**; key events carry text only from the hardware key map.
- Back key arrives as `NamedKey::BrowserBack` → egui `Key::BrowserBack`.
All of these need Kotlin forwarders injected in `raw_input_hook` (PLAN C3b, C3c, C4, C6, C16).

## Soft keyboard recipe (be3 PR #149, merged 2026-09-25; unproven on a device at that time)
Read `AndroidApp::text_input_state()` in `about_to_wait`; send the **difference** as Text/Backspace/Enter events; GameTextInput starts with a **null text pointer** (abort in debug) unless `MainActivity` sets an empty state at creation; 64 KiB buffer — clear after ~1 KiB when not composing; `MainActivity` forwards Tab/Escape/arrows/Home/End/PgUp/PgDn/modifiers and Ctrl/Alt/Meta combos to native directly; a cancelled touch must not count as a tap. Ladder (PLAN C4): A winit as is → B GameTextInput diff bridge → C native `EditText` overlay.

## Touch → upstream navigation (verified)
The canvas reads: pan = `smooth_scroll_delta` + `Event::MouseWheel`; zoom = `zoom_delta()` (includes egui multi-touch pinch); rotate = `Event::Rotate`/`rotation_delta()` (includes multi-touch). Touch translation is **not** read, so the shell injects two-finger translation as `Event::MouseWheel(Point)`. egui-winit emulates the pointer from the **first** touch only, so a second finger must cancel/hold the first finger's pointer events (C3c) or the document gets painted during a pinch. Upstream's Windows shell already rewrites input in `raw_input_hook` (`fold_legacy_pinch`) — same mechanism.

## Lifecycle (verified, eframe 0.36.2)
On `suspended` eframe drops only the window/surface and emits Save; app, egui context and wgpu device persist; on `resumed` it recreates the window. So `set_wgpu(rs)` stays valid across pause/resume. Persistence needs an explicit `persistence_path` (eframe's default dir is `None` on Android) and the layout file must be sanitised first (`ui_state::sanitize` exists upstream because a bad file crash-loops startup).

## Environment knobs to set before any thread starts (upstream reads them)
`PHOTOCRAFT_CONFIG_DIR`, `PHOTOCRAFT_LOCALE` (from the system `LocaleList`), `PHOTOCRAFT_RAM_MB` (from `ActivityManager.MemoryInfo.totalMem`), plus `TMPDIR=<cacheDir>`, `HOME=<filesDir>`, `XDG_DATA_HOME=<filesDir>/xdg` with `fonts → /system/fonts` (the font scanner has no Android path). Rendering ladder knobs: `PHOTOCRAFT_CPU_CANVAS`, `PHOTOCRAFT_CPU_COMPOSE`.

## Rules for every JNI entry
Wrap in `catch_unwind` (panic must never unwind into Java frames); keep `unsafe` in `jni_bridge.rs`/`ime.rs` with an invariant comment per block; attach threads properly; local-reference frames in loops (see the vendored `rust-jni` and `rust-panic-safety` skills, and verify against official Android docs).

## Never
Edit `upstream/`; add a dependency on the web shell, `wasm-bindgen`, `web-sys`; add Compose/View UI; change what upstream decides — report it instead.
