---
name: android-ci-verification
description: Use when creating or running CI jobs, Android emulator tests, screenshot capture, logcat checks, red-to-green proofs, or gate evidence for the PhotoCraft Android port. Covers the KVM emulator runner, the official Android CLI commands for screenshots and input, the rendering matrix (Vulkan, GLES, forced CPU), the logcat oracle, and the evidence layout.
---

# CI and evidence for the Android port

Commands marked **[verify]** must be checked against the official docs (`android docs search`, the action's README) at M1 before being relied on.

## Runner
- GitHub-hosted Linux runners support hardware-accelerated Android emulation (GitHub changelog 2024-04-02) after enabling KVM with a udev rule for `/dev/kvm` **[verify exact lines in the changelog]**. First CI job: prove `/dev/kvm` is usable; if not, stop and report (do not fall back silently to slow software emulation).
- `reactivecircus/android-emulator-runner@v2` runs a script against an emulator; its default GPU mode is `swiftshader_indirect` (software). Pin the action by commit SHA **[verify inputs: api-level, arch, target, profile, script, emulator-options]**.

## Official Android CLI (names verified from developer.android.com)
`android emulator create|start|stop|list|remove`, `android run`, `android install`, `android screen capture`, `android screen resolve`, `android input tap|swipe|scroll|key|text`, `android layout`, `android docs search|fetch`, `android sdk install|list|update`, `android skills add|find|list|update`, `android device remote …` (remote real devices, Firebase-backed, not needed before M7).
- `android layout` reports the **Android view hierarchy**. Our UI is egui drawn on one native surface, so it will show a single surface, not widgets. **Screenshots are the oracle for UI**; do not build checks on `layout` for egui content.
- Plain `adb input` cannot do multi-touch or stylus pressure; those need instrumentation injection (`MotionEvent` via `UiAutomation`) **[verify API]**.
- Installing the CLI uses a pipe-to-shell script from `dl.google.com`. It is allowed only inside the reviewed CI setup script, never ad hoc.

## Rendering matrix (run every build; proves all three ladder rungs without a device)
1. Vulkan (SwiftShader) — default; log adapter name, backend, limits vs the defaults upstream requires.
2. GLES — forced backend.
3. Forced CPU canvas — `PHOTOCRAFT_CPU_CANVAS=1`.
Each run: start → open sample document → screenshot → logcat → pass/fail JSON. A rung that cannot start is a defect to report, not a skipped test. Driver quirks of real GPUs are the one thing this matrix cannot reveal; they are handled by crash-safe GPU startup (PORT-SPEC SU-8), safe-graphics shortcut, log export, and the device-day runbook.

## Logcat oracle (fail the job on any of)
`FATAL EXCEPTION`, `ANR in`, `signal 11`, `Fatal signal`, `panicked at`, `JNI DETECTED ERROR`, `UnsatisfiedLinkError`, wgpu `Validation Error`, `Device lost`, `StrictMode` violation, `invalid local reference`.

## Red→green proof (AGENTS R3)
Every gate has a seeded-defect variant in `evidence/<gate>/red/` showing it FAIL, then the real run in `evidence/<gate>/green/`. Seeded defects to keep: blank frame, IME bridge off, wrong export bytes, `upstream/` file touched, lock version changed, forbidden dependency present (web crates).

## Evidence layout
`evidence/<milestone>/<step>/` with: CI run URL, screenshots (PNG), a contact sheet, logcat excerpt, the agent's written description of each screenshot, the reviewer's disposition, and the red/green proof. `STATE.md` links to these.
