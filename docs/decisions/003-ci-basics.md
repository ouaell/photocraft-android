# Decision 003 — CI runner, KVM, Android CLI install, provisioning commands (M1)

Read-and-verified facts (each with source; date read: 2026-10-20):

## Runner
- **`ubuntu-24.04` (pinned explicitly, not `ubuntu-latest`).** Source:
  actions/runner-images README — `ubuntu-latest` moves to Ubuntu 26.04 in
  November 2026; the Ubuntu 24.04 image (20261004.327.1) ships Rust 1.99.0 /
  Cargo / Rustup 1.29.1, Temurin JDK **17.0.20 default** (`JAVA_HOME_17_X64`)
  and 21; explains why no extra JDK/rustup action is needed. A repo
  `rust-toolchain.toml` (official rustup mechanism) will pin the Rust
  version used by builds (crate needs ≥ 1.95, PLAN F3).
- **KVM on GitHub-hosted runners** (PLAN F15): udev lines from the
  android-emulator-runner README (official project):
  `echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules`
  then `sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=kvm`.
  First CI emulator job must still prove `/dev/kvm` is *usable*
  (android-ci-verification SKILL); if not, STOP (R4), never fall back
  silently to software emulation.

## Android CLI (the "reviewed CI setup script", R17)
- Install command (official page
  developer.android.com/tools/agents/android-cli/download, page updated
  2026-09-01): `curl -fsSL https://dl.google.com/android/cli/latest/linux_x86_64/install.sh | bash`
  (Linux x86_64, local/user install). Wrapped in
  `.github/scripts/setup-android-cli.sh`, which refuses to run outside
  `GITHUB_ACTIONS` (AGENTS R17). Android CLI is stable 1.0 since 2026-05-19
  (official blog).
- SDK provisioning (official command reference, page updated 2026-10-16):
  `android sdk install <package>[@<version>] [--beta|--canary|--force|--no-downgrade]`,
  package paths like `platforms/android-36`, `build-tools/36.0.0`,
  `ndk/28.2.13676358`, `system-images;android-36;google_apis;x86_64`
  (semicolon legacy form accepted); `android sdk list --all` to browse.
  `--sdk=PATH` selects the SDK dir. **UNVERIFIED:** license acceptance flow
  of the CLI in headless CI (no explicit `--licenses` documented for the
  CLI; sdkmanager's `--licenses` is for the old tool) — observe the first
  `android sdk install` run; if licenses block, resolve via
  `android auth`/env accepted at first run and record here.

## android-emulator-runner@v2 (inputs verified from action.yml at tag v2)
- `api-level`, `system-image-api-level`, `target` — valid targets include
  `default`, `google_apis`, `google_apis_ps16k`, `google_apis_playstore`,
  `google_apis_playstore_16k`, `aosp_atd`, `google_atd`, `android-desktop`,
  wear/tv/automotive variants. **16 KB page targets exist natively**
  (`*_ps16k` / `*_playstore_16k`) — matches PLAN F14's 16 KB requirement.
- `arch`: `x86_64` (emulator on CI) / `arm64-v8a` (limited API levels).
- Default `emulator-options`: `-no-window -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim`
  (matches F15's default GPU mode). Inputs `ndk` and `channel` available.
- **UNVERIFIED then pinned-by-SHA:** the action must be pinned by commit SHA
  (SKILL [verify] note) — pending before the first emulator job lands.

## Gradle/AGP/NDK/JDK matrix (official AGP release notes, read 2026-10-20)
- AGP **8.x supports compileSdk up to 35**; API 36 requires **AGP 9.0+**
  (community issue quoting the official release notes; re-verify on the
  official matrix page when picking versions).
- AGP **9.0.1** (Jan 2026): max API 36.1; **Gradle 9.1.0** min & default;
  SDK Build-Tools **36.0.0**; default NDK **28.2.13676358**; **JDK 17**.
- AGP 9.1 (Apr 2026): API ≤ 37.0, Gradle 9.3.1. AGP 9.4 (Sep 2026):
  Gradle 9.6.0. PLAN C13 requires `targetSdk=compileSdk=36` and
  `NDK ≥ r28`, `AGP ≥ 8.5.1` — **proposal: AGP 9.0.x + Gradle 9.1.0 +
  NDK 28.2.13676358 + JDK 17** (final pick recorded when the Gradle files
  are written, M1-4).

## Decision
Use the pinned facts above for CI and build provisioning; pin every version
in files (never "latest"); record each UNVERIFIED item's resolution here by
editing this file in the task that observes it.

What would invalidate: any of the cited pages changing materially (page
updated-at dates quoted); CLI install URL moving; 16 KB targets disappearing
from the runner action.
