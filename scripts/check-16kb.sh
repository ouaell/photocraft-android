#!/usr/bin/env bash
# check-16kb.sh - C13/PK / PIN: every Android ELF we produce must be aligned to the
# 16 KB page size (2**14). Today that means: per-target link flags "max-page-size=16384"
# in android/.cargo/config.toml for BOTH targets we build. When the Gradle module and
# the packaging script land (later M1 steps), this check extends to them: NDK >= r28,
# `zipalign -c -P 16 4`, and a 16 KB system image for the emulator matrix.
set -u
fail=0
say() { printf '16KB: %s\n' "$*" >&2; }

CFG="android/.cargo/config.toml"
[ -f "$CFG" ] || { say "missing $CFG"; exit 1; }

for target in target.aarch64-linux-android target.x86_64-linux-android; do
  if ! sed 's/\r$//' "$CFG" | awk -v t="[$target]" '
    $0 == t          { insec = 1; next }
    /^\[/            { insec = 0; in_r = 0 }
    insec && /^#/    { next }
    insec && /^rustflags(\.[a-z]+)?[[:space:]]*=/ { in_r = 1 }
    insec && /^]/    { in_r = 0 }
    insec && in_r && /max-page-size=16384/ { found = 1 }
    END { exit !found }
  '; then
    say "$CFG: [$target] has no -C link-arg=-Wl,-z,max-page-size=16384 in a rustflags assignment"; fail=1
  fi
done

# NDK floor: any NDK pin below r28 in workflows or gradle fails (C13 needs r28's 16 KB defaults).
for f in .github/workflows/*.yml android/app/build.gradle.kts android/build.gradle.kts android/gradle.properties; do
  [ -f "$f" ] || continue
  bad="$(sed 's/\r$//' "$f" | grep -E 'ndk[-/ ]?2[0-7][\." ]|ndkVersion[[:space:]]*=?[[:space:]]*"2[0-7]' | head -3)"
  if [ -n "$bad" ]; then say "$f references NDK < r28: $(printf '%s' "$bad" | tr '\n' ' ')"; fail=1; fi
done

# Rollout notes (released checks stay listed here so the extension is visible at review)
say "NOTE: zipalign -P 16 and 16 KB system-image checks extend this gate when gradle/packaging land"
[ "$fail" -eq 0 ] && say "OK: 16 KB alignment configured for both targets"
exit "$fail"
