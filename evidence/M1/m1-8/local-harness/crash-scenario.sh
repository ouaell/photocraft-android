#!/usr/bin/env bash
# Local check of the CRASH scenario flow in scripts/e2e-rung.sh with a mock adb.
#
# Mock model (mirrors the real device):
#   - `am start` counts launches; `am force-stop` ends the current launch;
#   - the crash log is materialized at the N-th pid-scoped logcat call
#     ($STATE/crash_at_logcat) - i.e. the app crashes a moment after the start;
#   - a launch whose pid has a crash marker in its log is GONE (the crash took
#     the whole package down, as the real run showed: the package-level
#     "no pid alive" check passed there);
#   - `logcat --pid=X` serves $LOGCAT_DIR/X; the whole logcat serves all files.
set -u
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO" || exit 1
SRC="scripts/e2e-rung.sh"
BIN="$(mktemp -d)"
OUTROOT="$(mktemp -d)"
export LOGCAT_DIR="$(mktemp -d)"
export STATE="$(mktemp -d)"

cat > "$BIN/adb" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "shell am")
    if [ "$3" = "force-stop" ]; then
      rm -f "$STATE/forced"
      exit 0
    fi
    n=$(cat "$STATE/launches" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$STATE/launches"
    exit 0
    ;;
  "shell pidof")
    n=$(cat "$STATE/launches" 2>/dev/null || echo 1)
    if [ -f "$STATE/forced" ]; then exit 0; fi
    # The crash takes the whole package down: if ANY pid of the launch has a
    # crash marker in its log, no process of the package is alive any more.
    for p in $(cat "$STATE/pidof_$n" 2>/dev/null); do
      if grep -aq "PHOTOCRAFT_TEST_CRASH knob\|Rust panic: PHOTOCRAFT_TEST_CRASH" "$LOGCAT_DIR/$p" 2>/dev/null; then
        exit 0
      fi
    done
    cat "$STATE/pidof_$n" 2>/dev/null
    exit 0
    ;;
