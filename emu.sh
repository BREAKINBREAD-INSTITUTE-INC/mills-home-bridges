#!/usr/bin/env bash
# Build + run on the EMULATOR ONLY + screenshot. Touches NO real TV. Run: bash emu.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"; export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"
REPO="$HOME/Scripts/tv-vibehack/launcher"; OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
APK="$REPO/app/build/outputs/apk/release/app-release.apk"
PKG="com.gathin.tvhome"

( cd "$REPO" && ./gradlew assembleRelease --console=plain ) || { echo "build failed — nothing to run"; exit 1; }

# Boot the emulator if it isn't already running.
if ! adb devices | grep -q "emulator-"; then
  echo "starting emulator (first boot takes ~1-2 min)..."
  nohup emulator -avd MillsTV -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect >/dev/null 2>&1 &
  until adb devices | grep -q "emulator-"; do sleep 2; done
fi

# Pin EVERY command to the emulator's serial, so a second device (the real TV) can't interfere.
EMU="$(adb devices | awk '/^emulator-/{print $1; exit}')"
if [ -z "$EMU" ]; then echo "no emulator found"; exit 1; fi
echo "using emulator: $EMU"
A() { adb -s "$EMU" "$@"; }

echo "waiting for boot..."; until [ "$(A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 3; done

A install -r "$APK"
# Make MILLS TV the home on the emulator so we see the real thing, not stock Google TV.
A shell cmd package set-home-activity "$PKG/.MainActivity" >/dev/null 2>&1 || true
A shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true
sleep 4
SHOT="$OUT/emu_$(date +%H%M%S).png"
A exec-out screencap -p > "$SHOT"
echo "screenshot: $SHOT"
echo "emulator serial for manual commands: $EMU"
echo "  Original return : adb -s $EMU shell am start -n $PKG/.OriginalActivity"
echo "  read crash log  : adb -s $EMU root >/dev/null 2>&1; adb -s $EMU shell cat /data/data/$PKG/files/crash/last_crash.txt 2>/dev/null || echo '(no crash logged yet)'"
