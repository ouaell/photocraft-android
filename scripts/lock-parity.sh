#!/usr/bin/env bash
# lock-parity.sh - android/Cargo.lock must agree with upstream/Cargo.lock: for every
# crate NAME upstream resolves, ours must (a) only use sources upstream already knows
# for that name, and (b) only use VERSIONS upstream already pins for that (name,
# source) pair - upstream locks can legitimately hold multiple versions of one crate,
# so comparison is set membership on (name, source, version). Brand-new crate names
# only the shell uses are allowed; entries pruned because upstream's dev/extra
# dependencies are not ours are fine (informational). [patch]/[replace] forbidden.
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
  hit="$(sed 's/\r$//' "$f" | grep -E '^\[(patch|replace)' | head -3)"
  if [ -n "$hit" ]; then say "$f contains [patch]/[replace]: $(printf '%s' "$hit" | tr '\n' ' ')"; fail=1; fi
done

# package entries: "<name>\t<version>\t<source-or-dash>" per [[package]] block
scan() {
  tr -d '\r' < "$1" | awk '
    function flush() { if (n != "") print n "\t" v "\t" (s == "" ? "-" : s) }
    /^\[\[package\]\]/ { flush(); n = ""; v = ""; s = ""; next }
    /^\[/             { flush(); n = ""; v = ""; s = "" }
    $1 == "name"    && n == "" { d = $3; gsub(/"/, "", d); n = d; next }
    $1 == "version" && v == "" { d = $3; gsub(/"/, "", d); v = d; next }
    $1 == "source"  && s == "" { d = $3; gsub(/"/, "", d); s = d; next }
    END { flush() }
  '
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
scan "$UP" > "$T/up"
scan "$AN" > "$T/an"

# All fault classes (FAIL): NEWVER (shared crate resolved to a version upstream never
# had), SRCSET (shared crate under a different source set). Allowed: ADDS (brand-new
# crate names only the shell uses) and upstream-only/pruned entries (informational).

awk -F'\t' '
  FNR == NR {
    nameup[$1] = 1
    srcup[$1 "|" ($3 == "-" ? "path" : $3)] = 1
    verup[$1 "|" ($3 == "-" ? "path" : $3) "|" $2] = 1
    next
  }
  {
    if ($1 in nameup) {
      src = ($3 == "-" ? "path" : $3)
      if (!( ($1 "|" src "|" $2) in verup )) print "NEWVER: " $1 " (" src ") v" $2 " is not any version upstream pins"
      if (!( ($1 "|" src) in srcup ))        print "SRCSET: " $1 " resolved from " src " in ours, not in upstream"
    } else {
      adds++
    }
    next
  }
  END { if (adds > 0) printf "ADDS: %d (informational: new shell-only names)\n", adds > "/dev/stderr" }
' "$T/up" "$T/an" > "$T/rpt"
if [ -s "$T/rpt" ]; then
  say "violations:"; head -30 "$T/rpt" >&2; fail=1
else
  say "upstream-only (pruned) ok; shared names resolve to upstream-pinned versions"
fi

[ "$fail" -eq 0 ] && say "OK: shared entries match; upstream packages: $(wc -l < "$T/up"), ours: $(wc -l < "$T/an")"
exit "$fail"
