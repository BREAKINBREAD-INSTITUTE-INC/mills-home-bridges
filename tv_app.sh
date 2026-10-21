#!/usr/bin/env bash
# tv_app.sh v1.0 (Oct 19 2026). Build the MILLS OS TV app on HUB and install it on the TV.
# Run on the hub:  cd ~/Scripts/tv && bash tv_app.sh          (build + install + open the board)
#               bash tv_app.sh remove                      (uninstall the app; TVBro still works)
# The app shows the board full screen with no pointer; the remote's arrows and OK go to the page.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
APPDIR="$HOME/Scripts/tv/millsos-tv-app"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"
LOG="$OUT/tv_app_$(date +%Y%m%d_%H%M%S).log"
PKG=com.millsos.tv

adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
if ! $S shell true >/dev/null 2>&1; then echo "FAIL: TV not reachable or not authorized. Nothing changed." | tee -a "$LOG"; exit 1; fi

if [ "${1:-}" = "remove" ]; then
  $S uninstall "$PKG" 2>&1 | tee -a "$LOG"; echo "Removed. show_dashboard.sh goes back to TVBro."; exit 0
fi

echo "== BUILD $(date) ==" | tee "$LOG"
[ -d "$APPDIR" ] || { echo "FAIL: missing $APPDIR"; exit 1; }
cd "$APPDIR"
[ -f local.properties ] || echo "sdk.dir=$ANDROID_HOME" > local.properties
chmod +x ./gradlew 2>/dev/null || true
APK="$APPDIR/app/build/outputs/apk/release/app-release.apk"
rm -f "$APK"   # a failed build must never install an old APK
./gradlew assembleRelease --console=plain 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then echo "BUILD FAILED (gradle exit $RC). Nothing installed. TV unchanged. Log: $LOG" | tee -a "$LOG"; exit 1; fi
[ -f "$APK" ] || { echo "BUILD FAILED: no APK. Nothing installed." | tee -a "$LOG"; exit 1; }
echo "built: $(wc -c < "$APK") bytes, sha256 $(shasum -a 256 "$APK" | cut -c1-12)" | tee -a "$LOG"

echo "-- installing on the TV --" | tee -a "$LOG"
INS=$($S install -r "$APK" 2>&1); echo "$INS" | tee -a "$LOG"
echo "$INS" | grep -q Success || { echo "FAIL: install did not say Success." | tee -a "$LOG"; exit 1; }
$S shell pm path "$PKG" | tee -a "$LOG"

cd "$HOME/Scripts/tv" && bash show_dashboard.sh
echo "== DONE. Remote: left / right = page, OK = auto on or off, 1 to 8 = jump, Back = close, Menu = reload. =="
