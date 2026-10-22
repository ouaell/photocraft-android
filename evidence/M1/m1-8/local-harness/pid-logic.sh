#!/usr/bin/env bash
# Local sanity check of the pid handling in scripts/e2e-rung.sh (mock adb).
# Extracts the functions from the real script and runs them against a fake adb.
set -u
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO" || exit 1
SRC="scripts/e2e-rung.sh"
BIN="$(mktemp -d)"

cat > "$BIN/adb" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "shell pidof")
    printf '%s' "$PIDOF_OUT"
    exit 0
    ;;
esac
if [ "$1" = "logcat" ]; then
  p=""
  for a in "$@"; do
    case "$a" in
      --pid=*) p="${a#--pid=}" ;;
    esac
  done
  if [ -n "$p" ]; then
    [ -f "$LOGCAT_DIR/$p" ] && cat "$LOGCAT_DIR/$p"
  else
    for f in "$LOGCAT_DIR"/*; do
      [ -f "$f" ] && cat "$f"
    done
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/adb"
export PATH="$BIN:$PATH"
export LOGCAT_DIR="$(mktemp -d)"

# pull the function definitions out of the real script
OUT="$(mktemp -d)"
for fn in launch_and_log pidof_list adb_ok adb_error_text pid_alive pid_gone pkg_gone capture_logs; do
  eval "$(awk "/^$fn\\(\\)/,/^}/" "$SRC")"
done
ADB_ERR_FILE="$OUT/adb-error.txt"

OUT="$(mktemp -d)"
PKG=io.github.ouaell.picsh.crash
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1 ($2)"; else echo "FAIL - $1: got [$2] want [$3]"; fail=1; fi }

# 1. two pids -> PID is the first, PIDS keeps both
export PIDOF_OUT="3767 3900
"
launch_and_log >/dev/null 2>&1
check "PID from two pids" "$PID" "3767"
check "PIDS keeps both" "$PIDS" "3767 3900 "

# 2. pid_alive for each of them
check "pid_alive 3767" "$(pid_alive 3767 && echo yes)" "yes"
check "pid_alive 3900" "$(pid_alive 3900 && echo yes)" "yes"
check "pid_alive 376 (prefix must not match)" "$(pid_alive 376 && echo yes)" ""
check "pid_alive 39001 (must not match)" "$(pid_alive 39001 && echo yes)" ""

# 3. one pid gone
export PIDOF_OUT="3900
"
check "pid_alive 3767 after death" "$(pid_alive 3767 && echo yes)" ""
check "pid_alive 3900 still alive" "$(pid_alive 3900 && echo yes)" "yes"

# 4. pkg_gone / pid_gone (the "still alive" cases would spin 90s; run them in a
#    background job and require that they had NOT finished after 4 s)
export PIDOF_OUT="
"
check "pkg_gone when no pid" "$(pkg_gone && echo yes)" "yes"
export PIDOF_OUT="3900
"
( pkg_gone; echo $? > "$OUT/rc.pkg" ) &
bg=$!
sleep 4
check "pkg_gone does not return early while a pid lives" "$([ -f "$OUT/rc.pkg" ] && cat "$OUT/rc.pkg" || echo still-running)" "still-running"
kill $bg 2>/dev/null; wait $bg 2>/dev/null
( pid_gone 3900; echo $? > "$OUT/rc.live" ) &
bg=$!
sleep 4
check "pid_gone does not return early while the pid lives" "$([ -f "$OUT/rc.live" ] && cat "$OUT/rc.live" || echo still-running)" "still-running"
kill $bg 2>/dev/null; wait $bg 2>/dev/null
( pid_gone 3767; echo $? > "$OUT/rc.dead" ) &
bg=$!
sleep 1
check "pid_gone returns 0 for a dead pid" "$(cat "$OUT/rc.dead" 2>/dev/null)" "0"
wait $bg 2>/dev/null

# 5. an adb transport error must NOT read as "the app is gone" (fail closed)
cat > "$BIN/adb" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "shell pidof")
    echo "error: device offline" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$BIN/adb"
pkg_gone
rc=$?
check "an adb error fails closed (not 'the app is gone')" "$rc" "2"
check "the adb error text is recorded" "$(adb_error_text | grep -c 'device offline')" "1"

# 6. capture_logs concatenates per pid with a header
cat > "$BIN/adb" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "shell pidof")
    printf '%s' "$PIDOF_OUT"
    exit 0
    ;;
esac
if [ "$1" = "logcat" ]; then
  p=""
  for a in "$@"; do
    case "$a" in
      --pid=*) p="${a#--pid=}" ;;
    esac
  done
  if [ -n "$p" ]; then
    [ -f "$LOGCAT_DIR/$p" ] && cat "$LOGCAT_DIR/$p"
  else
    for f in "$LOGCAT_DIR"/*; do
      [ -f "$f" ] && cat "$f"
    done
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/adb"
printf 'line-a\n' > "$LOGCAT_DIR/3767"
printf 'line-b\n' > "$LOGCAT_DIR/3900"
capture_logs "$OUT/logcat-boot1.txt" 3767 3900
check "capture_logs content" "$(tr '\n' '|' < "$OUT/logcat-boot1.txt")" "===== pid 3767 =====|line-a|===== pid 3900 =====|line-b|"

# 7. the crash matcher must not fire on the "already fired once" line
cat > "$LOGCAT_DIR/9999" <<'EOF'
10-21 21:12:50.100  9999  9999 1234 I picsh   : picsh: Picsh: PHOTOCRAFT_TEST_CRASH already fired once (marker /x); staying up
EOF
hit="$(adb logcat -d --pid=9999 -v threadtime 2>/dev/null | grep -aq -e "PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now" -e "Rust panic: PHOTOCRAFT_TEST_CRASH" && echo yes)"
check "already-fired-once is NOT the crash" "$hit" ""

cat > "$LOGCAT_DIR/9998" <<'EOF'
10-21 21:12:50.100  9998  9998 1234 E picsh   : picsh: Picsh: PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now
EOF
hit="$(adb logcat -d --pid=9998 -v threadtime 2>/dev/null | grep -aq -e "PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now" -e "Rust panic: PHOTOCRAFT_TEST_CRASH" && echo yes)"
check "knob line IS the crash" "$hit" "yes"

cat > "$LOGCAT_DIR/9997" <<'EOF'
10-21 21:12:50.100  9997  9997 1234 E picsh   : picsh: Picsh: Rust panic: PHOTOCRAFT_TEST_CRASH
EOF
hit="$(adb logcat -d --pid=9997 -v threadtime 2>/dev/null | grep -aq -e "PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now" -e "Rust panic: PHOTOCRAFT_TEST_CRASH" && echo yes)"
check "panic line IS the crash" "$hit" "yes"

# 8. pid extraction from a threadtime line (field 3)
pid="$(adb logcat -d -v threadtime 2>/dev/null | grep -a -e "PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now" -e "Rust panic: PHOTOCRAFT_TEST_CRASH" | awk '{print $3}' | grep -E '^[0-9]+$' | head -1)"
check "pid from threadtime field 3" "$pid" "9997"

echo
[ "$fail" = "0" ] && echo "ALL PID-LOGIC CHECKS PASS" || echo "SOME CHECKS FAILED"
exit $fail
