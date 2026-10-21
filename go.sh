#!/usr/bin/env bash
# One command: build -> install to the TV (home default UNCHANGED) -> launch -> screenshot.
# The screenshot lands in out/tv_shot.png and Claude reads it. Run: bash go.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"; export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
REPO="$HOME/Scripts/tv-vibehack/launcher"; OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; PKG="com.gathin.tvhome"

echo ">> build"
( cd "$REPO" && ./gradlew assembleRelease --console=plain ) || { echo "BUILD FAILED"; exit 1; }
APK="$REPO/app/build/outputs/apk/release/app-release.apk"

echo ">> connect $TV"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
$S shell true >/dev/null 2>&1 || { echo "TV not reachable at $TV. Wake it and retry."; exit 1; }

echo ">> install + launch (home default unchanged)"
$S install -r "$APK" | tail -1
$S shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION 2>/dev/null
$S shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true

echo ">> screenshot (waiting to settle)"; sleep 3
$S exec-out screencap -p > "$OUT/tv_shot.png"
echo "saved $OUT/tv_shot.png ($(wc -c < "$OUT/tv_shot.png") bytes) — Claude reads it from the folder."
