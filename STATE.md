# STATE.md

Pin: tag v0.8.2 / d43db3e153c76aefce9b32cef9099e458eaf17a8 (see UPSTREAM_PIN)
Current milestone: M1 (in progress)

| Milestone | Status | Evidence (CI artifact links) |
|---|---|---|
| M1 real PhotoCraft UI on emulator (+ guard/parity shown red once) | open | |
| M2 touch, pinch/pan, insets, fonts | open | |
| M3 text input on real keyboards | open | |
| M4 open/save + export oracle | open | |
| M5 lifecycle/autosave + Back | open | |
| M6 full pen, mouse/desktop mode (Adaptive Tier 1/2/3 checklist), clipboard, polish, matrix | open | |
| M7 real devices: phone, tablet/foldable in desktop mode, stylus; latency numbers | open | |

## PORT-SPEC rows (one line per row: done (evidence) | n/a (reason) | open)
BR-1..7 · SU-1..14 · RB-1..20 · SV-1..10 · PB-1..11 · AO-1..7 · PK-1..6 · DL-1..4 — all open.

## Open questions (PLAN §2: U-A … U-J)

## Decisions (one file per decision in docs/decisions/)
- `docs/decisions/001-license-noncommercial.md` — repo public; maintainer additions = PolyForm Noncommercial 1.0.0; `upstream/` stays MIT OR Apache-2.0 (user decision 2026-10-20: public repo, no commercial use).
- `docs/decisions/002-app-id.md` — display name **Picsh**, applicationId **io.github.ouaell.picsh** (user decision 2026-10-20).

## M1 step log (§5.0 protocol, one block per step)
### M1-1 repository at CI-ready state
- **Spec (step 1):** deliver the repo on GitHub with its guard rails so every later M1 step can be proven by CI runs and leggings: (a) private→public push, (b) `.github/CODEOWNERS` marking protected paths (START-HERE step 4), (c) branch protection on `main` (required PR + 1 approval + required checks `guard`,`build`,`emulator-e2e`), (d) license plan recorded. Files touched: `.github/CODEOWNERS` (instructed by START-HERE), `LICENSE` (root, PolyForm-NC verbatim), `docs/decisions/001,002`, STATE.md. Reference: START-HERE.md steps 3–4; AGENTS.md R3/R6; PLAN §5.1.
- **Environment note:** branch protection is not available for *private* repos on the free plan (403); user made the repo public + chose noncommercial licensing. Protection now active: `https://api.github.com/repos/ouaell/photocraft-android/branches/main/protection`. `enforce_admins=false` (sole maintainer must keep bypass to merge); protocol: the agent pushes to `main` under the rules and never edits protected paths without explicit user instruction.
- **Step executed (self-check findings, R7):** seed A (modified `upstream/README.md` in a scratch clone) → `guard-upstream.sh` exit 1, log `evidence/guard-red/seedA-upstream-modified.log` (re-captured post-`.gitattributes`; the guard output is CRLF-insensitive, content identical). Seed B (modified `rust-jni/SKILL.md`) → exit 1 **but for the wrong reason**: in a fresh Windows clone, `MANIFEST.sha256` is checked out with CRLF (git autocrlf), so every manifest path ends in CR ("FAILED open or read" flood) and the actual hash-mutation check never ran (`evidence/guard-red/seedB-skill-modified.log`). **Fix:** `.gitattributes` with `* -text` (byte-identical checkouts; the guards compare bytes, so this is a requirement, not a style choice). Post-fix re-captures: valid seed B with the SPECIFIC reason (`rust-jni/SKILL.md: FAILED`, "1 computed checksum did NOT match") in `seedB-skill-mutated.log`; seed C (unlisted extra file) exit 1 (`SKILLS: unlisted file rust-jni/UNLISTED-extra.md`) in `seedC-skill-unlisted-file.log`; pristine baseline re-checked green in the fresh clone. The pre-fix seed-B log is kept as documentation of the discovered defect.
- **Green:** CI `guard` green on 92154d7 https://github.com/ouaell/photocraft-android/actions/runs/39422497113 and on 673fb64 https://github.com/ouaell/photocraft-android/actions/runs/39423004057 (artifact `guard-logs-39423004057`).
- PENDING: reviewer R-A disposition; CI link (first workflow run lands with this commit); re-run of red proofs in a post-`.gitattributes` clone.
- **R-A review (fresh context, read-only): "approved with findings", all 4 findings dispositioned in commit [this]:**
  1. LOW spec omission of `.gitattributes` in M1-2 spec line → fixed: added above (root cause documented; user-approved in-session).
  2. LOW missing post-fix seed A artifact → fixed: seedA log re-captured in guard-red2 run (content identical, as predicted), STATE now says so.
  3. MEDIUM `/.github/scripts/` missing from CODEOWNERS → fixed: line added (protective; the sole installer file is now also codeowner-gated).
  4. LOW/informational missing decision refs (checkout SHA pin, installer URL page-level verification) → fixed: `docs/decisions/003-ci-basics.md` records verified facts + UNVERIFIED items (checkout action SHA pin still pending before first emulator job; `android sdk` license flow to observe on first install).

