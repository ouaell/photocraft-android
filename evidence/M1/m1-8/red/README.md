# M1-8 — seeded RED proof of the two re-entry gates (R3)

AGENTS.md R3: "A new gate must be shown RED on a deliberately seeded defect
first (red→green proof, logs kept in `evidence/`)".

## The seeded defect

Branch `redproof/m1-8-exit-guard` (commit `3d82317`, based on the green
`684a914`), **not** merged into `main`: the re-entry exit guards were removed on
purpose.

- `android/src/services.rs`: the `Services::quit` hook logs
  `Picsh: leaving: the app quits; the process ends` but does **not** end the
  process.
- `android/src/lib.rs`: `android_main` logs `Picsh: android_main done; exiting
  the process for a clean next launch` but does **not** end the process.

## The run

https://github.com/ouaell/photocraft-android/actions/runs/39723970105
(artifact `emulator-e2e-39723970105`; `guard` 39723970115 and `build`
39723970151 green on the same commit - the defect is in the app, not in the
build).

| step | verdict | what it proves |
|---|---|---|
| `rungDefault`, `rungGles`, `rungCpu`, api 31, api 36 | **success** | the seed broke nothing but the re-entry path: the five rendering rungs do not depend on the exit guards, so a red there would have meant the seed was not specific |
| `api 34: Back press then relaunch` | **failure** | the Back gate detects the defect |
| `api 34: forced crash then relaunch` | **failure** | the crash gate detects the defect |

## What the two red steps said

`back/scenario.red`:

```
scenario RED: pid 4138 did not exit within 90s of Back (evidence: logcat-onred-*.txt, activities-onred.txt, screenshot-red.png)
```

`back/result.json`:
`{"rung":"back","package":"io.github.ouaell.picsh","scenario":"back","pid":"4138","result":"red","gate":"scenario"}`

`crash/scenario.red`:

```
scenario RED: the crashed pid 3054 is still alive 90s after the forced crash
```

`crash/result.json`:
`{"rung":"crash","package":"io.github.ouaell.picsh.crash","scenario":"crash","pid":"3054","result":"red","gate":"scenario"}`

Both red messages name exactly the property the gate exists for: the app's
process must END (after the leave, after the crash).

## The green counterpart

The same gates on the un-seeded code: run **39713283330** (commit `76c7db4`),
all 19 steps green - `Back pressed, pid 3791 exited cleanly` and
`forced crash observed in pid 3516, that pid is gone`. The evidence of that run
is in `../run-39713283330/`.

The branch was deleted after the run; the red logs are kept here.
