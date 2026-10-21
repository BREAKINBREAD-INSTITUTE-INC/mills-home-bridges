#!/usr/bin/env bash
# Compile-only gate — builds the APK, installs NOTHING. Run: bash check.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export JAVA_HOME="$(brew --prefix openjdk@17)"; export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
REPO="$HOME/Scripts/tv-vibehack/launcher"; cd "$REPO"
[ -f local.properties ] || echo "sdk.dir=$ANDROID_HOME" > local.properties
echo "== COMPILE CHECK $(date) =="
./gradlew assembleRelease --console=plain; RC=${PIPESTATUS[0]}
if [ "$RC" -eq 0 ]; then echo "GREEN — compiles & lint ok. Nothing installed."; else echo "FAILED (exit $RC). Nothing installed."; fi
exit $RC
