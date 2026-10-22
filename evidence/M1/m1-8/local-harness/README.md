# M1-8 — local harness proof (mock `adb`, no emulator)

These scripts prove the **harness logic** of `scripts/e2e-rung.sh` without an
emulator: a mock `adb` serves a scripted device (pids, logcat, lifecycle
events), and the real script is run against it.

They are NOT a substitute for the CI gates — the CI runs the script against a
real emulator (run ids in `../evidence.md`). They exist so that a reviewer can
re-run the pid/teardown/crash logic on a machine without an emulator, and so
that the claims in `STATE.md` and `docs/decisions/011-gpu-device-limits.md`
are checkable (R2).

## Run them

```bash
cd <repo root>
bash evidence/M1/m1-8/local-harness/pid-logic.sh       # 20 checks: the pid handling
bash evidence/M1/m1-8/local-harness/crash-scenario.sh  #  9 checks: the crash scenario
bash evidence/M1/m1-8/local-harness/back-scenario.sh    # 11 checks: the Back scenario
```

Each script prints one `ok`/`FAIL` line per check and ends with
`ALL ... CHECKS PASS` (exit code 0) or `SOME CHECKS FAILED` (exit 1). The
output of the runs that accompanied the fixes is in `output/`.

## What each one covers

| script | covers |
|---|---|
| `pid-logic.sh` | two pids from `pidof` (the list is kept, `PID` is the first entry), no pid-prefix match, dead/live liveness, the 90 s bounds of `pid_gone`/`pkg_gone`, per-pid `capture_logs`, the crash matcher (it must NOT fire on the "already fired once" line), the threadtime pid extraction |
| `crash-scenario.sh` | the crash event found in the SECOND of two pids; no crash event → red; "already fired once" alone → red; the whole-logcat fallback finds a crash whose pid was never listed; a torn-down activity is force-stopped and relaunched, and the crash is then found |
| `back-scenario.sh` | the leave line found in the second of two pids; no leave line → red; a torn-down activity (before the ready marker, and after it) is force-stopped and relaunched and the leave is then found; a first boot that died with a FATAL error is red, not retried |

The mock models the device faithfully enough for these paths: `am start`
counts launches, `am force-stop` ends the current launch, `pidof` answers with
the launch's pid list (empty once the app left or crashed), `input keyevent 4`
makes the app leave, and the logcat is served per pid.
