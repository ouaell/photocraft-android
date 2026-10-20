# PhotoCraft → Android: execution plan v3 (2026-10-13)

**Companion document: `PORT-SPEC.md` is normative for WHAT the port must do** — it maps everything the existing ports (macOS/Linux/Windows desktop shell, web shell, packaging, CI/release, docs) do onto Android, row by row, with IDs (BR, SU, RB, SV, PB, AO, PK, DL). This plan is HOW, in what ORDER and with what PROOF. A spec row is closed only through the step protocol (§5.0).

Tags: **[V]** = read in a primary source during planning (repo at the pinned tag, crate source, official docs). **[U]** = not yet proven; resolved at the milestone named next to it.
**Pinned upstream:** tag `v0.8.2`, commit `d43db3e153c76aefce9b32cef9099e458eaf17a8` (file `UPSTREAM_PIN`). Upstream moves daily (0.7.0 → 0.8.2 in two days), so we build only against the pin; bumping it is a gated task (§8).

---
## 0. Goal, scope, and why this is expected to work

**Foundation — the misunderstandings this plan is built to prevent (each has a machine check, §5.1):**
(1) The product is the **desktop** PhotoCraft (the same `photocraft-ui-egui` + engine the macOS/Linux/Windows builds run), compiled natively for Android — **not the web build, not a WebView, not a new app** (`no-web-guard.sh` fails the build if the shell depends on `photocraft-web`, `wasm-bindgen`, `web-sys`, `js-sys`, `trunk`, or any WebView class);
(2) `upstream/` is never modified (`guard-upstream.sh`);
(3) the shell is platform glue only (an allowlist of upstream crates the shell may depend on, checked in CI);
(4) **no physical device exists until the end (M7)**: everything before M7 is proven on CI emulators, and M7 is prepared in advance by a device-day runbook.
(The web shell in the upstream repo is read only as a structural example of `Services`; none of its code or output is used.)

**Goal.** The existing, unmodified PhotoCraft runs **as a native Android app** with **touch, pen and keyboard**, through a thin separate shell (`android/`); emulator testing runs in GitHub Actions — the same relationship `apps/photocraft-web` has to the engine. No new app, no redesign, no change to upstream, no Linux/macOS work (already supported upstream).

**Release scope (all required before a release candidate; work order follows §6):** entry/activity (C1), rendering on the GPU path (C2), touch + pinch/pan (C3), mouse/trackpad hover, right-click and wheel (C3b), text/keyboard soft + hardware (C4), file open/save (C5), full pen: pressure, tilt, rotation, eraser (C6), insets (C7), lifecycle/autosave (C8), prefs/presets (C11), clipboard image copy/paste and share (C12), packaging (C13), Back (C14), product polish (C15), desktop mode and large screens against the official Adaptive Tier 1/2/3 checklist (C16).
**The release scope above is a summary; the row-by-row definition is `PORT-SPEC.md`** (build recipe parity, startup sequence parity, module-by-module runtime parity, Services semantics, the audit of shared code that behaves differently on Android, packaging/CI/release parity, legal/attribution).
**Out of scope:** sibling Craft apps (until PhotoCraft is released), Linux/macOS work, any change to upstream, any new feature, any redesign of upstream's UI.

**Why Android is different from Linux/macOS even though those work:** the engine's arm64 CPU code is expected to compile unchanged (§1 E2). What differs is the OS layer: window/surface lifecycle, soft keyboard, file access, insets, Back. Those are exactly the C-items, and nothing else.

**The case for success (all [V], details in §1):**
E1 upstream already isolates every platform behaviour behind `Services`, and its web shell is a working non-desktop template · E2 the 583-crate dependency closure of the crates we link has no C/C++ libraries (only build helpers), and desktop-only crates are either gated off for Android by eframe itself or live only in the desktop binary · E3 eframe 0.36.2, android-activity 0.6.1 and ndk are already in upstream's lockfile · E4 there is an official, documented build recipe (Gradle + `cargo ndk` + GameActivity 4.4.0) and official examples (`agdk-eframe`, `agdk-egui`) · E5 pen pressure arrives through touch force with no extra code · E6 the hardest piece (soft keyboard) has a published, merged recipe with its pitfalls listed · E7 Android file picking fits upstream's callback-async `file_dialog` contract · E8 CI emulator, 16 KB rules and Play rules are known · E9 remote real devices exist.

