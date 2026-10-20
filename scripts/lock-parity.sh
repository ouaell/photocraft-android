#!/usr/bin/env bash
# lock-parity.sh - android/Cargo.lock must agree with upstream/Cargo.lock on every
# shared package (same crate name + same source: same version, PLAN L177, BR-4).
# A shared NAME resolved under a DIFFERENT source is a fault; brand-new names that
# only the shell adds are allowed. [patch]/[replace] are forbidden (per file).
# The committed lock is required; seed it with `cargo generate-lockfile` in android/
# (upstream's versions stay pinned) and COMMIT it before any --locked build.
set -u
UP="${UPSTREAM_DIR:-upstream}/Cargo.lock"
AN="android/Cargo.lock"
fail=0
say() { printf 'LOCK: %s\n' "$*" >&2; }

[ -f "$UP" ] || { say "missing $UP"; exit 2; }
[ -f "$AN" ] || { say "missing $AN - seed it: (cd android && cargo generate-lockfile), then COMMIT the file"; exit 1; }

for f in "$UP" "$AN"; do
  hit="$(sed 's/\r$//' "$f" | grep -E '^\[(patch|replace)\]' | head -3)"
  if [ -n "$hit" ]; then say "$f contains [patch]/[replace]: $(printf '%s' "$hit" | tr '\n' ' ')"; fail=1; fi
done

# package entries: "<name>\t<version>\t<source-or-dash>" per [[package]] block
scan() {
  tr -d '\r' < "$1" | awk '
    function flush() { if (n != "") print n "\t" v "\t" (s == "" ? "-" : s) }
    /^\[\[package\]\]/ { flush(); n = ""; v = ""; s = ""; next }
    /^\[/             { flush(); n = ""; v = ""; s = "" }
    $1 == "name"    && n == "" { d = $3; gsub(/"/, "", d); n = d }
    $1 == "version" && v == "" { d = $3; gsub(/"/, "", d); v = d }
    $1 == "source"  && s == "" { d = $3; gsub(/"/, "", d); s = d }
  '
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
scan "$UP" > "$T/up"
scan "$AN" > "$T/an"

awk -F'\t' '
  FNR == NR {
    k = $1 "@" $3
    if (!(k in seen)) seen[k] = $2
    nameup[$1] = 1
    srcup[$1 "|" ($3 == "-" ? "path" : $3)] = 1
    next
  }
  {
    k = $1 "@" $3
    if (k in seen) {
      if (seen[k] != $2) print "DIFF: " $1 " (" $3 ") upstream v" seen[k] " != ours v" $2
      delete seen[k]
    }
    if ($1 in nameup) {
      if (!( ($1 "|" ($3 == "-" ? "path" : $3)) in srcup ))
        print "SRCSET: " $1 " resolved as " $3 " in ours, not in upstream"
    } else {
      adds++
    }
    next
  }
  END {
    for (k in seen) print "MISSING from ours: " k
    if (adds > 0) print "ADDS: " adds
  }
' "$T/up" "$T/an" |

awk '
  /^DIFF:/ || /^MISSING/ || /^SRCSET:/ { print; bad = 1; next }
  { print > "/dev/stderr"; next }   # ADDS and unknown lines are informational
  END { exit bad }
' > "$T/rpt" && fail=1

if [ -s "$T/rpt" ]; then
  say "violations:"; head -30 "$T/rpt" >&2; fail=1
fi

[ "$fail" -eq 0 ] && say "OK: shared entries match; upstream packages: $(wc -l < "$T/up"), ours: $(wc -l < "$T/an")"
exit "$fail"
