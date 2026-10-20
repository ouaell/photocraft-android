#!/usr/bin/env bash
# craft-fonts-pin.sh - BR-2: the shell must embed craft-fonts at the commit upstream's
# release.yml pins (`craft-fonts-ref`) so official-releases fonts match. Reads the ref
# from upstream/.github/workflows/release.yml at the pin and compares it with
# android/craft-fonts-ref. A mismatch = the fonts pin has drifted and must stop the build.
set -u
fail=0
say() { printf 'FONTS: %s\n' "$*" >&2; }

UP="${UPSTREAM_DIR:-upstream}"
REL="$UP/.github/workflows/release.yml"
REFN="android/craft-fonts-ref"

[ -f "$REL" ] || { say "missing $REL (upstream changed?)"; exit 2; }
[ -f "$REFN" ] || { say "missing $REFN - record the pin ref there"; exit 1; }

want="$(sed 's/\r$//' "$REL" | grep -E 'craft-fonts-ref:[[:space:]]*[0-9a-f]{40}' | head -1 | grep -oE '[0-9a-f]{40}')"
if [ -z "$want" ]; then say "no craft-fonts-ref in $REL"; exit 1; fi
want="${want%$'\r'}"
have="$(sed 's/\r$//' "$REFN" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -1)"
if [ -z "$have" ]; then say "$REFN has no ref"; exit 1; fi

if [ "$want" != "$have" ]; then
  say "pin mismatch: upstream release.yml says $want, we recorded $have - update both together (BR-2)"
  fail=1
else
  say "OK: craft-fonts ref matches upstream release.yml ($want)"
fi
exit "$fail"
