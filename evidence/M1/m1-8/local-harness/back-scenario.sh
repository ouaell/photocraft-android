#!/usr/bin/env bash
# Local check of the BACK scenario flow in scripts/e2e-rung.sh with a mock adb.
#
# Mock model (mirrors the real device):
#   - `am start` counts launches, clears the "the app is gone" state and
#     materializes the boot log of the launch ($STATE/boot_log_<n>) in the log
#     of the launch's first pid;
#   - `am force-stop` ends the current launch (the package is gone);
#   - `input keyevent 4` (the Back press) appends the app's leave line to the
#     log of the pid that is supposed to leave ($STATE/leave_pid_<n>) and marks
#     the package as gone (the app exited);
#   - `pidof` answers with the pid list of the current launch, empty once the
#     app has left;
#   - `logcat --pid=X` serves $LOGCAT_DIR/X.
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
      rm -f "$STATE/gone"
      exit 0
    fi
    n=$(cat "$STATE/launches" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$STATE/launches"
    rm -f "$STATE/gone"
    if [ -f "$STATE/boot_log_$n" ]; then
      first=$(head -1 "$STATE/pidof_$n" 2>/dev/null | awk '{print $1}')
      [ -n "$first" ] && cp "$STATE/boot_log_$n" "$LOGCAT_DIR/$first"
    fi
    exit 0
    ;;
  "shell input")
    n=$(cat "$STATE/launches" 2>/dev/null || echo 1)
    if [ -f "$STATE/leave_pid_$n" ] && [ -f "$STATE/leave_log" ]; then
      printf '%s\n' "$(cat "$STATE/leave_log")" >> "$LOGCAT_DIR/$(cat "$STATE/leave_pid_$n")"
      touch "$STATE/gone"
    fi
    exit 0
    ;;
  "shell pidof")
    if [ -f "$STATE/gone" ]; then exit 0; fi   # the app left: the package is gone
    n=$(cat "$STATE/launches" 2>/dev/null || echo 1)
    cat "$STATE/pidof_$n" 2>/dev/null
    exit 0
    ;;
