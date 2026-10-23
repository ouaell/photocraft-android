#!/usr/bin/env bash
# scope-guard.sh - the shell's DIRECT dependencies are an allowlist: upstream library
# crates via `../upstream/crates/*` (never dev-only crates, never apps/*) plus a small
# set of shell-platform crates. No engine/app logic is vendored into android/src
# (PLAN L177, AGENTS R18). Run from the repo root.
set -u
fail=0
say() { printf 'SCOPE: %s\n' "$*" >&2; }

FORBIDDEN_UP="testkit automation"
ALLOW_EXT="eframe egui log jni android-activity android_logger winit serde serde_json bytemuck thiserror flate2 libc"

# parse `name = { ... }` dependency entries; $1=manifest; emits "<name> <table>" lines
parse_deps() {
  awk '
    /^\[dependencies\]/        {t="dependencies"; next}
    /^\[dev-dependencies\]/    {t="dev-dependencies"; next}
    /^\[build-dependencies\]/  {t="build-dependencies"; next}
    /^\[target\./              {t="target"; next}
    /^\[/                      {t=""; next}
    (t!="") && /^[A-Za-z"'"'"']/ && / *=/ {
      n=$1; sub(/ *=.*/,"",n); gsub(/["'"'"']/,"",n)
      print n, t
    }' < "$1"
}

while IFS= read -r f; do
  while read -r name tbl; do
    case "$name" in
      photocraft-*)
        crate="${name#photocraft-}"
        if printf ' %s ' "$FORBIDDEN_UP" | grep -qw "$crate"; then
          say "$f: upstream dev-only crate $name is not a shell dependency ($tbl)"; fail=1
        elif [ ! -d "upstream/crates/$crate" ]; then
          say "$f: $name points to missing upstream/crates/$crate (apps/* are not libs)"; fail=1
        fi
        ;;
      *)
        if [ -n "$name" ] && ! printf ' %s ' "$ALLOW_EXT" | grep -qw "$name"; then
          say "$f: external dep '$name' not on the shell allowlist ($tbl)"; fail=1
        fi
        ;;
    esac
  done < <(parse_deps "$f" | tr -d '\r')

  # qualified dependency sections are outside the parsed allowlist (R-A finding 1)
  while IFS= read -r q; do
    say "$f: qualified dependency section '$q' bypasses the allowlist; use plain [dependencies]"; fail=1
  done < <(tr -d '\r' < "$f" | grep -E '^\[(dev-|build-)?dependencies\.[A-Za-z0-9_-]+\]')

  # every photocraft- dep must declare exactly ../upstream twin path
  while IFS= read -r d; do
    crate="$(printf '%s' "$d" | sed 's/^photocraft-//;s/ = .*$//')"
    exp="path = \"../upstream/crates/$crate\""
    if ! printf '%s\n' "$(tr -d '\r' < "$f")" | grep -Fq "$exp"; then
      say "$f: photocraft-$crate must use $exp (found: $(printf '%s' "$d" | grep -o 'path = "[^"]*"'))"; fail=1
    fi
  done < <(tr -d '\r' < "$f" | grep -E '^photocraft-[a-z-]+ = ')
done < <(find android \( -name Cargo.toml \) -print 2>/dev/null | sort)

# no engine/app logic vendored into the shell
if [ -d android/src ]; then
  while IFS= read -r f; do
    if grep -Eq '#\[path[[:space:]]*=' "$f"; then say "$f: #[path = ...] source includes are not allowed"; fail=1; fi
    if grep -Eq 'include(_str|_bytes)?!\([^)]*upstream' "$f"; then say "$f: include! of upstream source is not allowed"; fail=1; fi
  done < <(find android/src -name '*.rs' -print 2>/dev/null | sort)
fi

[ "$fail" -eq 0 ] && say "OK: shell deps within the allowlist; no vendored logic"
exit "$fail"
