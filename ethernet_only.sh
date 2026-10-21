#!/usr/bin/env bash
# Move the TV to Ethernet and turn Wi-Fi off — safely. PLUG THE ETHERNET CABLE IN FIRST.
# Run: cd ~/Scripts/tv && bash ethernet_only.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "Can't reach the TV at $TV. Wake it / run tv_connect.sh first."; exit 1; }

echo "Looking for the Ethernet address..."
ETH=""
for IF in eth0 eth1 eth2; do
  IP=$($S shell ip -f inet addr show "$IF" </dev/null 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  [ -n "$IP" ] && { ETH="$IP"; break; }
done
if [ -z "$ETH" ]; then
  echo "No Ethernet IP found. Is the cable plugged in and the link up?"
  echo "Check the TV: Settings > Network > see that Ethernet is connected, then re-run."
  exit 1
fi
echo "Ethernet IP: $ETH"
adb connect "$ETH:5555" >/dev/null 2>&1; sleep 1
if adb -s "$ETH:5555" shell true </dev/null >/dev/null 2>&1; then
  echo "Reachable over Ethernet. Turning Wi-Fi OFF..."
  adb -s "$ETH:5555" shell svc wifi disable </dev/null
  echo
  echo "== DONE. Wi-Fi is off; the TV is on Ethernet at $ETH =="
  echo "From now, point the scripts at the new address, e.g.:"
  echo "   TV=$ETH bash tv_connect.sh"
  echo "Make it stick: in UniFi, give this TV a fixed IP (DHCP reservation) so $ETH never changes."
else
  echo "Could not reach the TV over Ethernet yet — leaving Wi-Fi ON so you don't lose access."
  echo "Check the cable/link, confirm Ethernet shows connected on the TV, then re-run."
fi
