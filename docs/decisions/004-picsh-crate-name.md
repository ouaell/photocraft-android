# Decision 004 — Shell crate named `picsh` (not `photocraft_android`)

- **Question:** PLAN.md drafts refer to the Android platform-shell crate as `photocraft_android`; the actual [package] in `android/Cargo.toml` and every committed lock/parity artifact carry the name `picsh`. Which name is correct, and why was `picsh` chosen?

- **Sources:**
  - User decision 002 in this repo (`docs/decisions/002-app-id.md`): the user approved the App-ID / display name **Picsh** for this port ("Picsh: PhotoCraft on Android"); the user also works from `C:\Users\chamso\Documents\Picsh`.
  - `android/Cargo.toml` `[package] name = "picsh"` (crate-type `cdylib` → `libpicsh.so`); `android/Cargo.lock` verified against the CI artifact `generated-cargo-lock` of run `39433683527` (`cmp` byte-identical, commit `5dc1c96`).
  - PLAN.md v3.2 first uses `photocraft_android` only as a draft label; no builder artifact from any locked runner ever references that name.

- **Decision:** the crate is and stays `picsh`. The user picked the displayed product name "Picsh" (decision 002), and the shell crate follows it so `libpicsh.so` matches the Gradle `System.loadLibrary("picsh")` wiring and all existing parity artifacts. PLAN.md's `photocraft_android` is treated as an editorial placeholder, not a normative name. No rename exists in any milestone deliverable.

- **What would invalidate it:** the user explicitly requesting the crate be renamed to `photocraft_android` (rule R3/M-report protocol: that is a user decision, never an agent one), which would then be a dedicated gated task touching `[package] name`, the Gradle jniLibs loader, lock parity, and⊂ every artifact referencing `libpicsh.so`.