esac
if [ "$1" = "logcat" ]; then
  p=""
  for a in "$@"; do case "$a" in --pid=*) p="${a#--pid=}" ;; esac; done
  if [ -n "$p" ]; then
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
  ( cd "$dir" && bash "$REPO/$SRC" back io.github.ouaell.picsh /tmp/app.apk back > run.log 2>&1 )
}
reset_state() {
  rm -f "$STATE"/* "$LOGCAT_DIR"/*
  echo 0 > "$STATE/launches"
  printf '10-21 21:13:20.300  5100  5100 I picsh   : picsh: Picsh: SystemInfo: Image compositor: CPU\n' > "$STATE/sysinfo"
  printf '10-21 21:13:20.400  5100  5100 I picsh   : picsh: Picsh: gpu ladder: selected vulkan\n' > "$STATE/ladder"
}

BOOT='10-21 21:12:50.100  PID  PID I picsh   : picsh: Picsh: device request: Limits::default { max_texture_dimension_2d: 8192 }'
boot_log() { echo "$BOOT" | sed "s/PID/$1/g"; }

# ---- case A: two pids; the leave line is in the SECOND one -------------------
reset_state
boot_log 3767 > "$STATE/boot_log_1"
printf '10-21 21:13:01.671  3900  3900 I picsh   : picsh: Picsh: leaving: the app quits; the process ends\n' > "$STATE/leave_log"
echo 3900 > "$STATE/leave_pid_1"
printf '3767 3900\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
boot_log 5100 > "$STATE/boot_log_2"
printf '10-21 21:13:20.300  5100  5100 I picsh   : picsh: Picsh: SystemInfo: Image compositor: CPU\n' > "$STATE/sysinfo"
printf '10-21 21:13:20.400  5100  5100 I picsh   : picsh: Picsh: gpu ladder: selected vulkan\n' > "$STATE/ladder"
cat "$STATE/sysinfo" "$STATE/ladder" >> "$STATE/boot_log_2"
run_case "$OUTROOT/a"
check "case A: the leave line was found in the second pid" "$(cat "$OUTROOT/a/rungs/back/scenario-boot1.txt" 2>/dev/null)" "scenario boot 1: Back pressed, pid 3900 exited cleanly"
check "case A: the relaunch is green" "$(has 'oracle":"green' "$OUTROOT/a/rungs/back/result.json")" "yes"

# ---- case B: no leave line -> the gate must be RED ---------------------------
reset_state
boot_log 3767 > "$STATE/boot_log_1"
printf '3767\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
boot_log 5100 > "$STATE/boot_log_2"
run_case "$OUTROOT/b"
check "case B: the gate is red without a leave line" "$(has 'no leave line in the log of the launched pid' "$OUTROOT/b/rungs/back/scenario.red")" "yes"

# ---- case C: the activity was torn down before Back could reach the app; the
#      script must force-stop, relaunch, press Back again and find the leave.
reset_state
# launch 1: torn down, the app never leaves
printf '10-21 21:12:50.100  3767  3767 V threaded_app: APP_CMD_DESTROY\n' > "$STATE/boot_log_1"
# launch 2 (after the force-stop relaunch): the app leaves on Back
boot_log 4800 > "$STATE/boot_log_2"
printf '10-21 21:13:20.671  4800  4800 I picsh   : picsh: Picsh: leaving: the app quits; the process ends\n' > "$STATE/leave_log"
echo 4800 > "$STATE/leave_pid_2"
printf '3767\n' > "$STATE/pidof_1"
printf '4800\n' > "$STATE/pidof_2"
printf '5100\n' > "$STATE/pidof_3"
boot_log 5100 > "$STATE/boot_log_3"
cat "$STATE/sysinfo" "$STATE/ladder" >> "$STATE/boot_log_3"
run_case "$OUTROOT/c"
check "case C: the torn-down boot is relaunched and the leave is found" "$(cat "$OUTROOT/c/rungs/back/scenario-boot1.txt" 2>/dev/null)" "scenario boot 1: Back pressed, pid 4800 exited cleanly"
check "case C: the relaunch is recorded" "$(has 'torn-down=yes' "$OUTROOT/c/rungs/back/pid.txt")" "yes"
check "case C: the relaunch reached the ready marker" "$(has 'ready=yes' "$OUTROOT/c/rungs/back/pid.txt")" "yes"

# ---- case D: the app reached the ready marker, but the platform tore the
#      activity down afterwards, so the Back key cannot reach the app. The
#      script must force-stop, relaunch, press Back again and find the leave.
reset_state
# launch 1: ready, then torn down
printf '%s\n10-21 21:12:51.100  3767  3767 V threaded_app: APP_CMD_DESTROY\n' "$(boot_log 3767)" > "$STATE/boot_log_1"
# launch 2 (after the force-stop relaunch): the app leaves on Back
boot_log 4800 > "$STATE/boot_log_2"
printf '10-21 21:13:20.671  4800  4800 I picsh   : picsh: Picsh: leaving: the app quits; the process ends\n' > "$STATE/leave_log"
echo 4800 > "$STATE/leave_pid_2"
printf '3767\n' > "$STATE/pidof_1"
printf '4800\n' > "$STATE/pidof_2"
printf '5100\n' > "$STATE/pidof_3"
boot_log 5100 > "$STATE/boot_log_3"
cat "$STATE/sysinfo" "$STATE/ladder" >> "$STATE/boot_log_3"
run_case "$OUTROOT/d"
check "case D: the torn-down activity is relaunched and the leave is found" "$(cat "$OUTROOT/d/rungs/back/scenario-boot1.txt" 2>/dev/null)" "scenario boot 1: Back pressed, pid 4800 exited cleanly"
check "case D: the relaunch is recorded" "$(has 'tore the activity down before Back' "$OUTROOT/d/rungs/back/pid.txt")" "yes"

# ---- case E: the first boot died with a FATAL error; it must NOT be retried
#      away (the fatal boot would be invisible to the oracle otherwise).
reset_state
printf '%s\n10-21 21:12:51.100  3767  3767 F libc    : Fatal signal 11 (SIGSEGV), code 1, pid 3767\n' "$(boot_log 3767)" > "$STATE/boot_log_1"
printf '3767\n' > "$STATE/pidof_1"
printf '5100\n' > "$STATE/pidof_2"
boot_log 5100 > "$STATE/boot_log_2"
run_case "$OUTROOT/e"
check "case E: a fatal first boot is red, not retried" "$(has 'died with a fatal error' "$OUTROOT/e/rungs/back/scenario.red")" "yes"
check "case E: the fatal boot is judged in the evidence file" "$(has 'Fatal signal 11' "$OUTROOT/e/rungs/back/logcat-boot1.txt")" "yes"

echo
[ "$fail" = "0" ] && echo "ALL BACK-SCENARIO CHECKS PASS" || echo "SOME CHECKS FAILED"
exit $fail
