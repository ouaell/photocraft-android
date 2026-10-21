# M1-7 — emulator-e2e evidence (run 39523080709, first green after 2 fix loops)

Workflow `.github/workflows/emulator-e2e.yml`, job `emulator-e2e`, run
https://github.com/ouaell/photocraft-android/actions/runs/39523080709
(commit `287c5e1`). All three required checks green on this commit:
`guard` (39523080686), `build` (39523080677), `emulator-e2e` (39523080709).
Full artifact: `emulator-e2e-39523080709` (rungs/, e2e/ trees quoted below).

## Red→green proofs in this run (R3)

- **Logcat oracle red proof, seeded, no emulator** (`e2e/redproof/`):
  seeded log containing `FATAL EXCEPTION: main` tripped the oracle grep
  (`red.observed`: "RED as expected: oracle caught the seeded FATAL line");
  the clean one-line log did not (`baseline.green`).
- **KVM permission fix** (`e2e/kvm.txt` → `e2e/kvm-enabled.txt`):
  before: `crw-rw---- 1 root kvm` (runner user could NOT use it; known from the
  failing run 39519013682 where the action printed "ProbeKVM: This user doesn't
  have permissions to use KVM" and launched with `-accel off` until the 900 s
  boot timeout); after the udev rule: `crw-rw-rw- 1 root kvm` — emulator boots
  in ~2 s per rung.

## Rung evidence (all `rungs/<rung>/` in the artifact)

| rung | package | knob asset | app-observed env (log line) | adapter chosen (log line) | oracle |
|---|---|---|---|---|---|
| default | io.github.ouaell.picsh | none | `WGPU_BACKEND=None, PHOTOCRAFT_CPU_CANVAS=None` | `SwiftShader Device (Subzero) device_type Cpu backend Vulkan` (of 2 candidates: Vulkan + Gl) | green |
| gles | io.github.ouaell.picsh.gles | `WGPU_BACKEND=gles` | `WGPU_BACKEND=Some("gles")` | `Backends(GL)` instance → `Android Emulator OpenGL ES Translator (Google SwiftShader) ... backend Gl` | green |
| cpu | io.github.ouaell.picsh.cpu | `PHOTOCRAFT_CPU_CANVAS=1` | `PHOTOCRAFT_CPU_CANVAS=Some("1")` | adapter logged; `set_wgpu` NOT called (cpu-canvas watch path) | green |

Every rung: fresh install (`adb install -r`), pid seen in ≤60 s, 3 screenshots
via `adb exec-out screencap`, full + pid-scoped logcat dumps kept, oracle
pattern (seeded above) matched nothing, result.json green.

## R8 — screenshot descriptions (viewed with vision; `shot-1`, shots 2/3 identical per rung)

`rung-default-1.png`, `rung-gles-1.png`, `rung-cpu-1.png` (320x640):

- **It is the real PhotoCraft UI, not a stub**: left vertical tool rail (move,
  selection, lasso, …), top menu bar rendered as a scrollable row
  (`File Edit Image Layer Type Select Filte…`), tool options row with brush
  size `20`, `Mode:` and `Norm…` fields, a right panel with tabs
  `Swatches / Gradients / Patterns`, a swatch gradient (dark red → bright red)
  and a vertical hue slider, bottom status bar `No document`.
- **Center modal dialog `Switched to CPU rendering`** (present on ALL three
  rungs — expected on the emulator where both adapters are `device_type Cpu`):
  body "GPU acceleration could not continue. Your documents are unchanged.",
  "PhotoCraft is using the CPU image compositor. The window may still use your
  graphics adapter.", `▸ Details`, "Retry GPU requires a restart. Save your
  work first.", buttons `Keep Using CPU` (blue) / `Retry GPU` (outline).
  This proves the desktop fallback-notice path (queue_fallback_notice) reached
  the screen through the pinned ui-egui crate.
- **Text renders correctly everywhere** (menu, dialog, fields) — embedded
  craft-fonts works; no tofu, no clipped unreadable strings at 320 px width
  (dialog wraps mid-line like on desktop at narrow width).
- **Defects observed, recorded honestly (R7/R12):**
  1. Right edge: the vertical hue slider touches the panel edge; a small
     strip of the color area appears cut by the window edge — cosmetic,
     narrow-window layout; record for M2/M6 sizing work, not a gate failure.
  2. Startup jank logged by the system (`Choreographer: Skipped 46 frames!`,
     first-paint Davey ~1.1 s on SwiftShader) — software-emulator startup,
     not measured as an M1 gate.
  3. `eframe: Saving disabled: Failed to find path to data_dir.` — eframe's
     own persistence path unused; our prefs IO goes through `services`
     (upstream-parity), tracked for M5 prefs verification.

## Boot & GPU facts across the 3 emulator boots

- api 34, google_apis, x86_64, SwiftShader (`-gpu swiftshader_indirect`),
  KVM enabled via udev rule (boot ≈ minutes → seconds).
- GameActivity loaded `libpicsh.so` every rung (`GameActivity: Found library
  libpicsh.so. Loading...`, android-activity glue `Creating`/`Resume` logs).
- U-G (accesskit-on-GameActivity): NO accesskit panic, no `FATAL`, no
  validation errors across all three boots — first real-crash evidence pass.

## Fix loop history (R7 records)

1. Run 39503833071 RED — `FATAL EXCEPTION: main`, root cause verified from
   stack: `IllegalStateException: You need to use a Theme.AppCompat theme`
   (games-activity 4.4.0 GameActivity is an AppCompatActivity; our theme-less
   manifest). Fix `0415aeb`: application-level `@style/ActivityTheme`
   (`Theme.AppCompat.Light.NoActionBar` + cutout/fullscreen) — copied
   byte-equal from the agdk-eframe template's themes.xml.
2. Run 39519013682 RED — no rung output at all: action resolved
   `disable-linux-hw-accel auto → true` because the runner user lacked
   `/dev/kvm` permission ("ProbeKVM: This user doesn't have permissions to use
   KVM"), emulator booted with `-accel off` and died at the 600 s boot
   timeout. Fix `287c5e1`: classic udev rule
   (`KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"`
   + `udevadm control --reload-rules` + `udevadm trigger --name-match=kvm`;
   verified pattern from dotnet/maui eng/pipelines/common/enable-kvm.yml) as a
   workflow step before the rungs, plus `emulator-boot-timeout: 900`.
