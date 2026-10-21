#!/usr/bin/env bash
# One-time: install the emulator + an Android TV (API 31) image and make an AVD.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"; export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"
echo "== EMULATOR SETUP =="
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "emulator" "platform-tools"
echo "-- Android TV images available --"
sdkmanager --list 2>/dev/null | grep -iE "system-images;android-3[0-4];android-tv" | sort -u
IMG="system-images;android-31;android-tv;arm64-v8a"
echo "-- installing: $IMG --"
if sdkmanager "$IMG"; then
  echo no | avdmanager create avd -n MillsTV -k "$IMG" -d "tv_1080p" --force 2>/dev/null \
    || echo no | avdmanager create avd -n MillsTV -k "$IMG" --force
  echo "AVD 'MillsTV' ready. Next: bash emu.sh"
else
  echo "That image wasn't available. Paste the list above and I'll pick the right one."
fi
