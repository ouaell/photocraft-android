# DESIGN decision: versioning scheme for Picsh (BR-6)

**Question:** How should the Android app's `versionName` and `versionCode` be defined and derived? The shell is versioned independently of upstream PhotoCraft (the desktop app has no concept of an Android platform version).

**Decision:** versionName tracks upstream's tag (e.g. `v0.8.2` → `0.8.2`). versionCode is derived from versionName as:

```
versionCode = major * 10000 + minor * 100 + patch
```

For `0.8.2`: `0 * 10000 + 8 * 100 + 2 = 802`.

**Rationale:** This scheme is monotonic for any increasing version, self-documenting (you can read the version from the code), and never collides for any reasonable version sequence. It is the common Android convention.

**Files:** `android/app/build.gradle` defines `versionName` and derives `versionCode` from it at build time (no separate `versionCode` constant).

**Verification:** `scripts/guard-upstream.sh` does not check this; the build itself validates the derivation (a bad version string fails the Gradle build). A reviewer can verify by reading `android/app/build.gradle`.
