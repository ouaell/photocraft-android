---
name: photocraft-port
description: Use at the start of any task in this repository, and whenever deciding what to build, how to prove it, or whether an edit is allowed. Entry point for the native Android port of the DESKTOP PhotoCraft app - reading order, foundation statements, the per-step protocol, upstream-read-only rules, and how to read pinned upstream files.
---

# photocraft-port — entry point

## Foundation (these are not options; a violation means stop and report)
- **A.** The product is the **desktop PhotoCraft** (`photocraft-ui-egui` + engine, the same code the macOS/Linux/Windows builds run) compiled **natively for Android**. It is **not** the web build, **not** a WebView/wrapper, **not** a new app.
- **B.** `upstream/` is a read-only git submodule at the commit in `UPSTREAM_PIN`. Nothing in it is ever modified, created or deleted. The shell lives in `android/`.
- **C.** The shell is platform glue only. No engine, tool, filter, format or UI logic is written here.
- **D.** "Works" is defined in `PLAN.md` §0.1 and made concrete row by row in `PORT-SPEC.md`. A script being green never decides success by itself.
- **E.** No real device exists until the end (M7). Everything before M7 is proven on CI emulators, and the plan's "device day" runbook prepares M7.

## Reading order (every milestone, and after any context compaction)
`AGENTS.md` → `PLAN.md` (§0, §4, §5.0, §6) → `PORT-SPEC.md` (the rows of the current milestone) → `STATE.md`.

## Read upstream without touching it
- `git -C upstream show HEAD:<path>` or plain `cat upstream/<path>` / `grep -rn` (read only). Never run cargo, fmt, or any generator with `upstream/` as the working directory.
- The cited desktop file in each PORT-SPEC row (`apps/photocraft/src/*.rs`, `apps/photocraft-web/src/web.rs` for structure only, `crates/*`) must be opened and read before implementing the Android counterpart.
- When a README, blog, other project, other model's review or this plan disagrees with the pinned/locked source code, **the source wins**; record it in `docs/decisions/`.

## Per-step protocol (PLAN §5.0)
1. Write the step spec in `STATE.md` (deliverable, files, reference file:line).
2. Do only that.
3. Compare your diff line by line with the reference; write each difference and why.
4. Fresh-context R-A reviews the diff.
5. Push; CI builds and runs the emulator; open the screenshots and write what you see.
6. Close only with: CI link + screenshot description + reviewer disposition.

## Hard stops
Two failed distinct fixes · anything needing a change in `upstream/` · a gate you cannot make fail on a seeded defect · a decision the plan does not contain · the urge to substitute the approach. Report format is in `AGENTS.md` R4.

## Android skills in this repo
The Android skills target Views/Compose apps. Use them for the **Kotlin shell and manifest only** (intents, permissions, tooling). Never introduce Compose or View-based UI: the UI is upstream's egui, drawn on one native surface.
