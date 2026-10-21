#!/usr/bin/env bash
# One rendering-rung of the emulator e2e matrix (docs/decisions/009-ci-probes.md).
# Args: <rung-name> <package-name> <apk-path> [scenario]
#   scenario (optional, default none):
#     back  - boot, press Back, the app must log its leave line and the pid must
#             exit, then a relaunch must show the UI again in a new process
#             (winit's one-event-loop re-entry gate, decision 011 amendment 3).
#     crash - the rungCrash apk (PHOTOCRAFT_TEST_CRASH=1, one-shot): the crash
#             must show up in the log of the launched process and that process
#             must be gone; the relaunch must come up normally (the marker file
#             skips the knob's second firing).
# `pidof` can answer with several pids for the package, so the script keeps the
# whole list (PIDS) and judges per pid - see the comment on launch_and_log.
# Booted by android-emulator-runner's `script` step; kills the emulator at exit so
# the next rung step boots its own AVD.
set -o pipefail

[ $# -eq 3 ] || [ $# -eq 4 ] || { echo "usage: e2e-rung.sh <rung> <package> <apk> [scenario]"; exit 64; }
RUNG="$1"; PKG="$2"; APK="$3"; SCENARIO="${4:-none}"
case "$SCENARIO" in none|back|crash) ;; *) echo "bad scenario '$SCENARIO' (none|back|crash)"; exit 64 ;; esac
OUT="rungs/$RUNG"
mkdir -p "$OUT"
echo "rung=$RUNG package=$PKG apk=$APK scenario=$SCENARIO" | tee "$OUT/config.txt"

fatal='FATAL EXCEPTION|ANR in .|Fatal signal 11|signal 11|panicked at|JNI DETECTED ERROR|UnsatisfiedLinkError|Validation Error|Device lost|StrictMode|invalid local reference'

# Process bookkeeping. `pidof` can answer with SEVERAL pids for the package
# (run 39672720132 rungs/crash: "3767 3900"). The old code stripped the
# whitespace and used the concatenation ("37673900") as one pid, so
# `adb logcat --pid=37673900` matched nothing and the crash-payload gate failed
# on a crash that had actually happened. The list is now kept intact: PIDS is
# the whole list, PID is its first entry, and every log capture is per pid.
launch_and_log() {
    adb shell am start -n "$PKG/com.google.androidgamesdk.GameActivity" 2>&1 | tee -a "$OUT/am-start.log"
    local pids=""
    for i in $(seq 1 30); do
        pids="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | tr -s ' ')"
        echo "$pids" | grep -q "[0-9]" && break
        pids=""
        sleep 2
    done
    echo "pids=$pids" >> "$OUT/pids.txt"
    PIDS="$pids"
    PID="$(echo "$pids" | awk '{print $1}')"
}

pid_alive() {  # true (0) while the given pid is still in the package's process list
    [ -n "$1" ] || return 1
    adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | tr -s ' ' | grep -q -w "$1"
}

pid_gone() {   # true (0) once the given pid (default: the launched one) is gone
    local target="${1:-$PID}"
    for i in $(seq 1 45); do
        pid_alive "$target" || return 0
        sleep 2
    done
    return 1
}

pids_gone() {   # true (0) once none of the given pids is alive (one shared 90s budget)
    local p
    for i in $(seq 1 45); do
        local alive=0
        for p in "$@"; do
            pid_alive "$p" && alive=1
        done
        [ "$alive" = "0" ] && return 0
        sleep 2
    done
    return 1
}

pkg_gone() {   # true (0) once no process of the package is alive
    for i in $(seq 1 45); do
        adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | tr -s ' ' | grep -q "[0-9]" || return 0
        sleep 2
    done
    return 1
}

capture_logs() {   # capture_logs <out-file> <pid> [pid...] - one pid-scoped logcat per pid
    local out="$1"; shift
    : > "$out"
    local p
    for p in "$@"; do
        echo "===== pid $p =====" >> "$out"
        adb logcat -d --pid="$p" -v threadtime >> "$out" 2>/dev/null || true
    done
}

