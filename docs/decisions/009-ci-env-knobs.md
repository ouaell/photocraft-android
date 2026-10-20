# Decision 009 — M1 CI probes, emulator life-sign matrix, and how rung env knobs are delivered

- Date: 2026-10-20
- Status: decided
- Related: decisions 004 (3-GPU ladder problem), 008 (toolchain build workflow); M1 stage d; SKILL emulator workflow
- Depends on: U-E (minSdk probes), U-G (accesskit-on-GameActivity probe), UB (AAssetManagerSlides), UC (multithreaded renderers), CLIP (text clipping), the desktop regressions, error-handling strands.

## Question

PLAN §5.3 requires the 15 probes soldiers plus the `emulator-e2e` required check to
leave CI featuring 3 rungs: screenshots, logcat evidence, and per-rung JSON; the
probes must be REVERSED. Also: an env-only-in-CI mechanism must force
`WGPU_BACKEND=gles`, and another force CPU canvas. HOW are the knobs delivered?

## Sources

- `reactivecircus/android-emulator-runner` `action.yml` at pin
  `e89f39f1abbbd05b1113a29cf4db69e7540cae5a` (v2.37.0, via GitHub API, 2026-10-20):
  inputs verified including `api-level`, `target` (greenlisted: `google_apis`,
  `google_apis_playstore_16k` exist), `arch` (`x86_64`), `avd-name`, `cores`,
  `ram-size`, `emulator-boot-timeout`, `emulator-port`, `emulator-options`
  (the action's own default is `-no-window -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim` — identical to what we pass), `script` (required), `pre-emulator-launch-script`, `working-directory`.
- `android-activity 0.6.1` source (crates.io tarball, read 2026-10-20):
  - `AndroidApp::asset_manager()` is public on the **Application-scoped** asset
    manager (game_activity/mod.rs); a leaked global JNI reference in the crate
    makes the handle `'static`-stable, so the call needs **no JNIEnv** at the
    call site and is valid on the GameActivity main thread.
  - `ndk 0.9.0` `src/asset.rs`: `AssetManager::open(&self, filename: &CStr) ->
    Option<Asset>` (streaming mode); `Asset::buffer(&mut self) -> io::Result<&[u8]>`
    via `AAsset_getBuffer`.
- adb cannot inject env vars into a Zygote-spawned app on the stock emulator;
  the `wrap.<package>` zygote property restart trick is UNVERIFIED on this image
  and rejected as too fragile for a gate (no per-rung evidence possible).
- `android-activity 0.6.1` exposes no launch-intent/extras API (no Intent
  accessor exists in its init.rs/main_callbacks.rs either).

## Decision

### Rung knob delivery (the CI env ladder)

Each rung variant is a **separate APK** whose Gradle flavor bundles the knob file:

- Flavor `rungDefault` (no suffix, no knob file) — wgpu auto backend.
- Flavor `rungGles` (`applicationIdSuffix '.gles'`) bundles `assets/picsh-knobs.txt`
  with `WGPU_BACKEND=gles`.
- Flavor `rungCpu` (`applicationIdSuffix '.cpu'`) bundles `assets/picsh-knobs.txt`
  with `PHOTOCRAFT_CPU_CANVAS=1`.

At boot, `jni_bridge::apply_asset_knobs(app)` reads the asset BEFORE anything else
(some knobs influence `RUST_LOG`, so before the logger binds) and applies each
`KEY=VALUE` line **through one fixed allowlist only:
`WGPU_BACKEND | PHOTOCRAFT_CPU_CANVAS | RUST_LOG | WGPU_VALIDATION_INDIRECT_CALL`**;
unknown keys are logged and skipped; the setter lives in `jni_bridge.rs` inside
the module's BR-5 invariant block. `androidResources { noCompress 'txt' }` keeps
the knob asset stored uncompressed so `AAsset_getBuffer` reliably returns data.

Three `productFlavors` replace plain variants in `build.yml` as
`assembleRungDefaultDebug/Release` and in the e2e as three debug apks; manifest,
identities and paths otherwise unchanged.

### The `emulator-e2e` workflow (single required check)

One job, named for the branch protection's required check id, runs:

1. Toolchain build (identical pin discipline to `build.yml`): rustup targets,
   NDK pick, `cargo-ndk 4.1.2 --locked`, both ABIs, `CRAFT_FONTS_REQUIRED=1`,
   then `gradle assembleRungDefaultDebug assembleRungGlesDebug assembleRungCpuDebug`.
2. **Logcat-oracle red proof, no emulator (R3)** — seeded log with `FATAL
   EXCEPTION` must trip the grep (red observed); a clean one-line log must not
   (baseline green). Both prints kept to `e2e/redproof/`.
3. **KVM proof**: `/dev/kvm` presence logged to `e2e/kvm.txt` (never silently
   hidden; software fallback would also boot slower but is still allowed and
   recorded).
4. Three rungs, each its own `android-emulator-runner` invocation (free AVD) at
   api 34, target `google_apis`, arch x86_64, SwiftShader, calling
   `scripts/e2e-rung.sh <rung> <pkg> <apk>`: install fresh (uninstall first),
   `am start`, poll pid ≤ 60 s, 3 screenshots via `adb exec-out screencap`,
   full + pid-scoped `logcat -d` dumps, run the red-proofed oracle grep
   (`FATAL EXCEPTION|ANR in .|Fatal signal 11|signal 11|panicked at|JNI DETECTED
   ERROR|UnsatisfiedLinkError|Validation Error|Device lost|StrictMode|invalid
   local reference`), write `rungs/<rung>/{result.json,oracle.*}`, then
   `force-stop`, `uninstall`, `adb emu kill`. Screenshot meaning is written into
   `evidence/M1/m1-7/` by the review step — screenshots are never interpreted as
   passing without a written description in the run evidence.
5. Artifact `emulator-e2e-<run_id>`: toolchain facts, redproof, kvm, rungs/ trees.

### What invalidates this

- `android-activity` gaining (or needing) a different AssetManager handle than
  `AndroidApp::asset_manager()` (would show as a compile error, not silently).
- A runner image whose `logcat` lacks `--pid` (then the oracle runs on the full
  dump and system noise must be added to the invalidation notes).
- Emulator-runner inputs renaming again at a pin bump (inputs are verified at
  every bump).
- The knobs asset being compressed after all (a rung reads a `None`/empty buffer
  and the rung log will show Picsh warning "could not buffer or no asset": that
  would falsify the rung claim and must be investigated, not retried.
