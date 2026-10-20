# Decision 010 — `NativeOptions.android_app` must be set for the Android eframe event loop

- Date: 2026-10-20
- Status: decided
- Related: decision 006 (entry wiring), M1-4b/M1-7

## Question

Does `eframe::run_native` on Android need the `AndroidApp` handle passed through
`NativeOptions.android_app`, given that `android_main` already consumes it?

## Sources

- `eframe 0.36.2` `src/epi.rs` (crates.io tarball of the pinned version, read 2026-10-20):
  field `pub android_app: Option<winit::platform::android::activity::AndroidApp>` —
  doc comment: *"This value is required on Android to correctly create the event
  loop. See `EventLoopBuilder::build` and `with_android_app` for details."*
- `android-activity 0.6.1` `src/lib.rs` (same method): `#[derive(Debug, Clone)] pub struct AndroidApp` — the handle is `Clone`, so `run(app)` can pass `app.clone()` and keep owning the original.
- The agdk-eframe template referenced by the eframe-android-shell skill also sets `android_app: Some(app.clone())`.

## Decision

`android/src/lib.rs` constructs `NativeOptions` with `android_app: Some(app.clone())`
in addition to `renderer: eframe::Renderer::Wgpu`. Without this field, `eframe`
on Android either panics or fails to create its `winit` event loop at runtime —
the failure would only manifest in the emulator run (M1-7), not at compile time
(the field is `Option` and `Default` yields `None`).

## What invalidates this

An eframe release whose `epi.rs` no longer documents `android_app` as required
for Android, or a move of the wiring into `eframe` itself. Verify by reading
`epi.rs` of the pinned version whenever eframe's lock version changes.
