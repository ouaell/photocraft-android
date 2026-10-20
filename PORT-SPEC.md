# PhotoCraft for Android — port specification (modeled on the existing ports)

Pinned upstream: tag `v0.8.2`, commit `d43db3e153c76aefce9b32cef9099e458eaf17a8` (`UPSTREAM_PIN`).
**This file is normative for WHAT the Android port must do.** `PLAN.md` says in what order and with what proof. `AGENTS.md` says how to behave.
Tags: **[V]** read in a primary source (repo at the pin, crate source, official docs). **[U]** not yet proven; resolved at the milestone shown.
Every row has an ID. `STATE.md` tracks each ID as `done (evidence)` or `n/a (reason)`. A row may not stay blank, and "n/a" needs a reason a reviewer can check.

---
## 1. What a "port" is in this repository [V]

The Android port is not "an app to write". It is the same set of parts every existing port has, built around the unchanged shared crates:

| Part | Desktop port (macOS/Linux/Windows) | Web port | Android port |
|---|---|---|---|
| Runtime shell code | `apps/photocraft/src/` — 23 modules, ~7,000 lines (`services.rs` 898, `gpu_startup.rs` 835, `main.rs` 656, …) | `apps/photocraft-web/src/` — `web.rs` 514, `main.rs` 51, preset bridge | `android/src/` (Rust) + `android/app/` (Kotlin, manifest) |
| Build recipe | `cargo build --release --locked -p photocraft --features heif`, with `CRAFT_FONTS_DIR` + `CRAFT_FONTS_REQUIRED=1` | Trunk, `wasm-release` profile, 24 MiB wasm gate | §2 |
| Packaging | `packaging/{macos,linux,windows,freebsd}` (dmg, AppImage/Flatpak/deb, MSI) | `packaging/web` | `packaging/android/` in the Android repo (§8) |
| CI / release | `ci.yml` (fmt, tests `--locked`, clippy `-D warnings`, layer and scorecard checks, corpus, wasm, web size gate, fuzz); `release.yml` → reusable `craft-common-actions` workflow; signing secrets | same | §8 |
| Docs / legal | `NOTICE`, `ATTRIBUTION.md`, `docs/hardware-parity.md`, `book/` | same | §9 |

Because the shared crates are identical, "content" (tools, filters, formats, UI) is inherited. Everything below is the platform layer that each port supplies for itself.

---
## 2. Build recipe parity (BR)

| ID | Requirement | Evidence / mechanism |
|---|---|---|
| BR-1 | Release builds use `--release --locked` and the **`heif`** feature of `photocraft-codecs` (what every official packaging script does). The shell depends on `photocraft-codecs` with `features = ["heif"]`. | `packaging/*/package.sh`; `apps/photocraft/Cargo.toml` `heif = ["photocraft-codecs/heif"]` [V]. `photocraft-heif` is pure Rust (`heic-rs =0.1.4`) [V]. |
| BR-2 | **craft-fonts is embedded exactly as in official releases.** Set `CRAFT_FONTS_DIR=<checkout of storytold/craft-fonts at the commit in upstream's release.yml (`craft-fonts-ref`)>` and `CRAFT_FONTS_REQUIRED=1` when compiling `photocraft-text` (build script `crates/text/build.rs`). Without it the app lacks the Japanese UI/Type fonts that official builds ship. `scripts/craft-fonts-pin.sh` reads `craft-fonts-ref` from `upstream/.github/workflows/release.yml` at the pin and fails if our recorded ref differs; the sync workflow bumps both together. | `crates/text/build.rs`; `release.yml` `craft-fonts-ref: abb83316d96aa59c1cf64784289e378fe9fa5695` at this pin; NOTICE/ATTRIBUTION [V]. |
| BR-3 | **Release profile must be copied.** Cargo ignores `[profile.*]` of a dependency workspace, so `android/Cargo.toml` must repeat upstream's `[profile.release] lto = "thin", codegen-units = 1` (no `panic = "abort"`: the crash guard relies on unwinding). Nothing else changes the optimisation level. `scripts/profile-parity.sh` compares our profile with upstream's at the pin. | `Cargo.toml` at the pin [V]; Cargo behaviour (profiles are root-workspace only) [U — confirm in Cargo docs at M1]. |
| BR-4 | `--locked` with a lock seeded from upstream's; `lock-parity.sh` fails on any version difference of a shared package. | PLAN §3. |
| BR-5 | `unsafe_code = "forbid"` is upstream's lint; our separate workspace may use `unsafe` only in `jni_bridge.rs`/`ime.rs`, each block with a comment stating its invariant. | Reviewer R-C checks. |
| BR-6 | Version = upstream's `Cargo.toml` version at the pin; Android `versionName` = that version; `versionCode` = a monotonic integer derived from it plus our own build counter (documented in `docs/decisions/versioning.md`). | `release.yml` reads version from Cargo.toml [V]. |
| BR-7 | NDK ≥ r28, AGP ≥ 8.5.1, GameActivity `androidx.games:games-activity:4.4.0`, `cargo ndk -t arm64-v8a -t x86_64`, `nasm` available if `rav1e` asks for it on x86_64. | PLAN F12, F14, E8b. |

