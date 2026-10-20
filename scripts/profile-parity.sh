#!/usr/bin/env bash
# profile-parity.sh - android/Cargo.toml must repeat upstream's [profile.release]
# exactly (Cargo ignores profiles of dependency workspaces; BR-3). The pinned
# upstream block is the reference; `panic` must not appear (crash guard needs
# unwinding). Run from the repo root.
set -u
fail=0
say() { printf 'PROFILE: %s\n' "$*" >&2; }

UP="${UPSTREAM_DIR:-upstream}/Cargo.toml"
AN="android/Cargo.toml"
[ -f "$UP" ] || { say "missing $UP"; exit 2; }
[ -f "$AN" ] || { say "missing $AN"; exit 1; }

extract() { # $1 = file -> [profile.release] block, comments/`?`? stripped of CR
  tr -d '\r' < "$1" | awk '
    /^\[profile\.release\]/ { p = 1; print; next }
    /^\[/                   { p = 0 }
    p && $0 !~ /^[[:space:]]*#/ { print }
  '
}

U="$(extract "$UP")"; A="$(extract "$AN")"
if [ -z "$U" ] || [ -z "$A" ]; then say "[profile.release] missing: upstream-empty=$([ -z "$U" ] && echo yes), ours-empty=$([ -z "$A" ] && echo yes)"; exit 1; fi
if ! diff <(printf '%s\n' "$U") <(printf '%s\n' "$A") > /dev/null 2>&1; then fail=1; fi
diffsum="$(diff <(printf '%s\n' "$U") <(printf '%s\n' "$A") | head -20)"
if [ -n "$diffsum" ]; then say "profile.release differs from upstream:"; printf '%s\n' "$diffsum" >&2; fail=1; fi
if printf '%s\n' "$A" | grep -Eq '^[[:space:]]*panic[[:space:]]*='; then say "profile.release sets 'panic' (crash guard needs unwinding)"; fail=1; fi
[ "$fail" -eq 0 ] && say "OK: profile.release matches upstream at the pin"
exit "$fail"
