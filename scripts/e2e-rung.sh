#!/usr/bin/env bash
# One rendering-rung of the emulator e2e matrix (docs/decisions/009-ci-probes.md).
# Args: <rung-name> <package-name> <apk-path>
# Booted by android-emulator-runner's `script` step; kills the emulator at exit so
# the next rung step boots its own AVD.
set -o pipefail

[ $# -eq 3 ] || { echo "usage: e2e-rung.sh <rung> <package> <apk>"; exit 64; }
RUNG="$1"; PKG="$2"; APK="$3"
OUT="rungs/$RUNG"
mkdir -p "$OUT"
echo "rung=$RUNG package=$PKG apk=$APK" | tee "$OUT/config.txt"

fatal='FATAL EXCEPTION|ANR in .|Fatal signal 11|signal 11|panicked at|JNI DETECTED ERROR|UnsatisfiedLinkError|Validation Error|Device lost|StrictMode|invalid local reference'

adb uninstall "$PKG" >/dev/null 2>&1 || true
adb install -r "$APK" 2>&1 | tee "$OUT/install.log"

# Ready-marker + one relaunch (decision 011 amendment 3). A freshly booted emulator
# occasionally tears the activity down ~30 ms after resume while the launcher role is
# still being re-registered (observed once on the 3rd consecutive boot, run
# 39548313457 rungs/cpu: pause/stop/destroy with no FATAL, no Rust panic, no lmkd
# record; the same rung binary was green on two prior boots and boots 1-2 of that run).
# We therefore wait (bounded) for the app's own "device request:" log marker; if the
# pid died before any marker appeared, am start once more and re-capture the pid. No
# assertion changes: the oracle and parity below judge whatever is finally captured.
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

PID=""
launch_and_log
echo "pid=$PID" | tee "$OUT/pid.txt"

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

# Adapter/first-frame grace window after the marker (SwiftShader boots slowly).
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
    printf '{"rung":"%s","package":"%s","pid":"%s","oracle":"red"}\n' "$RUNG" "$PKG" "$PID" > "$OUT/result.json"
    adb shell am force-stop "$PKG" 2>/dev/null || true
    adb uninstall "$PKG" >/dev/null 2>&1 || true
    adb emu kill >/dev/null 2>&1 || true
    sleep 5
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
    printf '{"rung":"%s","package":"%s","pid":"%s","oracle":"red","parity":"%s"}\n' "$RUNG" "$PKG" "$PID" "$PARITY" > "$OUT/result.json"
    adb shell am force-stop "$PKG" 2>/dev/null || true
    adb uninstall "$PKG" >/dev/null 2>&1 || true
    adb emu kill >/dev/null 2>&1 || true
    sleep 5
    exit 1
fi
echo "parity green: SystemInfo + device request captured" | tee "$OUT/parity.green"
grep -a "Picsh: SystemInfo: " "$ORACLE_LOG" > "$OUT/system-info.txt" || true
grep -a "Picsh: device request: " "$ORACLE_LOG" > "$OUT/device-request.txt" || true

echo "ORACLE GREEN on $ORACLE_LOG" | tee "$OUT/oracle.green"
printf '{"rung":"%s","package":"%s","pid":"%s","oracle":"green"}\n' "$RUNG" "$PKG" "$PID" > "$OUT/result.json"

adb shell am force-stop "$PKG" 2>/dev/null || true
adb uninstall "$PKG" >/dev/null 2>&1 || true
adb emu kill >/dev/null 2>&1 || true
sleep 5
echo "rung $RUNG done"
