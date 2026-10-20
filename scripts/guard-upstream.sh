#!/usr/bin/env bash
# guard-upstream.sh — fails if ANYTHING under upstream/ differs from the commit pinned by the
# superproject, or if the shell tries to override upstream sources through cargo configuration.
# Run from the repository root. Exit 0 = upstream is pristine. Any other exit = STOP and report.
set -u
UP="${UPSTREAM_DIR:-upstream}"
fail=0
say() { printf 'GUARD: %s\n' "$*" >&2; }

[ -e "$UP/.git" ] || { say "$UP is not an initialised submodule/checkout"; exit 2; }

# 1. Checked-out commit must equal the pinned gitlink (submodule status: ' ' ok, '+' moved, '-' missing, 'U' conflict).
st="$(git submodule status -- "$UP" 2>/dev/null | cut -c1)"
if [ "$st" != " " ]; then say "submodule state '$st' (expected ' '): upstream is not at the pinned commit"; fail=1; fi

# 2. No modified, staged, deleted or untracked files inside upstream (ignored files are NOT excluded on purpose).
dirty="$(git -C "$UP" status --porcelain --ignored=traditional 2>/dev/null)"
if [ -n "$dirty" ]; then say "upstream working tree is not clean:"; printf '%s\n' "$dirty" | head -20 >&2; fail=1; fi

# 3. Tracked content must match HEAD byte-for-byte (covers mode changes and assume-unchanged tricks).
if ! git -C "$UP" diff --quiet HEAD -- 2>/dev/null; then say "tracked files differ from HEAD"; fail=1; fi
if [ -n "$(git -C "$UP" ls-files -v | grep -E '^[a-z]' | head -1)" ]; then say "files marked assume-unchanged/skip-worktree inside upstream"; fail=1; fi

# 4. No cargo-level overrides of upstream code: [patch], [replace], 'paths =' in the shell's own manifests/config.
while IFS= read -r f; do
  if grep -Eq '^\s*\[(patch|replace)' "$f" 2>/dev/null; then say "$f contains [patch]/[replace]: needs written user approval (docs/decisions/)"; fail=1; fi
done < <(find . -path "./$UP" -prune -o \( -name Cargo.toml -o -name config.toml -o -name config \) -path '*cargo*' -print -o -name Cargo.toml -print 2>/dev/null)
if [ -f .cargo/config.toml ] && grep -Eq '^\s*paths\s*=' .cargo/config.toml; then say ".cargo/config.toml overrides paths"; fail=1; fi


# 5. The checked-out commit must equal the commit recorded in UPSTREAM_PIN (line: commit=<40-hex>), if the file exists.
if [ -f UPSTREAM_PIN ]; then
  want="$(sed -n 's/^commit=//p' UPSTREAM_PIN | head -1)"
  have="$(git -C "$UP" rev-parse HEAD 2>/dev/null)"
  if [ -z "$want" ]; then say "UPSTREAM_PIN has no 'commit=' line"; fail=1
  elif [ "$want" != "$have" ]; then say "upstream HEAD $have != UPSTREAM_PIN $want"; fail=1; fi
fi

[ "$fail" -eq 0 ] && say "OK: upstream pristine at $(git -C "$UP" rev-parse --short HEAD)"
exit "$fail"
