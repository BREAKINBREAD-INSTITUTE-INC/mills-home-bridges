#!/usr/bin/env bash
# Captures every screen on the emulator so we can review the whole build at once.
# Drives with D-pad key events; emulator only. Run: bash test_tour.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"; PKG="com.gathin.tvhome"
EMU="$(adb devices | awk '/^emulator-/{print $1; exit}')"
[ -z "$EMU" ] && { echo "no emulator — run emu.sh first"; exit 1; }
A(){ adb -s "$EMU" "$@"; }
K(){ A shell input keyevent "$1" >/dev/null 2>&1; }
shot(){ sleep 2; local f="$OUT/tour_$1_$(date +%H%M%S).png"; A exec-out screencap -p > "$f"; echo "  $1 -> $f"; }
home(){ K 3; sleep 2; }      # KEYCODE_HOME

echo "emulator: $EMU"
echo "1) HOME (dusk wallpaper + weather)";           home; shot home
echo "2) COMMAND CENTER (press DOWN)";               K 20; shot command_center
echo "3) MISSION CONTROL / AI TEAM (select card)";   K 23; shot ai_team; 
echo "4) APPS EDITOR (home -> UP -> select grid)";   home; K 19; K 23; shot apps_editor
echo "5) BACKGROUND picker (nav within settings)";   K 19; K 23; sleep 1; shot settings_open
home
echo "done. screenshots in $OUT (tour_*.png)"
