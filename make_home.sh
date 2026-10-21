#!/usr/bin/env bash
# Make MILLS TV your default home. Keeps the stock Sony home installed and enabled as a
# fallback (does NOT disable it), so reverting is one command. Run: bash make_home.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; PKG="com.gathin.tvhome"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
S="adb -s $TV:5555"
$S shell true >/dev/null 2>&1 || { echo "cannot reach the TV at $TV"; exit 1; }
$S shell cmd package set-home-activity --user 0 "$PKG/.MainActivity"
echo "MILLS TV is now your default home. Stock Sony home is still installed as a fallback."
echo "Revert anytime:  bash launcher_restore.sh"
