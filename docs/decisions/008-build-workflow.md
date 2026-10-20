# Decision 008: M1-6 native+APK build workflow (`build.yml`)

Date: 2026-10-20 — Milestone M1, task M1-6.

## Question
How does CI compile the pin-locked shell (entry code's first compile) and produce
installation-ready APKs with a 16 KB page alignment gate?

## Sources
- crates.io API `cargo-ndk` (2026-10-20 read): newest/max-stable `4.1.2`, published
  2025-08-09, MSRV 1.86, not yanked; README (GitHub master): `-t <triple>` (triples such as
  `aarch64-linux-android` supported as well as ABI names), `-o` jniLibs layout, NDK
  detection via `ANDROID_NDK_HOME`, `build --release --locked` passthrough.
- `gradle/actions/setup-gradle` `action.yml` read from `main` (2026-10-20): input
  `gradle-version` ("downloaded, added to PATH"); pin commit for v4 tag resolved through
  nested tag refs → `ed408507eac070d1f99cc633dbcf757c94c7933a`.
- actions pins: checkout v6.0.1 `8e8c483db84b4bee98b60c0593521ed34d9990e8`,
  upload-artifact v4.6.2 `ea165f8d65b6e75b540449e92b4886f43607fa02` (resolves the SHA-pinning
  pending item from decision 003; both new workflows pin; guard.yml remains untouched per
  its protection).
- `upstream/crates/text/build.rs:23-33` verified: `CRAFT_FONTS_DIR` + `CRAFT_FONTS_REQUIRED=1`
  semantics (env set on the cargo step, error when missing).
- developer.android.com page-size guidance (S108: AGP ≥8.5.1 aligns uncompressed libs at 16 KB
  by default; verify with `zipalign -c -P 16`) checked against our AGP 9.0.1.
- Decision 003 facts (ubuntu-24.04 image: NDK 28.2.13676358 under `$ANDROID_HOME/ndk`,
  build-tools present, JDK 17; Rust preinstalled).

## Decisions
1. **Single job `build` in `build.yml`** (this IS the required `build` check from M1-1
   branch protection). Sequence: toolchain facts → rustup targets → NDK pick (28.2 preferred,
   warning fallback) → `cargo install cargo-ndk --version 4.1.2 --locked` →
   `cargo ndk -t aarch64-linux-android -t x86_64-linux-android -o app/src/main/jniLibs build
   --release --locked` (fonts env embedded: BR-2 gate `CRAFT_FONTS_REQUIRED=1`) →
   jniLibs + `readelf -lW` alignment facts → Gradle 9.1.0 `assembleDebug assembleRelease` →
   `zipalign -c -P 16` BOTH APKs (first real packaging-use of the 16 KB gate) → evidence
   artifact `build-evidence-<runid>` (facts, APKs, logs; always uploaded).
2. **Both ABIs in one cargo-ndk invocation**, matching the agdk-eframe template recipe;
   the emulator matrix then uses only what it cannot avoid (x86_64 image is the only
   emulator-viable ABI here; aarch64 build kept for parity and 16 KB evidence).
3. **`--locked` builds**: any manifest/lock drift fails the build (never re-resolve).
4. **No cross-workflow artifact passing**: `emulator-e2e.yml` (M1-7) checks out and rebuilds
   itself (runner budget < coordination complexity; both workflows are artifacts-producing
   and independently verifiable). Revisit when M4 oracle runs need the same APK.
5. **No signing config in M1**: `assembleRelease` produces the unsigned APK (16 KB gate),
   `assembleDebug` produces the installable APK for the emulator rows.
6. **No caching** in M1 (runs are cold but bounded: ~90 min timeout; profiling comes later).
7. RELEASE-only? No: debug AND release built every run — gradle treats them as tasks of one
   session in the same step.

## What would invalidate this
- cargo-ndk 4.1.2 CLI drift from the README examples (e.g. flag renames) → M1-6's first run.
- runner image losing NDK 28.2 → `::warning::` fallback keeps the run honest about revision.
- `zipalign -c -P 16` failing at AGP 9.0.1 → packaging config change (R3: gate stays red
  until the ROOT cause is fixed, never silenced).
- JDK version mismatch with AGP 9 → image facts step surfaces it first.
