#!/usr/bin/env bash
# Read-only facts + pull the repo source for review. Run on the hub:
#   cd ~/Scripts/tv && bash repo_check.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "==================== MACHINE ===================="
echo "host: $(hostname)    macOS: $(sw_vers -productVersion 2>/dev/null)    arch: $(uname -m)"
echo "==================== JAVA ===================="
java -version 2>&1 | head -3 || echo "no java on PATH"
/usr/libexec/java_home -V 2>&1 | head -8 || echo "no JDKs registered"
echo "==================== GRADLE ===================="
if command -v gradle >/dev/null 2>&1; then gradle -v 2>/dev/null | grep -E 'Gradle|JVM' ; else echo "no gradle (repo may use ./gradlew wrapper)"; fi
echo "==================== ANDROID SDK ===================="
echo "ANDROID_HOME=${ANDROID_HOME:-unset}  ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-unset}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -d "$SDK" ]; then
  echo "sdk at: $SDK"
  echo "platforms:"; ls "$SDK/platforms" 2>/dev/null || echo "  none"
  echo "build-tools:"; ls "$SDK/build-tools" 2>/dev/null || echo "  none"
else echo "no Android SDK found at $SDK"; fi
command -v sdkmanager >/dev/null 2>&1 && echo "sdkmanager: yes" || echo "sdkmanager: no"
command -v adb >/dev/null 2>&1 && echo "adb: $(adb version 2>/dev/null | head -1)" || echo "adb: no"
echo "==================== GIT + REPO ===================="
command -v git >/dev/null 2>&1 && git --version || { echo "no git"; exit 0; }
cd "$HOME/Scripts"
if [ -d tv-vibehack/.git ]; then
  echo "repo already cloned; updating..."; (cd tv-vibehack && git pull --ff-only 2>&1 | tail -2)
else
  echo "cloning repo for review..."; git clone --depth 1 https://github.com/Gathin23/tv-vibehack.git 2>&1 | tail -3
fi
echo "---- repo layout ----"
find tv-vibehack -maxdepth 2 -not -path '*/.git/*' 2>/dev/null | sed "s|$HOME/Scripts/||" | sort | head -70
echo "==================== DONE ===================="
echo "Repo is at ~/Scripts/tv-vibehack for review."
