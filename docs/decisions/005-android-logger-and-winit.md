# Decision 005 — Adding `android_logger` (logcat sink) and `winit` (type-import only) to the shell

- **Question:** the shell's Rust logs (`log` facade) currently go nowhere on Android: stdout of a GameActivity native app is not routed to logcat (see vendored `rust-debugging`/`rust-observability` skills). Which logger backend, and is a direct `winit` dependency legitimate?

- **Sources:**
  - PORT-SPEC SU-1 (PORT-SPEC.md:41): "`log` → logcat (`android_logger`, a shell-only dependency pinned in our lock)". Later rows (rotating file, Share log) stay in M5.
  - PLAN.md:279: vendored `rust-security` skill exists to vet "new crates such as `android_logger`"; rust-security §5 vetting gate applied below.
  - eframe 0.36.2 pinned source (`epi.rs`, tag 0.36.2): `NativeOptions.android_app: Option<winit::platform::android::activity::AndroidApp>` (cfg target_os="android"); eframe 0.36.2 does not re-export `winit`, and its own manifest requires `winit ^0.30.13` (crates.io API, eframe/0.36.2/dependencies).
  - Official template rust-mobile/rust-android-examples/agdk-eframe on default branch: `android_main` with `NativeOptions { android_app: Some(app.clone()), ..Default::default() }` and `OnceLock` guard around global init.
  - Lock state: `winit` already locked at 0.30.13, `log` at 0.4.34 (caret-satisfied; no version churn), queries of the current lock show no `android_logger`/`env_filter`/`android_log-sys` entries.

- **Vetting (rust-security §5) for the three names expected to enter the lock:**
  - `android_logger 0.15.1` — first publish 2016-02-23, 27.3M downloads, repo `rust-mobile/android_logger-rs`, not yanked/removed. Published source triaged (docs.rs .crate contents): log facade impl writing only to `__android_log_write/__android_log_buf_write`; no network, no process spawn, no fs, no embedded blobs; no build script, no proc macro. Caret requirement `"0.15.1"` (no `=` as vetting device).
  - `android_log-sys 0.3.2` — first publish 2016-02-23, 31.1M downloads, repo `rust-mobile/android_log-sys-rs`. Published source = 100-line bindgen FFI to Android liblog (`#[link(name = "log")]`); zero dependencies; no build script.
  - `env_filter 0.1.4` — official `rust-cli/env_logger` ecosystem crate, 221.8M downloads, first publish 2024-01-19. lib.rs triaged: pure filter-string parsing (lib.rs:44-47 doctest reading `std::env::var` is caller-driven and its documented purpose); `regex` dep is optional and NOT enabled by android_logger → must not appear in our lock (checked in the lock-diff verification below).
  - `winit` direct dep adds no new lock name (already locked 0.30.13; our edge is `default-features = false`, feature-enablement unchanged because crate-graph requirements are additive/unioned).
  - `cargo audit`/`cargo deny` are not yet CI jobs in this repo; the checks exist only as vendored skills. Audit of the new graph is therefore recorded as a follow-up check inside the first milestone that gains a compile step (M1-6 build.yml), not silently skipped.

- **Decision:** add to `android/Cargo.toml`:
  - `android_logger = "0.15.1"` (shell-only, logcat sink; `init_once` in `android_main` with tag `picsh`),
  - `winit = { version = "0.30.13", default-features = false }` (direct dep ONLY so the shell can name `winit::platform::android::activity::AndroidApp` in its entry; no feature change, no lock-name change expected),
  - refresh `Cargo.lock` via the existing CI bootstrap artifact flow (no local cargo), verify the lock diff adds exactly the three vetted names above and NO `regex`/`aho-corasick`/`regex-automata`/`regex-syntax`, then re-commit the lock.

- **Lock-diff correction (2026-10-20, verified):** the first candidate lock (run `39450301905`) pulled 7 new names: `android_logger`, `android_log-sys`, `env_filter` plus `regex 1.13.1`, `regex-automata 0.4.18`, `regex-syntax 0.8.11`, `aho-corasick 1.1.5` (each with `memchr`, already locked). Root cause pinned in the published `.crate` manifest (docs.rs android_logger/0.15.1/source/Cargo.toml): android_logger's own `[features] default = ["regex"]` (`regex = ["env_filter/regex"]`; manifest confirms it depends on env_filter with `default-features = false`). The shell does not use regex filter matching, so the dependency edge was changed to `android_logger = { version = "0.15.1", default-features = false }`; the four regex-family crates were therefore never adopted and stay unvetted-on-purpose (they are not in the graph). The final lock must show exactly 3 added names.

- **What would invalidate it:** a lock diff introducing any unvetted name (fail the commit, re-vet before compiling); android_logger gaining a build script or proc-macro target in a newer release; SU-1 being renegotiated away from android_logger by the user.
