#!/usr/bin/env bash
# Build the tv-vibehack launcher and make it the TV's home screen.
# Run on the hub:  cd ~/Scripts/tv && bash launcher_build.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
REPO="$HOME/Scripts/tv-vibehack/launcher"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
LOG="$OUT/launcher_build_$(date +%Y%m%d_%H%M%S).log"

echo "== BUILD $(date) ==" | tee "$LOG"
cd "$REPO"
[ -f local.properties ] || echo "sdk.dir=$ANDROID_HOME" > local.properties
chmod +x ./gradlew 2>/dev/null || true
echo "building (first run downloads Gradle + deps, give it a few minutes)..." | tee -a "$LOG"
APK="$REPO/app/build/outputs/apk/release/app-release.apk"
# Remove the last APK first, so a failed build can never install an old one (Oct 19 fix).
rm -f "$APK" 2>/dev/null || mv -f "$APK" "$OUT/old-app-release.apk" 2>/dev/null || true
./gradlew assembleRelease --console=plain 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then echo "BUILD FAILED (gradle exit $RC). Nothing installed. TV unchanged." | tee -a "$LOG"; exit 1; fi
if [ ! -f "$APK" ]; then echo "BUILD FAILED: no APK produced. Nothing installed." | tee -a "$LOG"; exit 1; fi
echo "built APK: $(wc -c < "$APK") bytes" | tee -a "$LOG"

adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
if ! $S shell true >/dev/null 2>&1; then echo "TV not reachable/authorized." | tee -a "$LOG"; exit 1; fi

# Save the current (stock) home launcher so restore is exact. Ignore our own if this is a rerun.
STOCK=$($S shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -n1 | cut -d/ -f1 | tr -d '\r')
case "$STOCK" in com.gathin.tvhome|*[!a-zA-Z0-9._]*|"") STOCK=com.google.android.apps.tv.launcherx ;; esac
echo "$STOCK" > "$OUT/stock_launcher.txt"
echo "stock launcher saved for restore: $STOCK" | tee -a "$LOG"

echo "-- installing launcher on TV --" | tee -a "$LOG"
$S install -r "$APK" 2>&1 | tee -a "$LOG"
$S shell pm grant com.gathin.tvhome android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
$S shell cmd package compile -m speed -f com.gathin.tvhome 2>&1 | tee -a "$LOG" || true
$S shell cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity 2>&1 | tee -a "$LOG"
$S shell pm disable-user --user 0 "$STOCK" 2>&1 | tee -a "$LOG"
echo "== DONE. Press HOME on the remote to see your new launcher. ==" | tee -a "$LOG"
echo "Undo anytime:  bash launcher_restore.sh" | tee -a "$LOG"
