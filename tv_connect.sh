#!/usr/bin/env bash
# Reconnect ADB to the TV and install the already-built launcher APK.
# Run on the hub:  cd ~/Scripts/tv && bash tv_connect.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"
APK="$HOME/Scripts/tv-vibehack/launcher/app/build/outputs/apk/release/app-release.apk"
S="adb -s $TV:5555"

echo "== make sure the TV is ON and showing a screen before this runs =="
adb kill-server >/dev/null 2>&1; sleep 1
adb start-server >/dev/null 2>&1
echo "-- connecting to $TV:5555 --"
adb connect "$TV:5555"
sleep 2
echo "-- device state --"
adb devices

if ! $S shell true >/dev/null 2>&1; then
  echo
  echo "STILL CANT REACH THE TV. Do this on the TV, then re-run:"
  echo "  1. Wake it up, get to the home screen."
  echo "  2. Settings > System > About > scroll to Build, click 7x (Developer mode)."
  echo "  3. Settings > System > Developer options > turn ON 'Network debugging' / 'ADB debugging'."
  echo "  4. When you re-run this, WATCH THE TV for an 'Allow debugging?' box and hit Allow (check Always)."
  exit 1
fi

echo "-- TV reachable. installing new launcher ($(wc -c < "$APK") bytes) --"
$S install -r "$APK"
$S shell pm grant com.gathin.tvhome android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
$S shell cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity
$S shell pm disable-user --user 0 com.google.android.apps.tv.launcherx 2>/dev/null || true
echo "== DONE. Press HOME on the remote. You should see the new background + 5-app dock. =="