### 0.1 What "works" means here (the quality bar)
"Works" is **not**: it compiles, it launches, one frame renders, scripts are green. It means all of the following, each with evidence (§5):
1. **Same product as desktop.** Every capability the desktop build has and Android can host behaves the same: same engine, same tools, same results. Export output is **pixel-identical** to desktop/`photocraft-cli` for the same input. Capabilities that cannot exist on Android (colour picker from other apps' windows, native menus, window frame, control server) are listed one by one in `docs/decisions/services-parity.md` with the reason — none is dropped silently.
2. **Real GPU path, no cheap fallback.** On any device with a working Vulkan adapter the app uses the same GPU compositor as desktop. The CPU canvas path exists only as a diagnostic fallback; seeing it selected on a Vulkan-capable device is a defect.
3. **Every input type done properly.** Touch with pinch/pan; pen with pressure, tilt, rotation and eraser; soft keyboard with composition (CJK/Arabic/predictive IMEs) and paste; hardware keyboard shortcuts with all modifiers; mouse/trackpad hover and wheel.
4. **Native-grade integration.** Edge-to-edge with correct insets and cutouts; keyboard never covers the focused field; rotation, multi-window and folding without restart or data loss; Back behaves as Android users expect; open/save through the system file picker; "open with" and share; dark/light; correct app name, adaptive icon and splash (own artwork — upstream's ArtCraft marks are not licensed for forks); minimal permissions; release-signed build.
5. **Stable and honest under stress.** No crash, ANR or validation error in the scenario suite; large images produce a clear message instead of a crash; process death loses no work (autosave/recover).
6. **Desktop mode is a first-class target, not an afterthought.** Tablets, foldables and ChromeOS run Android apps in a PC-style mode (freeform resizable windows, external monitors, mouse/trackpad, physical keyboard). There PhotoCraft must behave like the desktop app: continuous window resizing, minimum window size, fullscreen request, mouse hover, right-click and middle-click, wheel and trackpad-pinch zoom, desktop keyboard shortcuts with every modifier, system-matching cursors, drag and drop of files into and out of the app, "open with" file handlers, scrollbars while scrolling by mouse, tooltips on hover. Official yardstick: Android's **Adaptive app quality guidelines, Tier 1 (Desktop, Foldables, Stylus), including Tier 2 and Tier 3** — every guideline ID is answered in `docs/decisions/adaptive-tier1.md` as *met (with evidence)* or *not applicable (with reason)*; nothing is left blank (§4 C16).
7. **Pen fidelity, not just pen events.** Android batches touch/pen samples per frame. Every batched (historical) sample is consumed so strokes are smooth and match what the hardware reported; pressure, tilt, rotation and eraser are exact; palm/finger rejection is handled (cancelled touches cause no stray marks).
8. **Responsiveness.** Input-to-ink latency and frame pacing on a real device are measured and recorded (M7) next to the same document on desktop; resize, pan and zoom stay smooth on large documents; no busy-looping when idle (battery) and rendering pauses in the background.
9. **Privacy and trust.** The linked crates contain no HTTP client (only `tokio`), so the app needs no `INTERNET` permission and works fully offline; this is kept true and asserted in CI by listing the permissions of the built APK. Only what the user opens or saves is touched (system file picker, no broad storage permission).
10. **Accessibility and localisation baseline.** System font scale and display-size changes, dark/light, keyboard focus navigation, per-app language. TalkBack through AccessKit is evaluated at M6 (U-L) and reported either as working or as a stated limit. RTL/Arabic text input works; RTL layout is whatever upstream's UI supports and is reported.
11. **Observability and upkeep.** Native crashes and Rust panics are captured with symbols (Play vitals/ANR visible; native debug symbols packaged), and the pin-bump workflow (§8) keeps the app current with upstream.
12. **Proven, not claimed.** Every item above has a CI artifact or a recorded real-device result, reviewed by an independent reader of the diff and the screenshots (§5.0, §5.4).

### 0.2 The result this plan is built to produce
A **release-candidate Android build of PhotoCraft (arm64, signed)** plus an **evidence package**: CI runs, screenshots, logs, the 38-field `Services` decision table, the oracle comparisons with desktop, and a short list of known limits. Upstream stays untouched and pinned; later upstream versions arrive by bumping the pin through the same gates.
**What it is, plainly:** the desktop PhotoCraft, with its own UI, running natively on Android with first-class input and system integration.
**What it is not:** a redesigned phone UI. Because upstream may not be modified, panels, sizes and layouts are upstream's own desktop-first ones (upstream itself calls touch "partial" and the app "alpha, ~45% ready for real work"). Shell-level aids (UI scale, on-screen modifier keys) are possible only with the user's approval, and upstream's own bugs remain upstream's.
**Success** = every gate through M7 passes with evidence. **Failure** is also observable: a gate whose ladder is exhausted stops the work with a report — never a silent downgrade.

**How big the job is (verified anchor, size estimate is my judgment).** The closest existing analogue is the web shell: `apps/photocraft-web/src/web.rs` is 514 lines (+51 in `main.rs`) and does exactly what the Android shell must do — start eframe, build `Services` (10 fields), feed pen events, pick/save files, store prefs. The desktop wiring (`services.rs`) is 898 lines for all 38 fields. The Android shell is a shell of that order, plus a small Kotlin layer for what Android needs (keyboard, file picker, insets, Back). It is a port of an existing, working UI — nothing in the engine, tools, filters or UI is written.

**What this plan does not claim.** No Rust toolchain is reachable from the planning environment, so nothing has been compiled yet; **M1 is the first real proof** and is deliberately the cheapest possible one (real upstream UI on an emulator, nothing else). Beyond that, every milestone ends with evidence the user can look at, and each risky component has a pre-decided next rung, so a failed rung changes the method, never the goal. No success percentages are given because none can be measured before M1.

**Baseline honesty.** Upstream's `ROADMAP.md` (2026-10-11) calls itself alpha, "ready for real work ~45%"; `docs/gaps.md:125`: 579 open issues; `docs/hardware-parity.md:56`: touch only "partial" on Windows. The Android build inherits upstream behaviour; to separate port defects from upstream defects, visual checks compare against the same pinned build on desktop (§5.3).

### 0.3 Fatal-gap audit — every way found so far that this could silently fail, and where it is closed
| # | Gap | Evidence | Closed by |
|---|---|---|---|
| 1 | Crates don't compile for Android | 583-crate closure has no C libraries; desktop-only crates excluded for Android (E2). **Static only — no toolchain reachable from planning.** | M1 (first build) |
| 2 | GPU path unavailable on some devices (silent CPU fallback) | Requires `Limits::default()`, no optional features (F26) | **No device exists before M7**, so: (a) the CI **rendering matrix** runs Vulkan(SwiftShader), GLES and forced CPU on every build, proving all three ladder rungs and the GPU shaders/compute functionally; (b) crash-safe GPU startup (SU-8) and a safe-graphics shortcut make a bad driver recoverable; (c) adapter/limits/driver log export is built in (SU-1); (d) the **device-day runbook** (`docs/device-day.md`, M6 deliverable) makes the first real-device run produce the maximum information; (e) M7 measures real GPUs |
| 3 | CI emulator cannot reveal real-driver quirks (Mali/Adreno/PowerVR) | emulator runner defaults to `swiftshader_indirect` (F15) | Accepted, named residual risk: only M7 can close it; it is limited by (b)–(d) above, and the app never depends on the GPU path to start (CPU canvas rung) |
| 4 | No system fonts → tofu for Arabic/CJK/emoji | `system_font_dirs()` lacks `/system/fonts` (PB-1) | C9: XDG symlink, ladder, M2 screenshots |
| 5 | Soft keyboard/IME incomplete | F5, F13 | C4 ladder A→B→C, M3 |
| 6 | Text copy/paste between apps absent | arboard excluded on Android (SV-7) | Kotlin clipboard bridge, M3 |
| 7 | Layout-file crash loop at startup | `ui_state::sanitize` exists for a reason (SU-7) | Port the sanitiser, explicit `persistence_path`, test with corrupt `ui.ron` |
| 8 | Different optimisation/panic profile than official builds | profiles not inherited by a separate workspace (BR-3) | `profile-parity.sh` |
| 9 | Missing official fonts | `CRAFT_FONTS_DIR` required for release parity (BR-2) | `craft-fonts-pin.sh` + `CRAFT_FONTS_REQUIRED=1` |
| 10 | Pinch/pan paint the document, or pan doesn't work | F27, F28 | C3c + document-hash test |
| 11 | Jagged/laggy pen strokes | winit uses latest sample only (F21) | C6 historical samples |
| 12 | Mouse/right-click/wheel/hover/cursors absent | F6, F21 | C3b, C16 |
| 13 | Surface loss on pause breaks canvas | eframe recreates window, device persists (F25) | C8 + S7; GPU-lost handling checked in S7 |
| 14 | Back gesture swallows strokes at screen edges; Back key dead | F7; gesture exclusion (AO-2) | C14, C7, M2/M5 tests |
| 15 | Panics crossing JNI | Rust unwinding into foreign frames is undefined behaviour | Every JNI entry wrapped in `catch_unwind` (R-C checklist) |
| 16 | Multi-instance state clash | engine globals unknown (U-K) | M6 decision |
| 17 | `temp_dir()` points at an unwritable path | PB-9 (to confirm) | `TMPDIR=<cacheDir>`, startup log |
| 18 | Play/OS policy: targetSdk 36, 16 KB pages | F14 | C13 checks in CI |
| 19 | Gradle/AGP/JDK/NDK mismatch | unknown versions of the official template | M1 decision record with version matrix from official docs |
| 20 | Upstream moves daily | 0.7.0→0.8.2 in two days | pin + sync + R-B re-audit |
| 21 | Official release workflow is a reusable workflow in another repo we cannot read | `release.yml` → `craft-common-actions` | PK rows reproduce its observable behaviour (artifacts, checksums, version); remaining differences listed in `docs/android.md` |
| 22 | Agent failure modes (unrequested edits, fake green, silent substitution) | your six prior projects | AGENTS.md R1–R16, step protocol §5.0, CI guard |

### 0.4 Traceability — from the quality bar to evidence
| Quality item (§0.1) | Spec rows / components | Milestone | Evidence |
|---|---|---|---|
| 1 Same product as desktop | BR-1…7, SV-1…5, RB-*, Appendix A | M1, M4, M6 | export pixel oracle; services-parity.md |
| 2 Real GPU path | SU-8, SU-9, F26, gap 2 | M1 (rendering matrix), M6 (device-day runbook), M7 | matrix logs per rung; adapter/limits logs from real devices at M7 |
| 3 All inputs | C3, C3b, C3c, C4, C6 | M2, M3, M6 | S3, S3b, S4, S9, S10 artifacts |
| 4 Native integration | C5, C7, C8, C12, C14, C15, C16, AO-* | M2, M4, M5, M6 | scenarios S2, S5–S7, S13, S14; `adaptive-tier1.md` |
| 5 Stability | SU-3, SU-7, SU-8, C8, C10 | M1, M5, M6 | logcat oracle; S7, S8 |
| 6 Desktop mode | C16, C3b, RB-8, RB-13 | M6, M7 | `adaptive-tier1.md`; S14; device video |
| 7 Pen fidelity | C6, RB-18 | M6, M7 | smoothness and profile comparison |
| 8 Responsiveness | C10, PK-5 | M7 | latency/frame numbers vs desktop |
| 9 Privacy | AO-7 | M5 | APK permission list |
| 10 Accessibility/localisation | C9, U-L | M2, M6 | locale screenshots; TalkBack finding |
| 11 Observability/upkeep | SU-1, SU-3, §8 | M1, M6 | logs, symbols, sync PR |
| 12 Proven, not claimed | §5.0 protocol | all | CI links, screenshot descriptions, reviewer dispositions |

**The final picture:** a signed Android build of the pinned PhotoCraft that starts like the desktop app (same startup sequence, same preferences and recovery files, same fonts), draws on the same GPU compositor where the device allows it, accepts touch, pen, mouse and keyboard like the desktop app accepts its devices, integrates with Android's files/windows/back/clipboard, ships with the same legal notices, and is rebuilt from each new upstream tag by the same gates. Every path above ends at an artifact someone can open.

---
## 1. Verified facts

| # | Fact | Source |
|---|---|---|
| F1 | `Services` (all `Option`, `Default`; `crates/ui-egui/src/lib.rs`) carries every platform behaviour; **38 fields** at the pin. Desktop sets all (`apps/photocraft/src/services.rs`); web sets **10**: `screen_pick, import, export, file_dialog, write, encode_png, inbox, load_prefs, save_prefs, preset_store`. | repo at tag |
| F2 | `file_dialog` is callback-async (`reply.send(answer)`); answers `Contents/ContentsMany/SaveTo`. | `web.rs` |
| F3 | Locked: eframe 0.36.2, egui-winit 0.36.2, winit 0.30.13, wgpu 30.0.1, android-activity 0.6.1, ndk 0.9.0, jni 0.22.4. No `[patch]`. Rust ≥ 1.95, edition 2024; workspace lint `unsafe_code = "forbid"`. `craft-ui` is a git dependency (`storytold/craft-libs` rev `5c874d51…`). | `Cargo.toml/lock` |
| F4 | eframe 0.36.2: features `android-game-activity`/`android-native-activity`; `NativeOptions.android_app: Option<AndroidApp>`; `App::raw_input_hook` exists. | crate source |
| F5 | winit 0.30.13 Android: `set_ime_allowed(true/false)` → `show/hide_soft_input` (not an empty stub). GameActivity **text events are not handled**; key events carry `text` only from the hardware key map; **modifiers are not reported**. | winit source; be3 PR #149 |
| F6 | winit 0.30.13 Android handles only touch Down/Up/Move/Cancel (`_ => None // TODO mouse events`): **no hover, no wheel**; touch force = `pointer.pressure()`. | winit source |
| F7 | Android Back → `NamedKey::BrowserBack` (winit) → `Key::BrowserBack` (egui-winit). Upstream's reaction is unknown **[U-I]**. | winit, egui-winit source |
| F8 | egui-winit safe-area code is iOS-only; `RawInput.safe_area_insets` can be set from `raw_input_hook`. Android 15+ is edge-to-edge for `targetSdk ≥ 35`. | egui-winit source; Android docs |
| F9 | `rfd` 0.17.2 has no Android backend. | docs.rs |
| F10 | `stylus.rs` documents pen per platform (Windows: touch force; Web: pointer events; macOS/X11: native). `StylusFeed` / `PenSample{pressure,tilt_x,tilt_y,rotation,eraser}` is the side channel. Upstream docs: tilt/rotation work on macOS, X11, **web**, not Windows. | `stylus.rs`; `docs/brush-parity.md:45` |
| F11 | `MotionEvent` offers tool type, pressure, tilt, orientation, hover. | developer.android.com |
| F12 | android-activity 0.6.1 needs `androidx.games:games-activity:4.4.0` (do **not** enable Prefab); API has `show/hide_soft_input`, `text_input_state`, `set_text_input_state`, `set_ime_editor_info`, `run_on_java_main_thread`, `content_rect`. **Recommended build:** Gradle project + `cargo ndk -t <abi> -o app/src/main/jniLibs/ build` + `./gradlew build`. `cargo-apk` cannot resolve AARs. | crate README; Android-rbxl README |
| F13 | be3 PR #149 (merged 2026-09-25): read `text_input_state()` in `about_to_wait`, send the **difference** as Text/Backspace/Enter; GameTextInput starts with a **null text pointer → abort in debug** unless `MainActivity` sets an empty state; 64 KiB buffer (clear after ~1 KiB when not composing); winit never reports modifiers, so `MainActivity` forwards Tab/Escape/arrows/Home/End/PgUp/PgDn/modifiers and Ctrl/Alt/Meta combos natively; insets sent from `MainActivity` on every change; touch cancel must not count as a tap. Author had not yet tried it on a device. | github.com/blockeditor-org/be3/pull/149 |
| F14 | Play: target API 36 since 2026-08-31; 16 KB page support required for updates from **2027-02-01**. NDK r28+ is 16 KB aligned by default; AGP ≥ 8.5.1; check ELF LOAD align 2**14 and `zipalign -c -P 16 4`. | developer.android.com/guide/practices/page-sizes (updated 2026-09-16) |
| F15 | KVM works on GitHub-hosted 2-vCPU Linux runners (changelog 2024-04-02); `android-emulator-runner@v2` defaults `-gpu swiftshader_indirect`. | github.blog; runner issues |
| F16 | Device Streaming (remote real devices) exists (Android Studio since 2024, Android CLI since 2026-10-02; 2024 pricing: 30 or 120 free min/month by device class, then $0.15/min on Blaze). **Not used before M7** (no device or remote-device account is assumed); only a possible M7 aid **[U-F]**. | Android Developers Blog |
| F17 | opencode permissions: last matching rule wins; `bash` matches parsed commands (`"git status"` ≠ `"git status *"`); explicit `deny` enforced even in `--auto`; does not constrain what allowed shell commands do. | opencode docs |
| F18 | Android CLI + official skills + `android docs` knowledge base; most skills target Kotlin/Compose. | Android Developers Blog |
| F19 | Desktop autosave logic lives in library crate `crates/format/src/autosave.rs`; wiring closures in `apps/photocraft/src/services.rs:278–300`. | repo at tag |
| F20 | `guard-upstream.sh` tested on 14 seeded cases in real git-submodule repos (pristine pass; modified, untracked, deleted, staged, assume-unchanged, moved commit, `[patch]`, pin mismatch, pin file without commit all fail). | executed |
| F21 | winit 0.30.13 Android reads only the **latest** sample of each `MotionEvent` (no use of batched/historical samples); `set_cursor`, `set_cursor_visible/grab`, `set_min_inner_size`, `request_inner_size`, `set_outer_position` are no-ops; no dropped-file events. | winit source |
| F22 | Upstream's web pen handler also keeps only the latest sample (no coalesced events); desktop gets raw OS events. | `web.rs:116–143` |
| F23 | The crates linked contain no HTTP client (only `tokio`); no ML/inference crates in the closure; `photocraft-automation` and `photocraft-tablet` are linked only by the desktop binary. `read_displays` (display ICC profiles) is desktop-macOS only; otherwise the canvas uses Color Settings or sRGB. | lock closure; `apps/photocraft/Cargo.toml`; `lib.rs:444` |
| F24 | Official yardstick: Android **Adaptive app quality guidelines** Tier 3 → 2 → 1. Tier 1 *Desktop* IDs: Scrollbar_Display, Hover_Parity, Desktop_Menus, UI_Config, Request_Fullscreen_Mode, Keyboard_Navigation, Keyboard_Parity, Input_Combinations, Triple_Click, Multitasking_Scenarios, Multitasking_PiP, Multi-Instance, Drag_Drop_Support, Printing_Support, File_Management_Basics, File_Picker, File_Handlers, Custom_Cursors, Cursor_Target_Size, Cross_Device_Handoff, Offline_Support, Web_Transition; *Foldables*: Foldables_Postures, Foldables_Camera; *Stylus*: Stylus_Draw_Write, Stylus_Drag_Drop, Stylus_Enhanced (drawing, erasing, pressure, tilt, palm/finger rejection); Tier 2 adds right-click, hover, wheel and trackpad zoom, keyboard shortcuts; Tier 3 adds full-window multi-window, multi-resume, external keyboard/mouse/stylus basics. | developer.android.com/guide/topics/large-screens/tier-1-overview (updated 2026-03-23), tier-2/3 pages |
| F25 | **Lifecycle (eframe 0.36.2 on Android):** on `suspended` eframe drops the window/surface and emits a Save (so `App::save` runs); the app, egui context and wgpu **device/render state persist**; on `resumed` it recreates only the window/surface. So `set_wgpu(rs)` stays valid across pause/resume; a *lost device* is a separate event upstream's GPU health code must handle. | `eframe native/wgpu_integration.rs` (resumed/suspended/recreate_window/drop_window); `egui-wgpu winit.rs` (`render_state` created once) |
| F26 | **GPU requirements:** the canvas device is created with `wgpu::Limits::default()` on Vulkan (`downlevel_webgl2_defaults()` on GL), only `max_texture_dimension_2d` and `max_buffer_size` taken from the adapter; **no optional features are required**. Public helper `gpu_canvas::device_limits(adapter)` exists. An adapter below the default limits makes `request_device` fail → upstream's ladder (GL → CPU). | `ui-egui/src/gpu_canvas.rs:805–814` |
| F27 | **Navigation input signals** the canvas reads: pan = `smooth_scroll_delta` + `Event::MouseWheel`; zoom = `zoom_delta()` (includes egui multi-touch pinch); rotate = `Event::Rotate` or `rotation_delta()` (includes multi-touch rotate); Alt-wheel zoom via modifiers. `smooth_scroll_delta` does **not** include touch translation. Upstream's Windows shell already rewrites input in `raw_input_hook` (`fold_legacy_pinch`) — precedent for a touch layer. | `wheel_nav.rs:120–160`; `rotate_view.rs:126–142`; egui `input_state/mod.rs:562–634`; `docs/hardware-parity.md:53–56` |
| F28 | egui-winit emulates the pointer from the **first** touch only (`pointer_touch_id`); a second finger still produces `Event::Touch` (so multi-touch works) while the first finger's press stays active — a pinch would therefore also drag/paint with the first finger unless the shell arbitrates. | egui-winit `lib.rs:878–935` |
| **E2** | **Dependency closure** of `photocraft-ui-egui`, engine, io, codecs, doc, eframe (from `Cargo.lock` at the tag): 583 crates, 23 workspace crates. Native-code indicators: only `cc` (used by android-activity's GameActivity glue, `blake3`, `libfuzzer-sys`←`rav1e`), plus loader/binding `-sys` crates (`ndk-sys`, `jni-sys`, `renderdoc-sys`, …); **no** zstd/openssl/libheif-style C libraries. `arboard` is a dependency only of egui-winit — gated `cfg(not(target_os = "android"))` — and of the desktop binary; **no** library crate under `crates/` depends on arboard, rfd, xcap, open, notify, trash, dirs or keyring. | lock + Cargo.toml analysis (static; not a compile) |
| **E4b** | Emulator pitfall seen in the official `agdk-egui` example: on the emulator's GLES translator, wgpu `request_device` failed with a compute-limit error; fix path is adapter-derived limits / Vulkan on SwiftShader / fallback. Upstream's web shell already uses `use_adapter_limits` and has a CPU canvas path. | rust-android-examples issues #5, #10; `web.rs`; `docs/architecture.md:339` |
| **E8b** | rav1e on `x86_64-linux-android` may need `nasm` (assembly); arm64 does not. Install `nasm` in CI image if the build asks for it. | general knowledge; verify at M1 |

---
## 2. True unknowns (each tied to a milestone; nothing else blocks work)

| # | Question | Resolved at | Pre-decided next step if it fails |
|---|---|---|---|
| U-A | GPU path: Vulkan on real devices; on emulator Vulkan(SwiftShader) vs GLES vs CPU canvas; limits handling. | M1 | Ladder: Vulkan → GLES (adapter limits) → CPU canvas (`set_wgpu` omitted). |
| U-B | Soft keyboard/IME with real keyboards (Gboard, Samsung). | M3 | Ladder A→B→C in C4. |
| U-C | Touch usability of the desktop-first UI. | M2 screenshots | Report with screenshots; shell-level aids (UI scale, on-screen modifier keys) only with user approval. |
| U-D | Which `None` Services fields the UI tolerates. | M1 smoke + R-B | Supply a minimal implementation for any field whose absence breaks the UI. |
| U-E | `minSdk` (Vulkan 1.1/GLES 3.x reach). | before M1 build config | USER decides from evidence the agent presents. |
| U-F | Remote-device options for M7 (Device Streaming quotas/terms, Samsung Remote Test Lab) in case no physical device can be borrowed. | M7 | Physical device lent at the end (the user's stated plan). |
| U-G | eframe `accesskit` feature on Android GameActivity (be3 hit a panic in accesskit_android). | M1 | Build the shell's eframe dependency without it. |
| U-H | Fonts/CJK loading off desktop. | M2 | Bundle a font via shell. |
| U-I | What upstream does on `Key::BrowserBack` and with `quit == None`. | M5 | Shell maps Back to upstream's close flow. |
| U-J | Play new-developer-account rules. | before distribution | n/a to the port. |
| U-K | Multi-instance (Tier 1): can two windows of PhotoCraft coexist given the engine's global state? | M6 | Separate Android processes per instance (`android:process`) if state is global; otherwise report as not applicable with the reason. |
| U-L | TalkBack through AccessKit on GameActivity (eframe `accesskit`). | M6 | Report as a stated limit with evidence; do not claim support. |
| U-M | CI emulator profile for desktop windowing (freeform windows, mouse, external display) and foldable postures. | M6 | Use resizable/desktop AVD profiles if present; else instrumented window-resize tests plus the M7 real device. |

---
## 3. Architecture (nothing in upstream changes)

```
repo/
├── UPSTREAM_PIN               tag + commit; the submodule must equal it
├── upstream/                  git submodule → storytold/photocraft @ pin. READ-ONLY (R1)
├── android/
│   ├── Cargo.toml             own [workspace]; path deps → ../upstream/crates/*; cdylib
│   ├── Cargo.lock             SEEDED from upstream/Cargo.lock
│   ├── src/                   lib.rs (android_main), shell.rs, services.rs, ime.rs, insets.rs,
│   │                          saf.rs, lifecycle.rs, back.rs, jni_bridge.rs (+ pen.rs, mouse.rs later)
│   └── app/                   Gradle module: MainActivity.kt (extends GameActivity), SafBridge.kt,
│                              InsetsBridge.kt, InputForwarder.kt, manifest, icons, androidTest/
├── PORT-SPEC.md               normative port specification (rows BR/SU/RB/SV/PB/AO/PK/DL)
├── scripts/                   guard-upstream.sh (provided, tested), lock-parity.sh, profile-parity.sh, craft-fonts-pin.sh, check-16kb.sh
├── packaging/android/         package.sh (AAB + universal APK), verify, checksums, icons (PK-1..PK-3)
├── .github/workflows/         guard, build, emulator-e2e, device-e2e, upstream-sync
├── docs/decisions/  evidence/  STATE.md  AGENTS.md  PLAN.md  opencode.json  .opencode/agents/
```
**Start from the official template.** Project layout, Gradle files and the `cargo ndk` build step are taken from `rust-mobile/rust-android-examples` (`agdk-eframe`), then pinned to GameActivity 4.4.0 and eframe 0.36.2; the agent does not invent a build chain.
**Dependencies.** Separate Cargo workspace consuming upstream crates by path; `android/Cargo.lock` seeded from `upstream/Cargo.lock`; `lock-parity.sh` fails on any version difference for shared packages; never `cargo update`; `--locked` after the seed commit. A separate workspace keeps JNI `unsafe` out of upstream's `forbid(unsafe_code)` scope and creates nothing inside `upstream/`.
**The shell is only platform glue.** Anything else belongs upstream: report it.

---
## 4. Components, with pre-decided ladders

| ID | Component | Requirement | Mechanism / ladder | Acceptance evidence |
|---|---|---|---|---|
| C1 | Entry & activity | `android_main(app)` → eframe with `android_app: Some(app)`; `MainActivity extends GameActivity`; `games-activity:4.4.0`; wrap `PhotocraftApp::new(session, services)` like `WebShell`. | Single path. | Cold start, logcat clean, resumed activity, backend logged. |
| C2 | Rendering | Vulkan with GLES fallback; `use_adapter_limits` and `set_wgpu` as web does; CPU canvas if no usable adapter. | A Vulkan → B GLES → C CPU canvas. | Backend log per AVD; non-blank screenshots. |
| C3 | Touch | Finger → pointer; pinch/pan reach canvas via egui-winit. | A egui-winit touch. | Pinch changes zoom; pan moves canvas (instrumented gesture + screenshots). |
| C3c | Touch gesture arbitration | One finger = the active tool exactly as the mouse. Two fingers = navigate and **never mark the document**: pinch → zoom and rotate (egui computes `zoom_delta`/`rotation_delta` from `multi_touch`, F27), two-finger translation → `Event::MouseWheel` (point units) injected in `raw_input_hook` (F27), because the canvas does not read touch translation. The first finger's pointer events are held for a short disambiguation window/slop and dropped if a second finger lands (F28); palm and cancelled touches (`ACTION_CANCEL`) end nothing and mark nothing; pen contact suppresses finger touches. | A hold-and-decide state machine in the shell (pure logic, unit-tested on the host). B (only if A cannot hold events): inject `PointerButton` release + `Escape` to cancel the stroke — a degraded, reported state. | S3 two-finger gesture: document hash before = after; pinch factor and pan distance match the injected gesture; one-finger drag draws as with a mouse; palm test (S3b). |
| C3b | Mouse, trackpad, stylus hover | Hover, primary/secondary/middle buttons, wheel with modifiers, trackpad pinch/scroll, triple-click, scrollbars while scrolling by mouse. winit drops these (F6): Kotlin `dispatchGenericMotionEvent`/`dispatchTouchEvent` forwarding injected as egui events in `raw_input_hook`. | A Kotlin forwarder (no alternative). | Hover tooltip; right-click opens upstream's context menu; middle-drag pans; wheel/pinch zoom as on desktop (S10, S14). |
| C4 | Text & keyboard | Focused `TextEdit` shows the keyboard; typed, composed, pasted text arrives; Backspace/Enter; hide on blur; hardware shortcuts (Ctrl/Alt/Shift/Space/Tab/arrows). | **A** winit as is (`set_ime_allowed` + key text). **B** GameTextInput diff bridge in `raw_input_hook` (be3 recipe F13; empty initial state; clear >1 KiB; `MainActivity` forwards special/modifier/combo keys). **C** native `EditText` overlay committing Text. | Scripted inputs produce exact strings; screenshots with keyboard open. |
| C5 | Files | SAF open (single/multi) and save-as; `VIEW/SEND` intents → `Services::inbox`; big files copied to cache. | A `ActivityResult` + JNI callbacks (matches F2). B blocking Java helper if threading issues. | Open PNG/JPEG/PSD; export compared with `photocraft-cli` (§5.3). |
| C6 | Pen | Pressure via touch force (F6); tilt, rotation (barrel) and eraser tool-type from Kotlin `MotionEvent` → JNI → `StylusFeed`; **all historical (batched) samples forwarded in order** before each latest sample (F21, F22), with their pressure/tilt; palm and finger rejection: `ACTION_CANCEL`/cancelled pointers undo nothing and mark nothing; conversion to W3C tiltX/Y degrees derived from Android docs and unit-tested. | A Kotlin forwarder with historical samples. B latest-sample only (a defect to report, not a finished state). | Stroke-width/angle profiles vs the desktop pen-simulation path; stroke smoothness compared at a fixed speed with and without history; eraser tool type selects Eraser; palm test (S3b). |
| C7 | Insets | Edge-to-edge bars, cutout, **IME inset**, rotation, density. | Kotlin `WindowInsets` → JNI → `raw_input.safe_area_insets`; `configChanges`. | Screenshots: nothing hidden behind bars/cutout/keyboard. |
| C8 | Lifecycle | Surface lost/recreated, background, rotation, process death. | Wire `autosave*`/`recover`/`adopt_autosave` to `crates/format::autosave` as desktop does (F19); persist on `onPause`. | Document survives resume and `am kill`. |
| C9 | Fonts & locale | craft-fonts embedded as in official builds (BR-2); Android system fonts visible to the existing scanner via `XDG_DATA_HOME/fonts → /system/fonts` (PB-1); locale via `PHOTOCRAFT_LOCALE` (PB-2, PB-4). | A symlink + env. B copy needed OFL fonts into the XDG dir. C bundle a Noto subset. | Screenshots: English, Arabic, Chinese, Japanese, Korean, emoji (UI and Type tool). |
| C10 | Memory & threads | `PHOTOCRAFT_RAM_MB` from `ActivityManager` (PB-3); `onTrimMemory` handling; rayon thread count decision from evidence (big.LITTLE, thermal) recorded; no busy loop when idle. | A env + trim handler. | Budget logged; S8 on a low-RAM AVD; idle CPU near zero (measured). |
| C11 | Prefs/presets | `load_prefs/save_prefs/preset_store` in `filesDir`. | Straight wiring. | Persist across restart. |
| C12 | Clipboard & share | `clipboard_set_image/get_image`; share sheet; `VIEW/SEND` "open with". | Kotlin `ClipboardManager` + `FileProvider`. | Copy/paste image round-trip; share sends the file (S-extra). |
| C13 | Packaging | `targetSdk=compileSdk=36`; `minSdk` per U-E; ABIs arm64-v8a (ship), x86_64 (CI); NDK ≥ r28; AGP ≥ 8.5.1; ELF align 2**14; `zipalign -c -P 16 4`. | Gradle + cargo-ndk. | `check-16kb.sh` output; run on a 16 KB-page emulator image. |
| C14 | Back | Back closes popups/dialogs first, then upstream's discard/quit flow, then leaves the app (`Services::quit`); never dead, never silent data loss. | Map `Key::BrowserBack` to the upstream-supported close action (U-I). | Back at each UI depth; unsaved-document prompt shown. |
| C15 | Product polish | App name (user decision), adaptive icon and splash from the user's own artwork (no ArtCraft marks), dark/light, minimal permissions, release signing, per-app language, no debug code in release. | Gradle resources + manifest. | Screenshot of launcher/splash/recents; `apkanalyzer` permission list. |
| C16 | Desktop mode & large screens | Freeform resizable windows (continuous resize with surface recreation, `resizeableActivity`, manifest `<layout>` min/default size since `set_min_inner_size` is a no-op), fullscreen request, external display, multi-window/multi-resume, foldable postures and fold/unfold without restart; egui cursor icon → Android `PointerIcon` each frame (F21: winit sets none); drag and drop in and out via Kotlin `DragEvent` → `Services::inbox`/drag source; file handlers (intent filters for supported formats); printing/PDF export decision recorded; multi-instance per U-K; picture-in-picture, cross-device handoff, camera/audio switchers: not applicable, reasons recorded. | A Kotlin + manifest implementation per the Android guides, tracked row by row in `docs/decisions/adaptive-tier1.md`. | S14: window resize storm, fold/unfold, drag-drop both ways, cursor shapes, right-click menus, fullscreen toggle; the checklist file complete. |

Not built: touch-optimised redesign, new features. Desktop-only fields (control server, colour picker, Photoshop import, native menus, window frame) stay `None`, each with its reason in `docs/decisions/services-parity.md` (Appendix A).

---
## 5. Verification (what keeps "green" honest)

### 5.0 The step protocol (applies to EVERY step inside every milestone)
1. **Spec first:** before coding, write 3–6 lines in `STATE.md`: what this step delivers, the files it will touch, the reference it follows (file:line in upstream web/desktop shell or the cited recipe).
2. **Do only that.** R6 applies.
3. **Self-check by reading, not scripts:** compare your diff line-by-line with the reference named in step 1 and write the differences and why each is intended.
4. **Independent diff review:** a fresh-context **R-A** reviewer reads the diff against the step's spec and AGENTS.md; every finding gets a disposition before the step is closed.
5. **Run it:** push; CI builds and runs the emulator; the agent opens the produced screenshots and writes what it sees.
6. **Close the step** only with: CI link, screenshot description, reviewer disposition. A script's green status is never sufficient by itself; the screenshot description and the diff review are part of the gate.

### 5.1 Protecting the rules
Foundation checks (CI, each shown red once): `guard-upstream.sh` (also checks `UPSTREAM_PIN`); `no-web-guard.sh` (no web/wasm/WebView dependency or class in the shell, checked on `cargo tree` and Gradle dependencies); `scope-guard.sh` (the shell's upstream dependencies are an allowlist of library crates; no engine logic copied in); `lock-parity.sh`; `profile-parity.sh`; `craft-fonts-pin.sh`; `skills-integrity.sh` (vendored skills equal their pinned sources). The `guard` job runs first; all jobs `needs: guard`. Changes to `.github/workflows/`, `scripts/`, `AGENTS.md`, `PLAN.md`, `opencode.json`, `.opencode/agents/` need a human-approved PR (branch protection + CODEOWNERS = the user). `opencode.json` is a seat belt only (F17).

### 5.2 Red→green proof
Every gate has a committed negative control in `evidence/` (blank-frame build, IME bridge off, wrong export bytes, touched `upstream/`, modified lock) on which it must FAIL. A gate never seen red is not a gate.

### 5.3 Oracles
1. **Desktop reference render** of the same pinned build (headless control/render path; read `docs/control-protocol.md`), same document/state/size/scale; compare per region with a perceptual metric whose thresholds are **measured** from desktop-vs-desktop runs and frozen before comparing Android.
2. **File oracle:** Android export pulled via `adb`, decoded, pixel-compared with `photocraft-cli` output.
3. **Logcat oracle:** fail on `FATAL`, `ANR`, panic text, wgpu validation errors, JNI reference errors.
4. **Vision review:** the agent opens the screenshot contact sheet and writes what it sees; every run attaches the contact sheet so the user can look too.

### 5.4 Reviewer subagents (fresh context)
R-A runs on **every step's diff** (cheap: diff only). R-B, R-C, R-D run at milestones M1, M4, M7.
R-A immutability/scope/lock/gates · R-B port-spec parity (every PORT-SPEC row compared side by side with the cited desktop/web file; all 38 `Services` fields; startup steps) · R-C Android/JNI/lifecycle/manifest/packaging · R-D adversarial tester (may run `adb`, emulator, `./gradlew`; cannot edit). Findings need file:line + evidence; "none found" must list what was checked.

### 5.5 E2E scenarios (instrumentation + `adb`; each stores logcat, screenshots, pass/fail JSON)
S1 cold start 60 s · S2 open files · S3 pinch/pan · S4 text input · S5 edit→export→oracle · S6 rotation/resize/insets · S7 background/process death/recovery · S13 Back. At M6 add (all required before M7): S8 low memory, S9 hardware shortcuts, S11 dark mode/font scale, S12 16 KB emulator, S3b pen ramp/tilt/eraser, S10 mouse, S14 desktop mode/large screens (freeform resize, fold/unfold, drag and drop, cursors, right-click, fullscreen, multi-window). Multi-touch and stylus pressure need instrumentation injection, not plain `adb input`.

---
## 6. The critical path (milestones; each ends with evidence, in this order)

| M | Delivers | Proof the user can look at |
|---|---|---|
| **M1** | **Rendering matrix on CI emulators** (Vulkan/SwiftShader, GLES, forced CPU canvas: adapter name/backend/limits against F26, startup path, first frames) + real PhotoCraft UI on the CI emulator: Gradle + `cargo ndk` from the official template; `Services` minimal; backend ladder; 16 KB alignment; U-A, U-D, U-G, U-E settled. Reviewers R-A/R-B/R-C run. | Screenshot of PhotoCraft's own UI; backend log; `check-16kb.sh`; lock-parity green and shown red once; guard green and shown red once. |
| **M2** | Touch with gesture arbitration — one finger = tool, two fingers = pan/zoom/rotate that never mark the document (C3, C3c), insets, fonts (C7, C9, C10; U-C, U-H). | Contact sheet in portrait/landscape/tablet; gesture test logs. |
| **M3** | Text input on real keyboards (C4; U-B). | Scripted-input results; screenshots with keyboard. |
| **M4** | Open/save files + export oracle (C5, C11). Reviewers run. | Hash/pixel comparison with `photocraft-cli`; screenshots. |
| **M5** | Lifecycle/autosave/recovery and Back (C8, C14; U-I). | `am kill` recovery log; Back walkthrough screenshots. |
| **M6** | Full pen incl. historical samples and palm rejection (C6), mouse/hover/wheel/right-click (C3b), desktop mode and large-screen behaviour (C16) with the complete Adaptive Tier 1/2/3 checklist, clipboard/share (C12), product polish (C15), accessibility/localisation baseline (U-L), tier-2 device matrix and the remaining scenarios. **Device-day runbook (`docs/device-day.md`)**: the ordered, scripted first-hour procedure for the day a physical device is available — install, collect adapter/limits/driver info, run the three rendering rungs, safe-graphics start, S1–S14 subset, pen/touch/keyboard checks, log and screenshot export, and how to report results so no time is lost. Reviewers R-B/R-C/R-D re-run. | Pen profiles vs desktop; smoothness comparison; `adaptive-tier1.md` with evidence per row; S14 contact sheets; launcher/splash screenshots; APK permission list. |
| **M7** | Real-device pass on at least one phone, one tablet/foldable in desktop mode with mouse+keyboard, and a stylus device if obtainable (a physical device lent at the end; remote devices only if none is available, U-F): latency and frame-pacing measurements next to desktop, S1–S14 subset, Tier 1 rows that need hardware. Executed from `docs/device-day.md`. Reviewers run. | Device logs, screenshots, video, latency numbers. |

**Spec rows closed per milestone (every row ends `done (evidence)` or `n/a (reason)`):**
M1 — BR-1…BR-7, SU-1…SU-3, SU-5…SU-11, SU-13, SU-14, RB-1, RB-2 (placeholder icon), RB-7, RB-10, RB-12, RB-19, PB-3, PB-9, PK-4 (build/guard/lock/profile/fonts-pin checks).
M2 — PB-1, PB-2, PB-4, PB-6, RB-3, AO-2, C9, C10.
M3 — SV-7 (text clipboard), AO-4.
M4 — SV-1…SV-5, RB-4, RB-8, PB-5 (decision), AO-3.
M5 — RB-5, SV-10, AO-1, AO-7.
M6 — RB-13…RB-18, SV-6, SV-8, SV-9, AO-5, AO-6, PK-1…PK-3, PK-5, DL-1…DL-4, RB-2 (final icon).
M7 — perf numbers (PK-5), device checks for every row that needs hardware.

Touch gesture arbitration (C3c) belongs to M2.

Milestone failure handling is §11 (stop and report with evidence); a failed ladder rung moves to the next rung without re-planning.

---
## 7. Gates
A milestone gate passes only when its proof exists as a CI artifact, the guard is green, `STATE.md` links the evidence, and reviewer findings (where run) have dispositions. No gate is passed on prose.

---
## 8. Following upstream (no edits, ever)
Scheduled workflow proposes a **new pin** (latest tag) on a branch → guard → lock-parity → build → S1–S5 smoke → PR with results. Failure → issue with logs; the agent may fix only `android/**`. A defect also present in the desktop reference is reported upstream, not patched here. R-B re-runs the 38-field table on every pin bump (`Services` already grew between 0.8.2 and `main`).

---
## 9. Agent tooling and skills (researched and vetted 2026-10-14)

**Skills are instructions the agent obeys, so they are treated as untrusted input until reviewed.** Rules: vendored copies at pinned commits under `.opencode/skills/` (the agent cannot edit them); an **allowlist** in `opencode.json` (`permission.skill`); provenance and vetting notes in `.opencode/skills/PROVENANCE.md`; scripts inside skills are reviewed by a human or R-C before first use; if a skill contradicts the pinned source or official docs, the source/docs win (R14).

**Project skills (ours, verified facts only):** `photocraft-port` (entry point, foundation, step protocol), `eframe-android-shell` (verified eframe/winit/egui/android-activity facts and recipes), `android-ci-verification` (CI, CLI commands, rendering matrix, logcat oracle, evidence layout).

**Official Android skills (`android/skills`, Apache-2.0, commit `5bda39f1…`) — enabled:** `android-cli` (create/run/emulators/screenshots/input/docs), `android-intent-security` (manifest and intent handling for file handlers and SEND/VIEW), `android-permissions-security` (M5: permission list). **Vendored but disabled until needed:** `android-profiler` (M7: Perfetto/Vulkan traces), `play-policy-insights` (M6, after reading its five Python scripts — it includes a Play Store scraper). **Reviewed and deliberately NOT installed:** `edge-to-edge`, `navigation-event`, `adaptive`, `testing-setup` (all Compose-centred; they would push the agent toward Compose/View UI — the equivalent knowledge is read from official docs through `android docs`), `agp-9-upgrade` (only if M1 chooses AGP 9), `r8-analyzer`, and every skill for cameras, cars, media, TV, Wear, XR, identity, AI, billing.

**Community Rust skills (`po4yka/rust-skills`, BSD-3-Clause, commit `6786362a…`; single author, 2 stars — hence vendored, reviewed, allowlisted) — enabled:** `rust-jni`, `rust-android-build` (its 16 KiB policy text matches F14), `rust-panic-safety`, `ffi-error-progress-cancel`, `rust-debugging`, `rust-observability`, `cargo-workflows`, `rust-native-linking`, `rust-unsafe`, `rust-lints`, `rust-security` (vetting new crates such as `android_logger`). Excluded: `rust-performance` (host `sudo` sysctl recipes), and all Swift/UniFFI/wasm/embedded/database/CLI/networking skills.
**Evaluated and not used:** `Nagarjuna2997/android-agent-skill` (developer preview v0.1.0, ships an MCP server; duplicates the official Android CLI); `eguidev` (instruments egui apps from inside their widget code — impossible without changing upstream).

**Tools:** Android CLI (`android docs`, `emulator`, `run`, `install`, `screen capture`, `input`, `sdk`); `adb`; instrumentation/UiAutomator; `apkanalyzer`, `zipalign`, `llvm-objdump`; Rust ≥ 1.95, NDK ≥ r28, AGP ≥ 8.5.1, `cargo-ndk`, Gradle; `nasm` if rav1e asks (E8b). Installing tools happens only in the reviewed CI setup script — no ad-hoc pipe-to-shell (AGENTS R17).
**References (read-only; licence check before reusing code; the pinned source wins over them):** `rust-mobile/rust-android-examples` (`agdk-eframe`, `agdk-egui`), `TouseefX/Android-rbxl` (`android_ime.rs`), `blockeditor-org/be3` PR #149, `shadowbrok3r/EguiMobile` (NativeActivity-based; different trade-offs).

---
## 10. Risks

| Risk | Mitigation |
|---|---|
| Soft keyboard/IME edge cases | Ladder A→B→C, M3, real keyboards at M7. |
| GPU path on emulator/devices | Ladder Vulkan→GLES→CPU canvas; backend log; real devices. |
| Desktop-first UI awkward on phones | Not fixable without upstream changes: report with screenshots; shell aids only with approval. |
| Lock drift | Seed + parity script + `--locked`. |
| Agent tampers with gates/upstream | CI guard, protected paths, red→green proofs, human-approved gate changes. |
| Upstream breaks the shell | Pin + sync workflow + Services re-check. |
| Real-device minutes scarce | Emulator carries volume; device sessions short and scripted. |
| Play dates/policies change | Weekly check (F14); CI asserts alignment. |
| Licence/brand | MIT OR Apache-2.0 notices kept; do not use ArtCraft name/logo; read `docs/brand` licence before publishing (not yet read). |

---
## 11. Stop-and-report triggers
Step impossible as written · decision not in this plan · two failed distinct fixes · temptation to change the idea/library/tool · any need to touch `upstream/` · a gate that cannot be made to fail on a seeded defect · a reference project contradicting pinned source (record, then trust the source).

**The deliverable is the native Android app and nothing else.** No alternative product (web, WebView, wrapper) is an option, and the agent never proposes one. If a ladder is exhausted the agent stops and reports with evidence; the goal does not change.

---
## 12. Sources (read 2026-10-13)
- Repo at tag v0.8.2: `Cargo.toml/lock`, `crates/ui-egui/src/{lib,stylus}.rs`, `apps/photocraft/src/services.rs`, `apps/photocraft-web/{Cargo.toml,Trunk.toml,index.html,src/web.rs}`, `crates/format/src/autosave.rs`, `ROADMAP.md`, `docs/{architecture,gaps,hardware-parity,brush-parity}.md`.
- Crate source: winit 0.30.13 (`platform_impl/android`), eframe 0.36.2, egui-winit 0.36.2, android-activity 0.6.1 (README).
- rust-mobile/rust-android-examples issues #5, #10, #11; be3 PR #149; Android-rbxl README; EguiMobile README.
- developer.android.com: page-sizes (2026-09-16), stylus/MotionEvent; Android Developers Blog 2024-06, 2026-04, 2026-10.
- github.blog changelog 2023-02-22, 2024-04-02; opencode.ai/docs/permissions (2026-10-12); chromestatus/blink-dev WebGPU Compatibility mode; web.dev WebGPU support.

---
## 13. Changes from v2.1 (and from v1)
v3.2: quality bar widened (§0.1 items 6–11): desktop mode as first-class target with the official Adaptive Tier 1/2/3 checklist, pen fidelity (historical samples, palm rejection), responsiveness, privacy, accessibility, observability; new C16; facts F21–F24; unknowns U-K–U-M.
v3.1: added §0.1 (what "works" means: quality bar) and §0.2 (expected result and its honest limits); full pen, mouse/hover/wheel, clipboard/share and product polish moved from "deferred" into the release scope (M6); new components C3b, C12, C15.
v3: removed numeric success estimates, the 8-spike phase and per-phase calendar budgets; replaced with 7 milestones on the real app; reduced unknowns from 15 to 10 by resolving U1/U2/U4/U10/U11 with sources (build chain = Gradle + cargo-ndk + GameActivity 4.4.0 + official `agdk-eframe` template; dependency closure analysis); added the success case (§0) and the size anchor; per-step protocol (§5.0) with R-A on every step's diff, R-B/R-C/R-D at M1/M4/M7; web/WebView options removed entirely; scenarios trimmed for the first release.
v2: corrected winit IME claim (F5), pinned upstream, added C14, 38-field Services table, fixed reviewer permissions.
v1 errors found and fixed: IME "empty stub" claim copied from a third-party README; web-only Services list presented as the whole; missing Back, mouse, IME-inset and autosave components; reviewer R-D could not run its own charter.

---
## Appendix A — `Services` parity table at v0.8.2 (R-B must verify every row against code; "Android decision" is a proposal)

| Field | Desktop | Web | Android decision (proposal) |
|---|---|---|---|
| screen_pick | yes | yes | None; check UI degrades (U15) |
| import / export | yes | yes | **Required** (`photocraft_io`) |
| automation_save / read / write / open_pcraft / command / authorize | yes | – | None (desktop control protocol); no test hooks in release |
| file_dialog | yes | yes | **Required** (SAF, callback-async) |
| write | yes | yes | **Required** |
| save_file | yes | – | Decide after reading its use |
| encode_png | yes | yes | **Required** |
| open_url | yes | – | Optional (Intent VIEW) |
| beep | yes | – | None |
| inbox | yes | yes | **Required** (VIEW/SEND intents) |
| clipboard_set_image / clipboard_get_image | yes | – | Phase 2 (C12) |
| load_prefs / save_prefs | yes | yes | **Required** |
| photoshop_shortcuts | yes | – | None; verify UI degrades |
| system_theme | yes | – | Required (dark mode via `uiMode`) |
| is_wayland / xwayland_command | yes | – | None |
| autosave / autosave_results / discard_autosave / recover / adopt_autosave | yes | – | **Required** (process death; reuse `crates/format::autosave`) |
| append_text | yes | – | Decide after reading its use |
| os_events | None | – | None |
| cursor_pos / caps_lock | yes | – | None (verify) |
| window_frame / caption_style | yes | – | None |
| preset_store | yes | yes | **Required** |
| read_displays / native_menu | yes | – | None |
| quit | yes | – | **Required** (C14) |