finish() {
    adb shell am force-stop "$PKG" 2>/dev/null || true
    adb uninstall "$PKG" >/dev/null 2>&1 || true
    adb emu kill >/dev/null 2>&1 || true
    sleep 5
}

red_exit() {   # red_exit <gate> <file> <detail> - write the gate's .red, json, finish, exit 1
    echo "$1 RED: $3 (full content in rungs/$RUNG/$2 plus logcat-boot1.txt)" | tee "$OUT/$2"
    printf '{"rung":"%s","package":"%s","scenario":"%s","pid":"%s","result":"red","gate":"%s"}\n' "$RUNG" "$PKG" "$SCENARIO" "$PID" "$1" > "$OUT/result.json"
    finish
    exit 1
}

# Failure-path capture, called BEFORE every scenario red_exit: gate 39615314265
# (Back, rung failed with "pid did not exit within 90s") produced no logcat at the
# failure point because the pid-scoped capture runs only after a successful exit,
# so the red was undiagnosable. Run 39608063154 showed the pid-scoped oracle gets
# nothing when the pid is missing. Not a gate change: the assertions stay as-is.
red_evidence() {
    adb logcat -d -t 200000 > "$OUT/logcat-onred-full.txt" 2>/dev/null || true
    if [ -n "$PID" ]; then
        adb logcat -d --pid="$PID" -v time > "$OUT/logcat-onred-pid.txt" 2>/dev/null || true
    fi
    adb shell dumpsys activity activities > "$OUT/activities-onred.txt" 2>/dev/null || true
    adb exec-out screencap -p > "$OUT/screenshot-red.png" 2>/dev/null || true
}

# Ready-marker + one relaunch (decision 011 amendment 3). A freshly booted emulator
# occasionally tears the activity down ~30 ms after resume while the launcher role is
# still being re-registered (observed once on the 3rd consecutive boot, run
# 39548313457 rungs/cpu: pause/stop/destroy with no FATAL, no Rust panic, no lmkd
# record; the same rung binary was green on two prior boots and boots 1-2 of that run).
# We therefore wait (bounded) for the app's own "device request:" log marker; if the
# pid died before any marker appeared, am start once more and re-capture the pid. No
# assertion changes: the oracle and parity below judge whatever is finally captured.
# The marker is looked for in EVERY pid of the package (pidof can answer with
# several), and PID is set to the pid that actually produced it, so the oracle
# judges the process that really ran the app.
wait_ready() {
    READY=""
    READY_PID=""
    for attempt in 1 2; do
        for i in $(seq 1 45); do
            for p in $PIDS; do
                if adb logcat -d --pid="$p" -v time 2>/dev/null | grep -aq "Picsh: device request: "; then
                    READY="yes"
                    READY_PID="$p"
                    break
                fi
            done
            [ -n "$READY" ] && break
            if [ -n "$PIDS" ]; then
                if ! adb shell pidof "$PKG" 2>/dev/null | grep -q "[0-9]"; then
                    break   # died without a marker -> relaunch below
                fi
            fi
            sleep 1
        done
        [ -n "$READY" ] && break
        if [ "$attempt" = "1" ]; then
            echo "relaunch: activity died before the ready marker (one retry)" | tee -a "$OUT/pid.txt"
            launch_and_log
            echo "pid=$PID (after relaunch)" | tee -a "$OUT/pid.txt"
        fi
    done
    [ -n "$READY_PID" ] && PID="$READY_PID"
    echo "ready=$READY" | tee -a "$OUT/pid.txt"
}

