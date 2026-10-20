#!/usr/bin/env bash
# skills-integrity.sh — fails if any vendored third-party skill differs from the reviewed, pinned copy
# (.opencode/skills/MANIFEST.sha256), or if a file exists in a vendored skill directory that the manifest does not list.
# Project-owned skills (photocraft-port, eframe-android-shell, android-ci-verification) are protected by CODEOWNERS instead.
set -u
cd "$(dirname "$0")/.." || exit 2
S=.opencode/skills; M=$S/MANIFEST.sha256; fail=0
[ -f "$M" ] || { echo "SKILLS: manifest missing" >&2; exit 2; }
( cd "$S" && sha256sum --quiet -c MANIFEST.sha256 ) || { echo "SKILLS: a vendored file changed or is missing" >&2; fail=1; }
# unlisted extra files inside vendored dirs
vend=$(cut -d/ -f1 <(awk '{print $2}' "$M") | sort -u)
for d in $vend; do
  [ -d "$S/$d" ] || continue
  while IFS= read -r f; do
    grep -qF -- "  ${f#$S/}" "$M" || { echo "SKILLS: unlisted file ${f#$S/}" >&2; fail=1; }
  done < <(find "$S/$d" -type f)
done
[ "$fail" -eq 0 ] && echo "SKILLS: OK (vendored skills match the reviewed manifest)"
exit "$fail"
