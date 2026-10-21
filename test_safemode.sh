#!/usr/bin/env bash
# Proves the safety net on the EMULATOR with REAL crashes. Builds+installs the DEBUG build
# (the only build where the crash hook exists), then:
#   TEST 1  Original button           -> Home picker
#   TEST 2  three real crashes        -> watchdog trips -> safe mode -> Home picker (logcat proof)
# Then clears app data to reset. Touches NO real TV. Run: bash test_safemode.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"; export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"
REPO="$HOME/Scripts/tv-vibehack/launcher"; OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
PKG="com.gathin.tvhome"
EMU="$(adb devices | awk '/^emulator-/{print $1; exit}')"
[ -z "$EMU" ] && { echo "no emulator running — run emu.sh first"; exit 1; }
A() { adb -s "$EMU" "$@"; }
echo "emulator: $EMU"

echo ">> building + installing DEBUG build (crash hook lives only here)"
( cd "$REPO" && ./gradlew assembleDebug --console=plain ) || { echo "debug build failed"; exit 1; }
A install -r "$REPO/app/build/outputs/apk/debug/app-debug.apk"
A shell cmd package set-home-activity "$PKG/.MainActivity" >/dev/null 2>&1 || true
A shell pm clear "$PKG" >/dev/null 2>&1 || true   # start from a clean watchdog state

# ---------- TEST 1: the Original button ----------
echo; echo ">> TEST 1  Original button (the one-button way back)"
A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true; sleep 2
A shell am start -n "$PKG/.OriginalActivity" >/dev/null 2>&1 || true; sleep 3
S1="$OUT/test1_original_$(date +%H%M%S).png"; A exec-out screencap -p > "$S1"
echo "   screenshot (should be the Home-app picker): $S1"
A shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true; sleep 1

# ---------- TEST 2: three real crashes -> safe mode ----------
echo; echo ">> TEST 2  three real crashes"
A logcat -c 2>/dev/null || true
for n in 1 2 3; do
  A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true; sleep 3
  echo "   firing crash #$n"
  A shell am broadcast -a com.gathin.tvhome.DEBUG_CRASH >/dev/null 2>&1 || true
  sleep 3
done
echo "   relaunching home after the loop (should refuse to draw, open Home picker)"
A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true; sleep 4
S2="$OUT/test2_safemode_$(date +%H%M%S).png"; A exec-out screencap -p > "$S2"
echo "   screenshot (should be the Home-app picker, NOT the calm home): $S2"
echo "   --- logcat proof (expect: safe mode at boot ...) ---"
A logcat -d -s MillsWatchdog | tail -8
echo "   --- crash log the watchdog wrote ---"
A shell run-as "$PKG" cat files/crash/last_crash.txt 2>/dev/null | head -8 || echo "   (could not read crash log)"

# ---------- RESET ----------
echo; echo ">> RESET (clear app data -> normal)"
A shell pm clear "$PKG" >/dev/null 2>&1 || true
A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true; sleep 4
S3="$OUT/test3_reset_$(date +%H%M%S).png"; A exec-out screencap -p > "$S3"
echo "   screenshot (calm home again): $S3"
echo; echo "done. (debug build is installed; run 'bash emu.sh' to put the release build back)"