# One install per rung before boot 1: am start can only resolve the GameActivity
# component once the package is on the device. The install line was lost when this
# script gained the scenario argument (run 39608063154 rungs/default: no install.log
# in the artifact, "Error type 3: Activity class ... does not exist", pid= empty).
adb uninstall "$PKG" >/dev/null 2>&1 || true
if ! adb install -r "$APK" > "$OUT/install.log" 2>&1; then
    red_exit install "install.red" "APK install failed: $(tail -1 "$OUT/install.log")"
fi

# ---- boot 1 ----------------------------------------------------------------
PID=""
launch_and_log
echo "pid=$PID" | tee "$OUT/pid.txt"

if [ "$SCENARIO" = "crash" ]; then
    # No ready/relaunch logic here: a relaunch would consume the one-shot marker
    # and mask the scenario. The knob fires at the end of the creator closure.
    #
    # Order matters: the death check comes FIRST (exactly as before), because
    # the window in which no process of the package is alive is the moment the
    # crash tore the app down; asking for the crash evidence afterwards still
    # works (logcat keeps the buffer of a dead process), while the other order
    # could miss that window.
    #
    # The gate: the forced crash must appear in the log of a process of this
    # package, and that process must be gone afterwards. The crash is matched on
    # the CRASH event lines, never on the bare token - the relaunch logs
    # "PHOTOCRAFT_TEST_CRASH already fired once" (same token) and must not be
    # mistaken for the crash.
    if ! pkg_gone; then
        red_evidence
        red_exit scenario "scenario.red" "a process of $PKG is still alive after the forced crash (live pids: $(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | tr -s ' '))"
    fi
    CRASHED=""
    for i in $(seq 1 45); do
        for p in $PIDS; do
            if adb logcat -d --pid="$p" -v threadtime 2>/dev/null \
                | grep -aq -e "PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now" \
                         -e "Rust panic: PHOTOCRAFT_TEST_CRASH"; then
                CRASHED="$p"
                break
            fi
        done
        [ -n "$CRASHED" ] && break
        sleep 2
    done
    if [ -z "$CRASHED" ]; then
        # The crashed process may have died before pidof listed it (run
        # 39672720132 rungs/crash: pidof answered with two pids and the old code
        # concatenated them into one bogus pid, so the pid-scoped logcat was
        # empty and this gate failed on a crash that had happened). Fall back to
        # the whole logcat, take the pid out of the matching line (threadtime
        # puts it in field 3) and judge THAT process.
        CRASHED="$(adb logcat -d -v threadtime 2>/dev/null \
            | grep -a -e "PHOTOCRAFT_TEST_CRASH knob: forcing the one-shot crash now" \
                    -e "Rust panic: PHOTOCRAFT_TEST_CRASH" \
            | awk '{print $3}' | grep -E '^[0-9]+$' | head -1)"
    fi
    if [ -z "$CRASHED" ]; then
        red_evidence
        red_exit scenario "scenario.red" "no PHOTOCRAFT_TEST_CRASH crash event in the log of the launched pid(s) ($PIDS)"
    fi
    if ! pid_gone "$CRASHED"; then
        red_evidence
        red_exit scenario "scenario.red" "the crashed pid $CRASHED is still alive 90s after the forced crash"
    fi
    capture_logs "$OUT/logcat-boot1.txt" $PIDS
    echo "scenario boot 1: forced crash observed in pid $CRASHED, that pid is gone" | tee "$OUT/scenario-boot1.txt"
    PID1="$CRASHED"