### M1-2 CI guard pipeline + red proofs for guard-upstream & skills-integrity
- **Spec (step 1):** deliver (a) `.github/workflows/guard.yml` — job `guard` on ubuntu-24.04: checkout with submodules, run `scripts/guard-upstream.sh` + `scripts/skills-integrity.sh`, upload logs always (even red); (b) `.github/scripts/setup-android-cli.sh` — the SOLE user-approved installer wrapper (curl|bash of `dl.google.com/android/cli/latest/linux_x86_64/install.sh`, refuses to run outside `GITHUB_ACTIONS`, R17); (c) `evidence/guard-red/` logs — seeded-defect FAIL runs of both guards executed in a disposable scratch clone OUTSIDE this workspace (upstream here stays untouched, R1): case A modified `upstream/README.md`, case B modified vendored skill file; then both guards re-run green in the CI job (the workflow run = green artifact). Files: `.github/workflows/**`, `.github/scripts/**`, `scripts/` none (existing untouched), `evidence/**`, `STATE.md`, plus `.gitattributes` (added mid-step: byte-exact checkouts required by the byte-comparing guards; R-A finding 1). Reference: PLAN §5.1/§5.2, F20, android-ci-verification SKILL, runner-images README (ubuntu-24.04), actions/checkout@v6 (SHA-pin tracked in decisions).

## Notes (2026-10-20, agent)
- Reading round complete: AGENTS.md, PLAN.md (v3.2), PORT-SPEC.md, STATE.md, SETUP run.
  `setup.sh` OK: `GUARD: OK` / `SKILLS: OK`; commit `d572cd1` "Import plan bundle and pin upstream" (local, not pushed yet).
- Project skills read: photocraft-port, eframe-android-shell, android-ci-verification; opencode.json allowlist noted.
- Local machine (Windows 10/11 PowerShell): git 2.54; gh CLI authed (`ouaell`,be repo+workflow); Android SDK at `%LOCALAPPDATA%\Android\Sdk` with NDK 27/28.2/30.0, emulator, platform-tools; Java 17; Python 3.12. **No Rust toolchain, no gradle shell, no local emulator confirmed yet** — per plan, builds+emulator run in GitHub Actions CI; local R-A/R-B reviews read diffs.
- Copy of upstream at pin v0.8.2 exists at `upstream/` (submodule, read-only).
- Blocking user decisions before any M1 file is written (START-HERE "قراراتك المطلوبة"): (1) GitHub repo to push to; (2) app display name + applicationId; (3) approval of the CI setup script (curl|bash from dl.google.com only); (4) minSdk — after evidence is presented.