---
## 3. Startup sequence parity (SU) — what `apps/photocraft/src/main.rs` does, in order, and the Android counterpart

| ID | Desktop step [V: main.rs] | Android counterpart |
|---|---|---|
| SU-1 | `logging::install()` — logger to stderr and rotating file `<config>/logs/photocraft.log` (`.1.log`, …). | `log` → logcat (`android_logger`, a shell-only dependency pinned in our lock) **and** the same rotating file under `filesDir/logs/`; a "Share log" action (Kotlin) so a user can attach it to a bug report. |
| SU-2 | Parse CLI args / env (`--safe-gpu`, `--in-window-menus`, files…, `PHOTOCRAFT_*`). | No CLI. Equivalents: Intent extras for **safe GPU** (launcher shortcut "Start in safe graphics mode"), file list from `VIEW/SEND` intents. Control server flags: not applicable. |
| SU-3 | Crash safety: panic hook logs; `crash_guard::guard` wraps import/export so a panic becomes a UI error (`crash_guard.rs`, 35 lines). | Same hook and guard (re-implemented from `crash_guard.rs`, same semantics); native signals go to Android's tombstone; ship native debug symbols. |
| SU-4 | `linux_libs::preflight` (X11/Wayland/Vulkan library check). | n/a (no dlopen of display libraries); reason recorded. |
| SU-5 | `app_dirs::config_dir()` — per-user data root (`PHOTOCRAFT_CONFIG_DIR`, portable marker, platform dir). | `PHOTOCRAFT_CONFIG_DIR=<filesDir>/photocraft` set before any thread starts; portable mode n/a. |
| SU-6 | Resolve `prefs_file`, `presets_dir`, `recovery_dir`, `ui.ron` under it. | Same relative layout under the Android config dir (so file names and formats match desktop). |
| SU-7 | `ui_state::sanitize(ui.ron)` before eframe reads it (a NaN/zero zoom or huge size aborts startup and crash-loops). | Same sanitisation (port the logic of `ui_state.rs`, 133 lines) and `options.persistence_path = <config>/ui.ron`, `persist_window = false`. eframe's default storage dir is `None` on Android (it uses the `directories` crate), so the path **must** be set explicitly [V: eframe `file_storage.rs`, desktop test `window_and_panel_geometry_survive_a_restart`]. |
| SU-8 | GPU startup: read `performance.gpuBackend` / `RenderingMode` from prefs; begin the **marker** (`gpu-starting.json`, OS file lock); `plan_with_mode`; configure wgpu setup; clear the marker after the first rendered frames; next launch after a driver crash uses the next safer backend (`gpu_startup.rs`). | Re-implement the same state machine for Android: Vulkan → GL(ES) → CPU; same marker file name, same prefs keys (`photocraft_engine::prefs::{GpuBackend, RenderingMode}` are library types and are reused); log adapter name/backend/driver; "safe graphics mode" shortcut = `--safe-gpu`. |
| SU-9 | `PhotocraftApp::new(Session::new(), services)`; `set_wgpu(rs)` with `adapter_info`; device created with `gpu_canvas::device_limits(adapter)` (F26). | Same call sequence and the same public `device_limits` helper (no copy of its logic); on pause eframe drops only the surface and keeps the device (F25), so `set_wgpu` is not repeated on resume; `set_wgpu` only when a real adapter was chosen; otherwise the CPU canvas path (also forced by `PHOTOCRAFT_CPU_CANVAS`/`PHOTOCRAFT_CPU_COMPOSE` upstream knobs [V]). |
| SU-10 | App fields: `integrated_titlebar`, `custom_titlebar`, `background_jobs`. | `integrated_titlebar = false`, `custom_titlebar = false` (the system draws the caption in desktop windowing; none on phones), `background_jobs = true` (thread-based jobs as on desktop; `PHOTOCRAFT_INLINE_JOBS` unset). |
| SU-11 | Services wiring (38 fields). | PLAN Appendix A + §5 below. |
| SU-12 | Platform extras: `tablet::install_*` (pen), `cursor::service`, `caps_lock::service`, `window_frame`, `monitor_profile` (ICC), `screen_color`, `apple_events`/native menu. | §4 table, one row each. |
| SU-13 | `eframe::NativeOptions`: icon, app id `ai.storyteller.photocraft`, title, `inner_size 1440×900`, `min_inner_size 760×480`, `drag_and_drop`. | App id = Android `applicationId` (decision: keep `ai.storyteller.photocraft`? **user decision**, brand/ownership); default and minimum window size via manifest `<layout android:defaultWidth/Height android:minWidth/Height>` (winit's `set_min_inner_size` is a no-op on Android [V]). |
| SU-14 | Environment knobs a shell may set [V: upstream reads them]: `PHOTOCRAFT_CONFIG_DIR`, `PHOTOCRAFT_LOCALE`, `PHOTOCRAFT_RAM_MB`, `PHOTOCRAFT_CPU_CANVAS`, `PHOTOCRAFT_CPU_COMPOSE`, `PHOTOCRAFT_GPU_SYNC`, `PHOTOCRAFT_INLINE_JOBS`, `PHOTOCRAFT_UI_DIRECTION`, `PHOTOCRAFT_TEXT_SYSTEM`. | Set at startup, before any thread: config dir, locale (from the system `LocaleList`), RAM (from `ActivityManager.MemoryInfo.totalMem`), `TMPDIR=<cacheDir>`, `HOME=<filesDir>`. `PHOTOCRAFT_UI_DIRECTION` and `PHOTOCRAFT_TEXT_SYSTEM`: read their use at M2 [U]. |

---
## 4. Runtime behaviour parity (RB) — module by module [V: apps/photocraft/src]

| ID | Desktop module (lines) | What it does | Android |
|---|---|---|---|
| RB-1 | `app_dirs.rs` (234) | Config/recovery/presets/log/marker locations; portable mode | SU-5/6; portable n/a |
| RB-2 | `app_icon.rs` (122) + `packaging/icons.sh` | App icon everywhere | Adaptive icon + monochrome + splash from the user's own artwork (no ArtCraft marks); decision file |
| RB-3 | `appearance.rs` (218) + `Services::system_theme` | OS dark/light, incl. compositors that report none | Read `Configuration.uiMode` in Kotlin; push on change; follows system |
| RB-4 | `apple_events.rs` (45) + `Services::os_events` (desktop sets `None`) + CLI file args | Open-document events | `VIEW`/`SEND`/`SEND_MULTIPLE` intents for every extension in `OPEN_EXTS` → `Services::inbox`; `onNewIntent` while running |
| RB-5 | `caps_lock.rs` (121) + `Services::caps_lock` | Caps Lock state per frame for the precise crosshair (winit/egui have no Caps Lock) | Kotlin reads `KeyEvent.META_CAPS_LOCK_ON` (`getMetaState`/`isCapsLockOn`) → polled value |
| RB-6 | `control_server.rs` (251) + `photocraft-automation` | Localhost control server for agents | n/a: not linked, no test hooks in release |
| RB-7 | `crash_guard.rs` (35) | Panic hook + guard | SU-3 |
| RB-8 | `cursor.rs` (126) + `Services::cursor_pos` | OS pointer position so file drops land correctly (canvas = layer, tab strip = open at position, panels = open as document) | Kotlin `DragEvent` supplies drop coordinates; `cursor_pos` returns the last known pointer/hover/drag position |
| RB-9 | `file_dialog_probe.rs` (129) | Explains missing Linux portal | n/a |
| RB-10 | `gpu_startup.rs` (835) | Crash-safe GPU startup | SU-8 |
| RB-11 | `linux_libs.rs` (447) | Linux library preflight | n/a |
| RB-12 | `logging.rs` (432) | Logger | SU-1 |
| RB-13 | `mac_menu.rs` (396) / `native_menu` | macOS menu bar; `--in-window-menus` keeps menus in the window | `native_menu = None` → in-window menus (the same code path as `--in-window-menus`) [V]; context menus on right-click (Tier 1 Desktop_Menus) |
| RB-14 | `mac_window.rs` (41) / `window_frame.rs` (198) | macOS title-bar drag/quit; Windows borderless frame fix | n/a; `window_frame = None` |
| RB-15 | `monitor_profile.rs` (538) + `Services::read_displays` | Display ICC profiles (macOS only; Windows/Linux use Color Settings or sRGB) | `None`: same behaviour as Windows/Linux. Wide-gamut/HDR displays: documented limit, decision recorded |
| RB-16 | `photoshop_settings.rs` (156) | One-time offer to import Photoshop shortcuts (macOS/Windows) | n/a (no Photoshop settings on Android); `photoshop_shortcuts = None`, UI behaviour with `None` checked (U-D) |
| RB-17 | `screen_color.rs` (485) + `Services::screen_pick` | Colour from the screen (explicit request, no retention) | `None`; UI hides/disables it (check at M1) or the limit is documented |
| RB-18 | `tablet.rs` (301) + `photocraft-tablet` | Pen pressure/tilt/rotation/eraser into `StylusFeed` | Kotlin forwarder with historical samples and palm rejection (PLAN C6) |
| RB-19 | `ui_state.rs` (133) | Sanitise saved layout | SU-7 |
| RB-20 | `services.rs` (898): file filters, save pipeline, atomic writes, recovery, beep | §5 |

---
## 5. Services semantics worth reproducing exactly (SV) [V: services.rs]

| ID | Behaviour | Android requirement |
|---|---|---|
| SV-1 | **Open formats** (`OPEN_EXTS`, 52 extensions): pcraft, pdn, ora, kra, psd, psb, psdt, png, jpg/jpeg, tif/tiff, webp, gif, bmp, tga, ico, qoi, exr, hdr, pbm/pgm/ppm/pam/pfm, pcx, fits/fit/fts, heic/heif/hif, RAW (dng cr2 cr3 nef nrw arw pef orf rw2 raf), abr, grd, svg/svgz, aco, ase, kys, af/afdesign/afphoto/afpub. Filters: All Formats, PhotoCraft, OpenRaster, Krita, SVG. | SAF filters use MIME types, and many of these have none: use `*/*` with an extension check **after** pick (case-insensitive) and register intent filters for the formats that do have MIME types plus `pathPattern`/`mimeType` entries for the rest. A matrix `extension → (MIME for picker, intent filter, handled after-pick check)` is a deliverable (`docs/decisions/formats-mime.md`). |
| SV-2 | **Save As formats** (`SAVE_FILTERS`): PSD/PSB, PhotoCraft, OpenRaster, PNG, JPEG, WebP, TIFF, TGA, OpenEXR, FITS; `suggested` extension first; swatches `.aco/.ase` offered alone. | `ACTION_CREATE_DOCUMENT` with the matching MIME or `application/octet-stream`; the default type and extension logic identical to `save_filters()`. |
| SV-3 | **Save pipeline** (`save_through`, `ENCODE_SHARE = 0.85`): encode then write; progress shown as "Saving NN%" (#3389); `write_atomic` never destroys the old file on failure. | Encode to bytes, then write through `Services::write`/`save_file` with the same progress split; for SAF write to a cache file first, then copy to the picked URI; a failed save leaves the original untouched. |
| SV-4 | **Preferences** go through `write_atomic`. | Same, under the config dir. |
| SV-5 | **Recovery** (`recovery_services` + `crates/format/src/autosave.rs`, `RecoveryStore`): autosave, results, discard, recover, adopt; kept until saved or closed. | Same wiring; `onPause` triggers an autosave; process death must recover (S7). |
| SV-6 | `image_from_files` (clipboard/drag image from paths) and `Services::clipboard_set_image/get_image`. | Kotlin `ClipboardManager` + `FileProvider`. |
| SV-7 | **Text clipboard:** egui-winit disables its system clipboard on Android (`arboard` is excluded for `target_os = "android"`) [V]. | Bridge `PlatformOutput::copied_text` → `ClipboardManager.setPrimaryClip`; inject paste (`Event::Paste`) from `ClipboardManager` for Ctrl+V and the keyboard's paste; otherwise copy/paste inside text fields works only within the app. |
| SV-8 | `open_url` | `Intent.ACTION_VIEW`. |
| SV-9 | `beep` ("Beep When Done") | `ToneGenerator`/notification sound respecting ringer mode, or n/a with reason. |
| SV-10 | `quit` and `ViewportCommand::Close` (used by discard dialog and quit paths) | Confirm what eframe does on Android when asked to close; implement `quit` as `finish()`; Back flow (PLAN C14). |

---
## 6. Where Android falls into the "wrong" branch of shared code — audit [V, static]

Shared crates branch on `target_os`/`cfg(unix)`. On Android `unix` is true while `linux` is false. Found in `crates/` at the pin:

| ID | Site | What Android gets | Shell compensation | Check |
|---|---|---|---|---|
| PB-1 | `text/src/fonts.rs::system_font_dirs()` | the "Linux/other" list: `/usr/share/fonts`, `$XDG_DATA_HOME/fonts`, `$HOME/.local/share/fonts`, `$HOME/.fonts` — **no `/system/fonts`**; no override variable; `pub(crate)` | craft-fonts embedded (BR-2) **plus** `XDG_DATA_HOME=<filesDir>/xdg` containing `fonts → /system/fonts` (symlink created by the shell) so the existing scanner sees Android's system fonts (Arabic, CJK, emoji) | M2: screenshots with Arabic, Chinese, Japanese, Korean, emoji text; if the scanner does not follow the symlink → copy needed files into `xdg/fonts` (OFL fonts only) |
| PB-2 | `text/src/cjk.rs` (`os_locale()` → `None`, fontconfig scan = no-op) | no OS locale hint for CJK variant choice | set `PHOTOCRAFT_LOCALE` from the system `LocaleList` | M2 screenshots per locale |
| PB-3 | `ui-egui/src/gpu_canvas.rs::detect_physical_memory()` | fallback `None` (not a compile error) → memory budget without RAM knowledge | `PHOTOCRAFT_RAM_MB` from `ActivityManager.MemoryInfo.totalMem` | log shows detected budget; S8 low-RAM AVD |
| PB-4 | `ui-egui/src/i18n/system.rs` | `sys-locale 0.3.2` has an Android provider, but may not reflect per-app language | `PHOTOCRAFT_LOCALE` (explicit tag) | locale switch test |
| PB-5 | `engine/src/print_cmds.rs` | printing spawns `lp` (CUPS) → error "could not run `lp`" on Android | Print = documented limit unless a PDF-export + Android print-dialog path is added later; PDF export itself works | Tier 1 `Printing_Support` row records the decision |
| PB-6 | `engine/src/installed_profiles.rs` (`HOME`/`USERPROFILE`) | scans per-user ICC dirs under `$HOME` | `HOME=<filesDir>` keeps it inside the app; built-in profiles remain | Colour Settings screenshot |
| PB-7 | egui-winit clipboard | internal only (SV-7) | Kotlin bridge | S-clip |
| PB-8 | eframe persistence | no default dir (SU-7) | explicit `persistence_path` | restart test |
| PB-9 | `std::env::temp_dir()` | Rust std falls back to `/data/local/tmp` on Android when `TMPDIR` is unset [U — confirm in std source at M1]; in the linked non-test code only printing uses temp files | `TMPDIR=<cacheDir>` | startup log prints `temp_dir()` |
| PB-10 | winit 0.30.13 Android | no mouse hover/wheel, only latest touch sample, cursor/min-size/resize/drag-drop APIs are no-ops, IME text events dropped, modifiers not reported | Kotlin forwarders (PLAN C3b, C4, C6, C16) | per-component evidence |
| PB-11 | `photocraft-automation`, `photocraft-tablet` | not linked by library crates | n/a | closure check (PLAN E2) |

The audit covered every `cfg(target_os/unix/windows/wasm32)` site in `crates/` (28 files); sites using only `cfg(target_arch = "wasm32")` take the native (non-wasm) branch on Android and need nothing. R-B re-runs the audit on every pin bump.

---
## 7. Android-only responsibilities with no desktop analogue (AO)

| ID | Responsibility | Source of truth |
|---|---|---|
| AO-1 | Surface lifecycle, rotation, multi-window, fold/unfold without restart | PLAN C1, C8, C16 |
| AO-2 | Edge-to-edge insets, IME inset, **system-gesture exclusion** for the canvas edges (so a stroke near the edge is not swallowed by the Back gesture) | PLAN C7, C14 [U: confirm `setSystemGestureExclusionRects` limits in Android docs at M2] |
| AO-3 | SAF open/save, persistable URIs | PLAN C5 |
| AO-4 | Soft keyboard, IME composition, hardware shortcuts | PLAN C4 |
| AO-5 | Pen, palm rejection, historical samples | PLAN C6 |
| AO-6 | Desktop mode: freeform windows, mouse, cursors, drag and drop, file handlers | PLAN C16, Adaptive Tier 1 checklist |
| AO-7 | Permissions: none requested (no INTERNET, no broad storage); `allowBackup="false"` for user documents (decision), `exported` only for the activity and intent filters needed | APK permission list in CI |

---
## 7b. Input-signal mapping (IM) [V: wheel_nav.rs, rotate_view.rs, egui input_state, egui-winit]
What the upstream canvas actually reads, and the Android source that must produce it:

| ID | Upstream signal | Android source |
|---|---|---|
| IM-1 | Pan: `smooth_scroll_delta` and `Event::MouseWheel` (point/line/page units; ⇧/⌘/Ctrl sideways) | Mouse wheel and trackpad scroll (Kotlin `AXIS_VSCROLL/HSCROLL` with meta state); **two-finger touch translation synthesised by the shell as `MouseWheel(Point)`** (C3c) |
| IM-2 | Zoom: `zoom_delta()` (`Event::Zoom`, ctrl/⌥-wheel, and egui multi-touch pinch) | Touch pinch: automatic through egui multi-touch; trackpad pinch: Android 14+ pinch classification [U: confirm axis/classification names in docs]; ⌥-wheel via meta state |
| IM-3 | Rotate view: `Event::Rotate` or `rotation_delta()` (includes multi-touch rotate), gated by a preference | Touch rotate automatic; gated by the same preference |
| IM-4 | Click/drag: pointer events | Touch via egui-winit first finger (after C3c arbitration); mouse via Kotlin; pen via touch + `StylusFeed` |
| IM-5 | Modifiers: `Modifiers {alt, ctrl, shift, command, mac_cmd}`; `command == ctrl` off macOS | Kotlin `KeyEvent` meta state → `RawInput.modifiers`; `Meta` (logo) key mapping decision recorded |
| IM-6 | Windows precedent: `fold_legacy_pinch` rewrites events in `raw_input_hook` | Same mechanism for the Android touch layer |

---
## 8. Packaging, CI and release parity (PK)

| ID | Existing port practice [V] | Android requirement |
|---|---|---|
| PK-1 | Each port has `packaging/<os>/` scripts that build, stamp the version, name artifacts `photocraft-<ver>-…`, and verify output (`verify.sh`, `apprun-test.sh`, size gate `MAX_WASM_BYTES`). | `packaging/android/package.sh`: builds the AAB and a universal APK; names `photocraft-<ver>-android.{aab,apk}`; verifies ELF alignment 2**14, `zipalign -c -P 16 4`, permission list, signature, `versionCode`; a size gate with a recorded budget. |
| PK-2 | Checksums and verified download (`packaging/linux/verified-download.sh`). | SHA-256 for every artifact, attached to the release; verification script in the repo. |
| PK-3 | Release on branch `release` or manual dispatch with a version override; signing secrets (Apple/Windows) held as Actions secrets; artifacts attached to a GitHub release. | Same triggers; secrets: upload keystore (base64), alias, passwords; optional Play publishing; **never** commit keys; debug keystore only for CI emulator builds. |
| PK-4 | `ci.yml`: `cargo fmt --check`, tests `--locked`, `clippy --all-targets --locked -D warnings`, `cargo xtask layers`, scorecard, corpus tests, wasm check, size gate, fuzz. | Android repo CI: `fmt`, `clippy -D warnings` for the shell, host unit tests for pure logic (IME diff, tilt conversion, sanitiser, GPU plan), `lock-parity`, `profile-parity`, `craft-fonts-pin`, `guard`, build, emulator scenarios, 16 KB check. Optional pin-health job running upstream's own `cargo test -p photocraft-ui-egui --locked` on the host at the pinned commit. |
| PK-5 | `perf-nightly.yml`, `windows-arm64.yml`, `freebsd.yml`, `packaging-lint.yml`. | `packaging-lint` equivalent (shellcheck, actionlint); perf numbers recorded at M7 (latency, frame pacing, open/save times for the standard documents) next to desktop. |
| PK-7 | A real-device day is prepared in advance: `docs/device-day.md` (scripted first hour, diagnostics export, rendering-rung runs, input checklist, reporting template). | Completed and verified on emulators at M6; executed at M7. |
| PK-6 | Release notes follow upstream's version; the Android build says which upstream tag it contains. | About screen shows app version, upstream tag/commit, craft-fonts ref. |

---
## 9. Docs, legal and trust (DL)

| ID | Requirement |
|---|---|
| DL-1 | Ship upstream's `LICENSE-MIT`, `LICENSE-APACHE`, `NOTICE`, `ATTRIBUTION.md` and craft-fonts' `ATTRIBUTION.md` inside the app (assets) and reachable from an in-app licenses screen. |
| DL-2 | ArtCraft name, wordmark and logo are not licensed for forks: app name, icon and store text are the user's own. Read `docs/brand` licence before publishing (**not yet read**). |
| DL-3 | `docs/android.md` in the Android repo: supported devices, input matrix, known limits (printing, screen colour pick, display ICC, TalkBack status, multi-instance decision), privacy statement (no network). Per-feature parity with upstream's `docs/hardware-parity.md` rows is stated; suggested upstream doc changes are filed as upstream issues, never edited in `upstream/`. |
| DL-4 | Play Data safety and privacy policy text prepared (U-J). |

---
## 10. Verification mapping
Each ID is closed with evidence per PLAN §5.0: spec, diff review against the cited desktop/web file, CI artifact, screenshot description, reviewer disposition. R-B owns the cross-check: for every SU/RB/SV/PB/AO/PK/DL row it opens the cited upstream file and the Android implementation side by side and writes the comparison. A row is `n/a` only with a reason that cites a file or an Android constraint.

## 11. Open points specific to this spec
- U-N: how the UI behaves with each `None` service (menus hidden vs disabled vs panic) — read per-field usage; smoke test at M1.
- U-O: semantics of `PHOTOCRAFT_UI_DIRECTION` and `PHOTOCRAFT_TEXT_SYSTEM` (RTL/Arabic support) — read at M2.
- U-P: whether the font scanner follows the symlinked `/system/fonts` directory (PB-1) — M2.
- U-Q: Cargo profile inheritance (BR-3) and Rust std `temp_dir` on Android (PB-9) — confirmed from official docs/source at M1.
- U-R: what eframe does on `ViewportCommand::Close` on Android (SV-10) — M5.