else
    wait_ready
    PID1="$PID"
    if [ "$SCENARIO" = "back" ]; then
        # Adapter/first-frame grace window, one UI-visible shot, then Back.
        sleep 10
        adb exec-out screencap -p > "$OUT/screenshot-boot1.png"
        adb shell input keyevent 4 2>&1 | tee "$OUT/back.log"
        # The Back key asks the app to close (the shell's wrapper), upstream's
        # leave guard runs, and the app leaves through the platform quit
        # (`Services::quit` -> the shell's leave hook). On Android the eframe
        # run itself cannot return (winit's Android event loop never exits on
        # its own), so the leave evidence is the shell's own line, not
        # "efrace loop returned cleanly".
        LEAVE_PID=""
        for i in $(seq 1 45); do
            for p in $PIDS; do
                if adb logcat -d --pid="$p" -v threadtime 2>/dev/null | grep -aq "Picsh: leaving: the app quits"; then
                    LEAVE_PID="$p"
                    break
                fi
            done
            [ -n "$LEAVE_PID" ] && break
            sleep 2
        done
        if [ -z "$LEAVE_PID" ]; then
            red_evidence
            red_exit scenario "scenario.red" "no leave line in the log of the launched pid(s) ($PIDS)"
        fi
        if ! pkg_gone; then
            red_evidence
            red_exit scenario "scenario.red" "pid $LEAVE_PID did not exit within 90s of Back (evidence: logcat-onred-*.txt, activities-onred.txt, screenshot-red.png)"
        fi
        capture_logs "$OUT/logcat-boot1.txt" $PIDS
        grep -aq "Picsh: Rust panic" "$OUT/logcat-boot1.txt" && {
            red_evidence
            red_exit scenario "scenario.red" "the app panicked while leaving"
        }
        echo "scenario boot 1: Back pressed, pid $LEAVE_PID exited cleanly" | tee "$OUT/scenario-boot1.txt"
        PID1="$LEAVE_PID"
    fi
fi

# ---- boot 2 for the re-entry scenarios --------------------------------------
if [ "$SCENARIO" != "none" ]; then
    launch_and_log
    echo "pid=$PID (relaunch)" | tee -a "$OUT/pid.txt"
    [ -n "$PID" ] && [ "$PID" != "$PID1" ] || {
        red_evidence
        red_exit scenario "scenario.red" "relaunch pid is empty or unchanged ($PID1)"
    }
    wait_ready
    if [ -z "$READY" ]; then red_evidence; red_exit scenario "scenario.red" "relaunch never reached the ready marker"; fi
fi

# ---- evidence capture (boot 1 for none, boot 2 for back/crash) --------------
sleep 10
adb exec-out screencap -p > "$OUT/screenshot-1.png"
sleep 5
adb exec-out screencap -p > "$OUT/screenshot-2.png"
sleep 5
adb exec-out screencap -p > "$OUT/screenshot-3.png"
# 16 KB page-size evidence from THIS emulator (decision 011: claim-scope honesty).
adb shell getconf PAGE_SIZE > "$OUT/pagesize.txt" 2>&1 || true
ls -l "$OUT" | tee "$OUT/files.txt"

adb logcat -d -t 200000 > "$OUT/logcat-full.txt"
ORACLE_LOG="$OUT/logcat-full.txt"
if [ -n "$PID" ]; then
    if adb logcat -d --pid="$PID" -t 200000 > "$OUT/logcat-pid.txt"; then
        ORACLE_LOG="$OUT/logcat-pid.txt"
    fi
fi
echo "oracle-log=$ORACLE_LOG" >> "$OUT/pid.txt"

if grep -qE "$fatal" "$ORACLE_LOG"; then
    echo "ORACLE RED in $ORACLE_LOG:" | tee "$OUT/oracle.red"
    grep -nE "$fatal" "$ORACLE_LOG" | tee -a "$OUT/oracle.red"
    printf '{"rung":"%s","package":"%s","scenario":"%s","pid":"%s","oracle":"red"}\n' "$RUNG" "$PKG" "$SCENARIO" "$PID" > "$OUT/result.json"
    finish
    exit 1
fi

