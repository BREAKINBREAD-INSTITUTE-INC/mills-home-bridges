#!/usr/bin/env bash
# Turn TV-level ad-block on/off via Android Private DNS (AdGuard). Reversible.
#   bash set_adblock_dns.sh on     (default)
#   bash set_adblock_dns.sh off
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"; MODE="${1:-on}"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable. Wake it, run tv_connect.sh, retry."; exit 1; }
if [ "$MODE" = "off" ]; then
  $S shell settings put global private_dns_mode off </dev/null
  echo "Ad-block DNS OFF (Private DNS disabled)."
else
  $S shell settings put global private_dns_mode hostname </dev/null
  $S shell settings put global private_dns_specifier dns.adguard-dns.com </dev/null
  echo "Ad-block DNS ON -> dns.adguard-dns.com"
fi
echo "mode:      $($S shell settings get global private_dns_mode </dev/null | tr -d '\r')"
echo "resolver:  $($S shell settings get global private_dns_specifier </dev/null | tr -d '\r')"
echo "give it ~10s, then the home screen's Ad-block light should go teal."
