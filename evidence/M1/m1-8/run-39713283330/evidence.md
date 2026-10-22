# M1-8 — emulator-e2e evidence (run 39713283330, all steps green)

Workflow `.github/workflows/emulator-e2e.yml`, job `emulator-e2e`, run
https://github.com/ouaell/photocraft-android/actions/runs/39713283330
(commit `76c7db4`, "fix 3f"). All three required checks green on that commit:
`guard` (39713283329), `build` (39713283373), `emulator-e2e` (39713283330).
Full artifact: `emulator-e2e-39713283330` (the `rungs/` tree; the small,
load-bearing part of it is copied into `run-39713283330/` here - the full
logcat stays in the CI artifact).

## Step verdicts (all green)

| step | verdict | what it proves |
|---|---|---|
| `rungDefault` (wgpu auto on SwiftShader) | success | the ladder selects a rung, the app reaches the ready marker, the parity fields and the ladder record are present, the oracle is clean |
| `rungGles` (`WGPU_BACKEND=gles`) | success | the same on the GL rung |
| `rungCpu` (`PHOTOCRAFT_CPU_CANVAS=1`) | success | the same on the CPU-compositor rung |
| `rungDefault` at api 31 | success | the api-31 gate (decision 011 amendment 4): the UI works AND the Vulkan rejection is recorded |
| `rungDefault` at api 36 | success | the same matrix at api 36 |
| `api 34: Back press then relaunch` | success | the re-entry gate: Back → the app leaves → the process ends → a NEW pid comes up with the UI |
| `api 34: forced crash then relaunch` | success | the re-entry gate: the forced crash happens → the crashed pid is gone → a NEW pid comes up with the UI, the one-shot marker skipped the second crash |

## The two re-entry gates in detail

### `rungs/back/` (Back → relaunch)

- `pid.txt`: `pid=3791` / `ready=yes` / `pid=4658 (relaunch)` / `ready=yes`.
- `scenario-boot1.txt`: `scenario boot 1: Back pressed, pid 3791 exited cleanly`.
- `logcat-boot1-excerpt.txt`: `Picsh: Back key pressed; asking the app to close`
  (03:12:45.015) then `Picsh: leaving: the app quits; the process ends`
  (03:12:45.024) - the shell's leave hook, 9 ms later.
- `result.json`: `{"rung":"back","package":"io.github.ouaell.picsh","scenario":"back","pid":"4658","oracle":"green"}`.
- **Recorded, not judged:** the leave ends the process inside the Java→native
  frame, so ART tears the runtime down while the render thread is still in a
  JNI call. The boot-1 log therefore contains
  `JNI DETECTED ERROR IN APPLICATION: thread ... "android_main" using JNIEnv*
  from thread ... "main"` + the ART abort. The Back gate judges everything UP TO
  the leave line (clean) and records the teardown lines after it
  (`boot1-fatal.txt` in the CI artifact). A clean leave path is an open
  decision - see decision 011 amendment 8, item 13.

### `rungs/crash/` (forced crash → relaunch)

- `pids.txt`: **two pids** at boot 1 - `pids=3516 3673`. This is exactly the
  case that made the OLD script red: it stripped the whitespace and used the
  concatenation (`35163673`) as one pid, so `adb logcat --pid=35163673` matched
  nothing and the crash payload check failed on a crash that had happened.
- `scenario-boot1.txt`: `scenario boot 1: forced crash observed in pid 3516,
  that pid is gone`.
- `logcat-boot1-excerpt.txt`: `Picsh: PHOTOCRAFT_TEST_CRASH knob: forcing the
  one-shot crash now` in pid 3516, and the ART panic line
  `PHOTOCRAFT_TEST_CRASH` from the same pid.
- `logcat-pid-excerpt.txt` (the RELAUNCH, pid 3920):
  `Picsh: device request: Limits::default {...}` (exactly one) and
  `Picsh: PHOTOCRAFT_TEST_CRASH already fired once (marker
  /data/user/0/io.github.ouaell.picsh.crash/files/config/picsh-test-crash.txt);
  staying up` - the one-shot marker did its job.
- `result.json`: `{"rung":"crash","package":"io.github.ouaell.picsh.crash","scenario":"crash","pid":"3920","oracle":"green"}`.

## Rendering rungs (the ladder record per rung)

| rung | ladder | device request | System Info |
|---|---|---|---|
| default | `gpu-ladder.txt`: vulkan (SwiftShader) | one `device request:` line | `system-info.txt` present |
| gles | gl (Android Emulator OpenGL ES Translator) | one | present |
| cpu | CPU compositor (`PHOTOCRAFT_CPU_CANVAS=1`) | one | present |
| default-api31 | vulkan REJECTED, gl selected (amendment 4) | one | present |
| default-api36 | vulkan (SwiftShader) | one | present |

The api-31 rung is the user-approved gate of decision 011 amendment 4: it passes
only if the UI works AND the Vulkan rejection is recorded - both are in
`default-api31/gpu-ladder.txt` and `default-api31/parity.green`.

## R8 — screenshots (viewed with vision)

The run's screenshots are in the CI artifact (`rungs/<rung>/screenshot-1..3.png`,
`screenshot-boot1.png`). The Back rung's boot-1 shot and the post-relaunch shot
show the REAL PhotoCraft UI: the top menu row (`File Edit Image Layer Type
Select Filter`), the left tool rail, the brush options row, the right panel
with the `Swatches / Gradients / Patterns` tabs and a gradient strip, the bottom
status bar `No document`, and the app's own modal `Switched to CPU rendering`
("GPU acceleration could not continue. Your documents are unchanged. ...
PhotoCraft is using the CPU image compositor. ... Retry GPU requires a
restart." with `Keep Using CPU` / `Retry GPU`). Text renders correctly (no
tofu), nothing is blank, and the modal is the pinned upstream notice
(`main.rs:415-437`, decision 011). The emulator image is 320x640, so the right
edge of the panel is cut - the narrow-window layout, not a defect.

## Fix history of the two re-entry gates (R7)

1. Run 39615314265: the Back gate red - "pid 1 did not exit within 90s of
   Back". Root cause: nothing acted on the Android Back key (decision 011
   amendment 5).
2. Run 39623279397: the Back gate red again, now with the failure-path
   evidence (fix 3c) - the app was healthy, the key press was visible in the
   logcat.
3. Run 39672720132: the Back gate GREEN (fix 3d), the CRASH gate red - the
   pid-list concatenation (decision 011 amendment 6).
4. Run 39689236795: `rungGles` red - the platform destroyed the activity while
   the process survived, and `am start` could not recover (decision 011
   amendment 7).
5. Run 39713283330: **all steps green** (fix 3f).
