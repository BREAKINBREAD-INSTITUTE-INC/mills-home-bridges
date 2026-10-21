#!/usr/bin/env bash
cd "$(dirname "$0")"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; PSK="${PSK:-0000}"; OUT="./out"
rm -rf "$OUT" 2>/dev/null; mkdir -p "$OUT"; R="$OUT/REPORT.txt"
echo "== TV toolkit run $(date) ==" | tee "$R"
echo "TV=$TV  PSK=${PSK:+set}" | tee -a "$R"
echo "--- port surface (what the TV exposes) ---" | tee -a "$R"
python3 - "$TV" <<'PY' | tee -a "$R"
import socket,sys
h=sys.argv[1]
ports={80:"Sony REST",443:"https",5555:"ADB",6466:"AndroidTV remote",6467:"AndroidTV remote(tls)",
8008:"Cast/DIAL",8009:"Cast",8080:"http-alt",9080:"?",10000:"?",20060:"Sony SimpleIP",
50001:"DIAL",52323:"DIAL"}
for p,label in ports.items():
    s=socket.socket(); s.settimeout(1.5)
    try: s.connect((h,p)); print(f"port {p:>5} OPEN   ({label})")
    except Exception: pass
    finally: s.close()
print("(only OPEN ports shown)")
PY
echo "--- Sony REST API (likely dead on VH2, trying anyway) ---" | tee -a "$R"
for c in info apps; do
  python3 tv.py --host "$TV" --psk "$PSK" --out "$OUT" "$c" 2>&1 | tee -a "$R"
done
echo "--- ADB inventory ---" | tee -a "$R"
bash adb_inventory.sh "$TV" "$OUT" 2>&1 | tee -a "$R"
echo "== DONE. Full results in $(pwd)/out/ ==" | tee -a "$R"
