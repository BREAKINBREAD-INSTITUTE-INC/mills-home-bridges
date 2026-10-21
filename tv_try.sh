#!/usr/bin/env bash
# Install MILLS TV on the real TV and show it, WITHOUT changing your home default.
# Your Home button still goes to the stock Sony home. Fully reversible. Run: bash tv_try.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"; export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
REPO="$HOME/Scripts/tv-vibehack/launcher"; OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; PKG="com.gathin.tvhome"

echo ">> building release APK"
( cd "$REPO" && ./gradlew assembleRelease --console=plain ) || { echo "build failed"; exit 1; }
APK="$REPO/app/build/outputs/apk/release/app-release.apk"

echo ">> connecting to TV $TV"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
if ! $S shell true >/dev/null 2>&1; then
  echo "cannot reach the TV at $TV. Make sure it is on and ADB/network debugging is enabled."; exit 1
fi

# Record the current stock home so revert knows what to restore.
STOCK="$($S shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -n1 | cut -d/ -f1 | tr -d '\r')"
case "$STOCK" in "$PKG"|""|*[!a-zA-Z0-9._]*) STOCK=com.google.android.apps.tv.launcherx ;; esac
echo "$STOCK" > "$OUT/stock_launcher.txt"
echo "   stock home recorded: $STOCK"

echo ">> installing (replaces any older MILLS build)"
$S install -r "$APK"
$S shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION 2>/dev/null; echo "   location permission granted (for Wi-Fi name)"

echo ">> launching MILLS TV (home default unchanged)"
$S shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true
echo
echo "MILLS TV is on your TV now, with your full dock."
echo "Your Home button STILL goes to the stock Sony home — nothing was made default."
echo "  Make it your home for real:   bash make_home.sh"
echo "  Put stock home back / remove: bash launcher_restore.sh"
