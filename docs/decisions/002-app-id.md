# Decision 002 — App display name and applicationId

- **Question:** what display name and Android `applicationId` does this
  derivative port use (SU-13 keeps upstream's `ai.storyteller.photocraft`
  *if and only if* the user decides so; upstream's ArtCraft name/wordmark/
  logo are not licensed for forks, PORT-SPEC DL-2)?
- **Sources:** user decision, session 2026-10-20 ("الاسم الخاص هو اسم الملف
  مجلد المشروع الحالي" — the name of the current project folder: *Picsh*;
  repo chosen: private→public `ouaell/photocraft-android`). `AGENTS.md` R18
  forbids adopting upstream branding.
- **Decision:**
  - Display name / user-facing title: **Picsh**
  - `applicationId`: **`io.github.ouaell.picsh`**
  - Launcher icon and splash: user's own artwork (placeholder in M1/M6;
    BR-2 placeholder accepted only until RB-2 final icon in M6).
- **What would invalidate it:** the user renaming the app before first
  release; a Play Store conflict on the same `applicationId`; the user later
  acquiring a commercial license from upstream that changes branding rules.
