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

adb shell am start -n "$PKG/com.google.androidgamesdk.GameActivity" 2>&1 | tee "$OUT/am-start.log"

PID=""
for i in $(seq 1 30); do
    PID="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r\n ')"
    [ -n "$PID" ] && break
    sleep 2
done
echo "pid=$PID" | tee "$OUT/pid.txt"

# Adapter/first-frame window (SwiftShader boots slowly; generous but bounded).
sleep 15
adb exec-out screencap -p > "$OUT/screenshot-1.png"
sleep 5
adb exec-out screencap -p > "$OUT/screenshot-2.png"
sleep 5
adb exec-out screencap -p > "$OUT/screenshot-3.png"
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

echo "ORACLE GREEN on $ORACLE_LOG" | tee "$OUT/oracle.green"
printf '{"rung":"%s","package":"%s","pid":"%s","oracle":"green"}\n' "$RUNG" "$PKG" "$PID" > "$OUT/result.json"

adb shell am force-stop "$PKG" 2>/dev/null || true
adb uninstall "$PKG" >/dev/null 2>&1 || true
adb emu kill >/dev/null 2>&1 || true
sleep 5
echo "rung $RUNG done"
