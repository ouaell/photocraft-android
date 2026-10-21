#!/usr/bin/env bash
# One rendering-rung of the emulator e2e matrix (docs/decisions/009-ci-probes.md).
# Args: <rung-name> <package-name> <apk-path> [scenario]
#   scenario (optional, default none):
#     back  - boot, press Back, the pid must exit cleanly ("Picsh: eframe loop
#             returned cleanly"), then a relaunch must show the UI again in a new
#             process (winit's one-event-loop re-entry gate, decision 011
#             amendment 3).
#     crash - the rungCrash apk (PHOTOCRAFT_TEST_CRASH=1, one-shot): pid 1 must
#             die right after the ready marker with the "PHOTOCRAFT_TEST_CRASH"
#             payload in logcat; the relaunch must come up normally (the marker
#             file skips the knob's second firing).
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

launch_and_log() {
    adb shell am start -n "$PKG/com.google.androidgamesdk.GameActivity" 2>&1 | tee -a "$OUT/am-start.log"
    local newpid=""
    for i in $(seq 1 30); do
        newpid="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r\n ')"
        [ -n "$newpid" ] && break
        sleep 2
    done
    PID="$newpid"
}

pid_gone() {   # true (0) once no process of the package is alive
    for i in $(seq 1 45); do
        adb shell pidof "$PKG" 2>/dev/null | grep -q "[0-9]" || return 0
        sleep 2
    done
    return 1
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

# Ready-marker + one relaunch (decision 011 amendment 3). A freshly booted emulator
# occasionally tears the activity down ~30 ms after resume while the launcher role is
# still being re-registered (observed once on the 3rd consecutive boot, run
# 39548313457 rungs/cpu: pause/stop/destroy with no FATAL, no Rust panic, no lmkd
# record; the same rung binary was green on two prior boots and boots 1-2 of that run).
# We therefore wait (bounded) for the app's own "device request:" log marker; if the
# pid died before any marker appeared, am start once more and re-capture the pid. No
# assertion changes: the oracle and parity below judge whatever is finally captured.
wait_ready() {
    READY=""
    for attempt in 1 2; do
        for i in $(seq 1 45); do
            if [ -n "$PID" ] && adb logcat -d --pid="$PID" -v time 2>/dev/null | grep -aq "Picsh: device request: "; then
                READY="yes"
                break
            fi
            if [ -n "$PID" ]; then
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
    if ! pid_gone; then
        red_exit scenario "scenario.red" "pid 1 never exited after the forced-crash boot"
    fi
    adb logcat -d --pid="$PID" -v time > "$OUT/logcat-boot1.txt" 2>/dev/null || true
    grep -aq "PHOTOCRAFT_TEST_CRASH" "$OUT/logcat-boot1.txt" || {
        red_exit scenario "scenario.red" "no PHOTOCRAFT_TEST_CRASH payload in the pid-1 logcat"
    }
    echo "scenario boot 1: forced crash observed, pid $PID gone" | tee "$OUT/scenario-boot1.txt"
    PID1="$PID"
else
    wait_ready
    PID1="$PID"
    if [ "$SCENARIO" = "back" ]; then
        # Adapter/first-frame grace window, one UI-visible shot, then Back.
        sleep 10
        adb exec-out screencap -p > "$OUT/screenshot-boot1.png"
        adb shell input keyevent 4 2>&1 | tee "$OUT/back.log"
        if ! pid_gone; then
            red_exit scenario "scenario.red" "pid 1 did not exit within 90s of Back"
        fi
        adb logcat -d --pid="$PID1" -v time > "$OUT/logcat-boot1.txt" 2>/dev/null || true
        grep -aq "Picsh: eframe loop returned cleanly" "$OUT/logcat-boot1.txt" || {
            red_exit scenario "scenario.red" "no clean-exit line in the pid-1 logcat"
        }
        echo "scenario boot 1: Back pressed, pid $PID1 exited cleanly" | tee "$OUT/scenario-boot1.txt"
    fi
fi

# ---- boot 2 for the re-entry scenarios --------------------------------------
if [ "$SCENARIO" != "none" ]; then
    launch_and_log
    echo "pid=$PID (relaunch)" | tee -a "$OUT/pid.txt"
    [ -n "$PID" ] && [ "$PID" != "$PID1" ] || {
        red_exit scenario "scenario.red" "relaunch pid is empty or unchanged ($PID1)"
    }
    wait_ready
    [ -n "$READY" ] || red_exit scenario "scenario.red" "relaunch never reached the ready marker"
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
