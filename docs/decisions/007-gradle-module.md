# Decision 007: Gradle module (M1-5)

Date: 2026-10-20 — Milestone M1, task M1-5.

## Question
How is the Rust cdylib packaged into a bootable GameActivity APK within the CI
constraints (decision 003: AGP 9.0.1 / Gradle 9.1.0 / JDK 17, `ubuntu-24.04` images)?

## Sources
- `rust-mobile/rust-android-examples@main` `agdk-eframe/` (settings.gradle, build.gradle
  AGP 9.1.0 declare, app/build.gradle: compileSdk/targetSdk 35, minSdk 31, Java 17,
  `androidx.games:games-activity:4.4.0` with NO prefab and NO separate game-text-input,
  appcompat 1.7.0, manifest `<activity android:name=".MainActivity…" meta-data
  android.app.lib_name>`). Pinned-commit read 2026-10-20.
- `docs/decisions/003-ci-basics.md` (agent-pinned AGP/Gradle/JDK).
- Decision 002 (display name Picsh, applicationId io.github.ouaell.picsh).
- Plan M1-5 step: wrapper? `games-activity:4.4.0` no Prefab; jniLibs wiring.

## Decisions
1. **Gradle root = `android/`** (same dir as the Cargo workspace; sibling `app` module) —
   mirrors the template layout (Cargo.toml + app/ + gradle files together).
2. **Navigation/activity**: `android:name="com.google.androidgamesdk.GameActivity"` directly
   (no Kotlin/Java subclass — the shell adds zero Java code in M1) with
   `meta-data android.app.lib_name = "picsh"`, `configChanges` list copied from the template.
   The Rust `android-activity` crate receives the GameActivity pointers through eframe's
   `android_app`.
3. **Versions under OUR pins, not the template's**: AGP 9.0.1 / Gradle 9.1.0 (decision 003);
   compileSdk/targetSdk 35 + minSdk 31 (template values; U-E minSdk question stays open —
   evidence-driven rerun is a later decision; nothing in the manifest blocks a change).
   versionName 0.8.2 / versionCode 82 (= upstream's at the pin, BR-6).
4. **No committed Gradle wrapper**: there is no local Gradle on the Windows machine, and the
   wrapper jar would be an unreviewable binary shipped into git. `build.yml` (M1-6) uses
   `gradle/actions/setup-gradle@v4` with `gradle-version: 9.1.0` and runs `gradle -p android …`
   directly; the version is pinned by the action, not by the wrapper properties.
5. **JNI packaging**: `libpicsh.so` blocks are copied into `app/src/main/jniLibs/<abi>/` by
   the build workflow (`cargo ndk -o app/src/main/jniLibs …`); the Gradle module has no
   source set — only the manifest. 16 KB alignment comes from `.cargo/config.toml`
   (M1-3, already locked); APK page alignment coverage is asserted by `check-16kb.sh`
   in CI once packaging exists (M1-6).
6. **No `android:theme`/icons in M1**: the template's res/ (themes, launcher icons) is
   replaced by nothing — the system default applies; both are cosmetic for the M1 gate
   evidence and each is a separate packaging task (plan PK rows).

## What would invalidate this
- An AGP 9.0.1 requirement that blocks the manifest (e.g. named theme) → the M1-6 build
  failure shapes the fix (R7 evidence recorded in STATE).
- games-activity API change in the AAR at 4.4.0 (manifest class name still
  `com.google.androidgamesdk.GameActivity` — verified today from the AAR's own docs page and template).
- U-E evidence supporting a different minSdk (≥31 chosen here may relax to 26+ later).
