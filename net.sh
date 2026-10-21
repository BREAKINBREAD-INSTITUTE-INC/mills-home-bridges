#!/usr/bin/env bash
# Find/confirm the TV on the hub's network. Run: bash net.sh
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; OUT="./out"; mkdir -p "$OUT"; R="$OUT/NET.txt"
echo "== net diag $(date) ==" | tee "$R"
echo "--- hub IPs ---" | tee -a "$R"
ifconfig 2>/dev/null | grep -E 'inet ' | grep -v 127.0.0.1 | tee -a "$R"
echo "--- default gateway ---" | tee -a "$R"
route -n get default 2>/dev/null | grep -E 'gateway|interface' | tee -a "$R"
echo "--- ping TV $TV ---" | tee -a "$R"
ping -c 3 -t 3 "$TV" 2>&1 | tee -a "$R"
base=$(echo "$TV" | cut -d. -f1-3)
echo "--- ping sweep $base.0/24 (finding live hosts) ---" | tee -a "$R"
for i in $(seq 1 254); do ( ping -c1 -t1 "$base.$i" >/dev/null 2>&1 && echo "$base.$i alive" ) & done; wait
echo "--- arp table (MAC -> vendor hint; Sony OUIs often start with these) ---" | tee -a "$R"
arp -a 2>/dev/null | tee -a "$R"
echo "== net diag done: $(pwd)/out/NET.txt ==" | tee -a "$R"