esac
if [ "$1" = "logcat" ]; then
  p=""
  for a in "$@"; do case "$a" in --pid=*) p="${a#--pid=}" ;; esac; done
  if [ -n "$p" ]; then
    c=$(cat "$STATE/logcat_calls" 2>/dev/null || echo 0)
    c=$((c + 1))
    echo "$c" > "$STATE/logcat_calls"
    if [ "$c" = "$(cat "$STATE/crash_at_logcat" 2>/dev/null || echo 999)" ] && [ -f "$STATE/crash_log" ]; then
      cp "$STATE/crash_log" "$LOGCAT_DIR/$(cat "$STATE/crash_pid")"
    fi
    [ -f "$LOGCAT_DIR/$p" ] && cat "$LOGCAT_DIR/$p"
  else
    for f in "$LOGCAT_DIR"/*; do [ -f "$f" ] && cat "$f"; done
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/adb"
export PATH="$BIN:$PATH"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1 ($2)"; else echo "FAIL - $1: got [$2] want [$3]"; fail=1; fi }
has() { grep -q "$1" "$2" 2>/dev/null && echo yes || echo no; }

run_case() {
  local dir="$1"; rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir" && bash "$REPO/$SRC" crash io.github.ouaell.picsh.crash /tmp/app.apk crash > run.log 2>&1 )
}
reset_state() {
  rm -f "$STATE"/* "$LOGCAT_DIR"/*
  echo 0 > "$STATE/launches"
  echo 0 > "$STATE/logcat_calls"
}

# ---- case A: two pids, the crash event lands in the second one --------------
reset_state
printf '10-21 21:12:50.100  3767  3767 I picsh   : picsh: Picsh: device request: Limits::default {}\n' > "$LOGCAT_DIR/3767"
cat > "$STATE/crash_log" <<'EOF'
10-21 21:12:50.200  3900  3900 E picsh   : picsh: Picsh: PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now
EOF
echo 3900 > "$STATE/crash_pid"
echo 2 > "$STATE/crash_at_logcat"
printf '3767 3900\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
printf '10-21 21:13:10.100  5100  5100 I picsh   : picsh: Picsh: PHOTOCRAFT_TEST_CRASH already fired once (marker /x); staying up\n' > "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.200  5100  5100 I picsh   : picsh: Picsh: device request: Limits::default { max_texture_dimension_2d: 8192 }\n' >> "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.300  5100  5100 I picsh   : picsh: Picsh: SystemInfo: Image compositor: CPU\n' >> "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.400  5100  5100 I picsh   : picsh: Picsh: gpu ladder: selected vulkan\n' >> "$LOGCAT_DIR/5100"
run_case "$OUTROOT/a"
check "case A: the crash was found in the second pid" "$(cat "$OUTROOT/a/rungs/crash/scenario-boot1.txt" 2>/dev/null)" "scenario boot 1: forced crash observed in pid 3900, that pid is gone"
check "case A: not red for a missing crash event" "$(has 'no PHOTOCRAFT_TEST_CRASH crash event' "$OUTROOT/a/rungs/crash/scenario.red")" "no"
check "case A: both pids are in the evidence file" "$(grep -c '===== pid ' "$OUTROOT/a/rungs/crash/logcat-boot1.txt" 2>/dev/null)" "2"
check "case A: the relaunch is a new pid that reached the ready marker" "$(has 'oracle":"green' "$OUTROOT/a/rungs/crash/result.json")" "yes"

# ---- case B: no crash event at all -> the gate must be RED -------------------
reset_state
printf '10-21 21:12:50.100  3767  3767 I picsh   : picsh: Picsh: device request: Limits::default {}\n' > "$LOGCAT_DIR/3767"
printf '3767\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
run_case "$OUTROOT/b"
check "case B: the gate is red without a crash event" "$(has 'no PHOTOCRAFT_TEST_CRASH crash event' "$OUTROOT/b/rungs/crash/scenario.red")" "yes"

# ---- case C: the "already fired once" line alone must NOT count as a crash ---
reset_state
printf '10-21 21:12:50.100  3767  3767 I picsh   : picsh: Picsh: PHOTOCRAFT_TEST_CRASH already fired once (marker /x); staying up\n' > "$LOGCAT_DIR/3767"
printf '3767\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
run_case "$OUTROOT/c"
check "case C: 'already fired once' alone is red" "$(has 'no PHOTOCRAFT_TEST_CRASH crash event' "$OUTROOT/c/rungs/crash/scenario.red")" "yes"

# ---- case D: the crashed process died BEFORE pidof ever listed it, so it is
#      not among the pids the script knows -> only the whole-logcat fallback
#      can find it. The package is gone (the crash took it down).
reset_state
printf '10-21 21:12:50.100  4700  4700 E picsh   : picsh: Picsh: Rust panic: PHOTOCRAFT_TEST_CRASH\n' > "$LOGCAT_DIR/4700"
printf '\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
printf '10-21 21:13:10.200  5100  5100 I picsh   : picsh: Picsh: device request: Limits::default { max_texture_dimension_2d: 8192 }\n' > "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.300  5100  5100 I picsh   : picsh: Picsh: SystemInfo: Image compositor: CPU\n' >> "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.400  5100  5100 I picsh   : picsh: Picsh: gpu ladder: selected vulkan\n' >> "$LOGCAT_DIR/5100"
run_case "$OUTROOT/d"
check "case D: the full-logcat fallback finds the crash" "$(cat "$OUTROOT/d/rungs/crash/scenario-boot1.txt" 2>/dev/null)" "scenario boot 1: forced crash observed in pid 4700, that pid is gone"

# ---- case E: the platform tore the activity down before the knob could fire;
#      the script must force-stop, relaunch and find the crash in the NEW boot.
reset_state
printf '10-21 21:12:50.100  3767  3767 V threaded_app: APP_CMD_DESTROY\n' > "$LOGCAT_DIR/3767"
cat > "$STATE/crash_log" <<'EOF'
10-21 21:12:50.100  4800  4800 E picsh   : picsh: Picsh: PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now
EOF
echo 4800 > "$STATE/crash_pid"
echo 3 > "$STATE/crash_at_logcat"
printf '3767\n' > "$STATE/pidof_1"
printf '4800\n' > "$STATE/pidof_2"
printf '5100\n' > "$STATE/pidof_3"
printf '10-21 21:13:10.200  5100  5100 I picsh   : picsh: Picsh: device request: Limits::default { max_texture_dimension_2d: 8192 }\n' > "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.300  5100  5100 I picsh   : picsh: Picsh: SystemInfo: Image compositor: CPU\n' >> "$LOGCAT_DIR/5100"
printf '10-21 21:13:10.400  5100  5100 I picsh   : picsh: Picsh: gpu ladder: selected vulkan\n' >> "$LOGCAT_DIR/5100"
run_case "$OUTROOT/e"
check "case E: the torn-down boot is relaunched and the crash is found" "$(cat "$OUTROOT/e/rungs/crash/scenario-boot1.txt" 2>/dev/null)" "scenario boot 1: forced crash observed in pid 4800, that pid is gone"
check "case E: the relaunch is recorded" "$(has 'the platform tore the activity down' "$OUTROOT/e/rungs/crash/pid.txt")" "yes"

echo
[ "$fail" = "0" ] && echo "ALL CRASH-SCENARIO CHECKS PASS" || echo "SOME CHECKS FAILED"
exit $fail