# Decision 011 parity fields: every rung must surface the Help > System Info content
# (Image compositor / Fallback / ...) and the device-limits record (SU-9/F26) logged by
# the shell. Missing either is a red result, not a prose claim.
PARITY=""
grep -aq "Picsh: SystemInfo: Image compositor: " "$ORACLE_LOG" || PARITY="systeminfo"
grep -aq "Picsh: device request: " "$ORACLE_LOG" || PARITY="${PARITY:+$PARITY }device-request"
if [ -n "$PARITY" ]; then
    echo "PARITY RED: missing in $ORACLE_LOG: $PARITY" | tee "$OUT/parity.red"
    printf '{"rung":"%s","package":"%s","scenario":"%s","pid":"%s","oracle":"red","parity":"%s"}\n' "$RUNG" "$PKG" "$SCENARIO" "$PID" "$PARITY" > "$OUT/result.json"
    finish
    exit 1
fi
echo "parity green: SystemInfo + device request captured" | tee "$OUT/parity.green"
grep -a "Picsh: SystemInfo: " "$ORACLE_LOG" > "$OUT/system-info.txt" || true
grep -a "Picsh: device request: " "$ORACLE_LOG" > "$OUT/device-request.txt" || true

# Decision 011 amendment 4 (user-approved api-31 gate): a rung passes only if the
# UI works (oracle + parity above) AND the ladder record is in the log - the
# "selected" line always; on api-31 additionally the exact Vulkan rejection
# reason (that image's SwiftShader Vulkan adapter cannot carry egui's device
# request, so the ladder must show WHY it moved down to GL).
LADDER=""
grep -aq "Picsh: gpu ladder: selected " "$ORACLE_LOG" || LADDER="ladder-selected"
case "$RUNG" in *api31*)
    grep -aq "Picsh: gpu ladder: rung vulkan: rejected: " "$ORACLE_LOG" || LADDER="${LADDER:+$LADDER }ladder-vulkan-rejection" ;;
esac
if [ -n "$LADDER" ]; then
    echo "LADDER RED: missing in $ORACLE_LOG: $LADDER" | tee "$OUT/ladder.red"
    printf '{"rung":"%s","package":"%s","scenario":"%s","pid":"%s","oracle":"red","ladder":"%s"}\n' "$RUNG" "$PKG" "$SCENARIO" "$PID" "$LADDER" > "$OUT/result.json"
    finish
    exit 1
fi
grep -a "Picsh: gpu ladder: " "$ORACLE_LOG" > "$OUT/gpu-ladder.txt" || true

# Re-entry scenario gates on the relaunch (boot 2) log: exactly one device
# request (one fresh ladder run in the new process), and for the crash scenario
# the one-shot skip line proves the marker kept the knob from firing twice.
if [ "$SCENARIO" != "none" ]; then
    SCENARIO2=""
    [ "$(grep -ac "Picsh: device request: " "$ORACLE_LOG" || true)" = "1" ] || SCENARIO2="${SCENARIO2:+$SCENARIO2 }device-request-count"
    if [ "$SCENARIO" = "crash" ]; then
        grep -aq "PHOTOCRAFT_TEST_CRASH already fired once" "$ORACLE_LOG" || SCENARIO2="${SCENARIO2:+$SCENARIO2 }one-shot-marker"
        grep -aq "Picsh: Rust panic" "$ORACLE_LOG" && SCENARIO2="${SCENARIO2:+$SCENARIO2 }panic-in-relaunch"
    fi
    if [ -n "$SCENARIO2" ]; then
        echo "SCENARIO RED: relaunch problems: $SCENARIO2 (judged on $ORACLE_LOG)" | tee "$OUT/scenario.red"
        printf '{"rung":"%s","package":"%s","scenario":"%s","pid":"%s","result":"red","gate":"relaunch","detail":"%s"}\n' "$RUNG" "$PKG" "$SCENARIO" "$PID" "$SCENARIO2" > "$OUT/result.json"
        finish
        exit 1
    fi
fi

echo "ORACLE GREEN on $ORACLE_LOG" | tee "$OUT/oracle.green"
printf '{"rung":"%s","package":"%s","scenario":"%s","pid":"%s","oracle":"green"}\n' "$RUNG" "$PKG" "$SCENARIO" "$PID" > "$OUT/result.json"

finish
echo "rung $RUNG done"
