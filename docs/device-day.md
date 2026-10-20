# Device-day runbook (draft by the planner; the agent completes and verifies every command in M6)

Purpose: the first hour with a real device must yield the maximum information with no improvisation. Everything here is prepared on CI emulators beforehand; commands marked **[verify]** are checked against official docs at M6.

## 0. Before the device arrives (checklist, all done on CI)
- [ ] Release-candidate APK (debug-signed copy for install) and the log-export action built and attached to the CI run.
- [ ] The three rendering rungs (Vulkan, GLES, forced CPU) each launched on CI emulators with screenshots and logs.
- [ ] "Start in safe graphics mode" launcher shortcut works on the emulator.
- [ ] A one-page **how to enable USB debugging and wireless debugging** for the person lending the device (Android developer options) — written in plain language, with screenshots from the emulator.
- [ ] A sample set of documents (small PNG, large JPEG, PSD, HEIC, a corrupt file) bundled in `evidence/samples/` and pushable with `adb push`.

## 1. First ten minutes (collect facts)
1. `adb devices` shows the device **[verify]**; record model, Android version, SDK level, ABI, RAM, screen size and density (`adb shell getprop …`, `adb shell wm size`, `adb shell wm density`) **[verify]**.
2. Install: `adb install -r photocraft-android.apk`; start the app; capture the first screenshot.
3. Pull the app's own diagnostics (log export, GPU adapter name/backend/driver/limits vs upstream's required defaults, selected rendering rung, detected RAM, locale, config dir, `temp_dir`).
4. `adb bugreport` saved only if something crashed **[verify]**.

## 2. Rendering (the single largest unknown)
Run the sample document on each rung and record: starts / doesn't start, frame feel, screenshot. Order: automatic → forced GLES → forced CPU → safe-graphics shortcut. A crash on any rung is the most valuable finding: keep the marker file and the log (SU-8).

## 3. Input checklist (each ends with a screenshot or log)
Touch: one-finger draw; two-finger pan/zoom/rotate with **no mark on the document** (compare document hash before/after); pen: pressure ramp, tilt, eraser end, palm resting; soft keyboard: type, composing (the device's default keyboard and any alternative installed), paste; hardware keyboard shortcuts; mouse hover/right-click/wheel if available; desktop mode if the device offers it.

## 4. System integration
Open/save through the file picker; open from another app (VIEW/SEND); rotate; split-screen/freeform window if available; Back at each UI depth; background → foreground; `adb shell am kill` recovery; dark mode; font scale 200%.

## 5. Measurements (PK-5)
Open/save times and frame behaviour for the standard documents; input-to-ink latency measured by the agreed method; compare with the desktop numbers.

## 6. Reporting
Fill `evidence/M7/<device>/REPORT.md`: device facts, rung results, input results, defects (with screenshot/log paths), and a one-line verdict per PORT-SPEC row that needed hardware. Defects go back as shell-only fixes in one reviewed batch.
