# Skills provenance and vetting (2026-10-14)

Skills are instructions an agent obeys. Third-party skills here are **vendored copies at pinned commits**, reviewed before use, listed in `MANIFEST.sha256`, enforced by `scripts/skills-integrity.sh` in CI, protected from agent edits by `opencode.json`, and enabled only through the `permission.skill` allowlist. To update one: a human re-reads the diff, regenerates the manifest, and approves the PR.

| Source | Pinned commit | Licence | Enabled now | Vendored, disabled until needed | Reviewed and NOT installed |
|---|---|---|---|---|---|
| `github.com/android/skills` (official, Google) | `5bda39f154fb859a08d45e2392f3568e049f83fb` (2026-10-14) | Apache-2.0 | `android-cli`, `android-intent-security` | `android-permissions-security` (M5), `android-profiler` (M7), `play-policy-insights` (M6: five Python scripts incl. a Play Store scraper; a human reads them first) | `edge-to-edge`, `navigation-event`, `adaptive`, `testing-setup` (Compose-centred), `agp-9-upgrade` (only if M1 chooses AGP 9), `r8-analyzer`, camera/cars/media/TV/Wear/XR/identity/AI/billing skills |
| `github.com/po4yka/rust-skills` (community; single author, 2 stars, CI type-checks its Rust examples on Rust 1.98) | `6786362aa24bb67d183b6e5dac5e35cf56db0069` (2026-10-09) | BSD-3-Clause | `rust-jni`, `rust-android-build`, `rust-panic-safety`, `ffi-error-progress-cancel`, `rust-debugging`, `rust-observability`, `cargo-workflows`, `rust-native-linking`, `rust-unsafe`, `rust-lints`, `rust-security` | — | `rust-performance` (host `sudo` sysctl recipes) and every Swift/UniFFI/wasm/embedded/database/CLI/networking/serde/macro/type-system skill |
| Project-owned | this repository | — | `photocraft-port`, `eframe-android-shell`, `android-ci-verification` | — | — |
| Evaluated elsewhere | — | — | — | — | `Nagarjuna2997/android-agent-skill` (developer preview v0.1.0; ships an MCP server; duplicates the official Android CLI); `eguidev` (needs instrumentation inside the app's widget code — impossible without changing upstream) |

## Vetting performed
- Pattern scan of every allowlisted skill including `references/`: no prompt-injection phrasing, no exfiltration, no obfuscation. Hits and decisions: `rust-performance` references contain `sudo` sysctl commands → excluded; `android-cli` contains the official `curl … | bash` installer from `dl.google.com` → allowed only inside the reviewed CI setup script (AGENTS R17); `play-policy-insights` ships Python scripts → disabled until read.
- Content read: headings and frontmatter of every enabled skill; `rust-android-build`'s 16 KiB policy matches PLAN F14; `rust-jni`/`rust-panic-safety` match the JNI/`catch_unwind` rules in the plan.
- Compose-centred Android skills were rejected deliberately: they would steer the agent toward Compose/View UI, which this port must never contain.
- File types: text only, except two Perfetto `.pftxt` text configs in `android-profiler`.

## Rule
If any skill contradicts the pinned source code, the locked crate sources or official Android documentation, the source/docs win (AGENTS R14) and the contradiction is recorded in `docs/decisions/`.
