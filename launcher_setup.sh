#!/usr/bin/env bash
# One-time: install the Android build toolchain on the hub (JDK 17 + Android SDK 34).
# Run on the hub:  cd ~/Scripts/tv && bash launcher_setup.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "== JDK 17 =="
brew list openjdk@17 >/dev/null 2>&1 || brew install openjdk@17
JAVA_HOME="$(brew --prefix openjdk@17)"; export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
java -version 2>&1 | head -2
echo "== Android command-line tools =="
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
SDK="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_HOME="$SDK"
echo "sdk root: $SDK"
echo "== licenses + platform 34 + build-tools 34 (downloads ~ a few hundred MB) =="
yes | sdkmanager --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
sdkmanager --sdk_root="$SDK" "platform-tools" "platforms;android-34" "build-tools;34.0.0"
echo "== verify =="
echo "platforms:";   ls "$SDK/platforms" 2>/dev/null
echo "build-tools:"; ls "$SDK/build-tools" 2>/dev/null
echo "JAVA_HOME=$JAVA_HOME"
echo "DONE. Toolchain ready for the launcher build."
