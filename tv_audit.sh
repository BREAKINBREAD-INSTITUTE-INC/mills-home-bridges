#!/usr/bin/env bash
# Full TV audit: space, biggest app data/cache, running/memory, live tiles. Read-only.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
TV="${TV:?set TV to the TV IP address, e.g. TV=192.168.1.x}"; S="adb -s $TV:5555"
OUT="$HOME/Scripts/tv/out"; mkdir -p "$OUT"; A="$OUT/audit"; mkdir -p "$A"
adb connect "$TV:5555" >/dev/null 2>&1; sleep 1
$S shell true </dev/null >/dev/null 2>&1 || { echo "TV not reachable. Wake it, run tv_connect.sh, retry."; exit 1; }

echo "== 1. STORAGE =="
$S shell df -h /data </dev/null | tr -d '\r'

echo; echo "== 2. BIGGEST APPS (data + cache) =="
$S shell dumpsys diskstats </dev/null > "$A/diskstats.txt" 2>/dev/null
python3 - "$A/diskstats.txt" <<'PY'
import sys,re,json
raw=open(sys.argv[1]).read()
def arr(key):
    m=re.search(key+r':\s*(\[.*?\])',raw)
    if not m: return []
    try: return json.loads(m.group(1))
    except: return []
names=arr("Package Names"); app=arr("App Sizes"); data=arr("App Data Sizes"); cache=arr("Cache Sizes")
rows=[]
for i,n in enumerate(names):
    a=app[i] if i<len(app) else 0
    d=data[i] if i<len(data) else 0
    c=cache[i] if i<len(cache) else 0
    rows.append((n,(a or 0)+(d or 0)+(c or 0),c or 0))
rows.sort(key=lambda x:-x[1])
print("  %-44s %10s %10s" % ("package","total","cache"))
for n,t,c in rows[:22]:
    print("  %-44s %9.1fM %9.1fM" % (n, t/1e6, c/1e6))
PY

echo; echo "== 3. TOP MEMORY (running) =="
$S shell dumpsys meminfo </dev/null | tr -d '\r' | sed -n '/Total PSS by process/,/Total PSS by OOM/p' | head -26

echo; echo "== 4. APPS THAT STILL SHOW AS TILES =="
$S shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER </dev/null \
  | tr -d '\r' | grep -oE '[a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_.]+/[A-Za-z0-9_.$]+' | cut -d/ -f1 | sort -u

echo; echo "== paste all of this back to Claude =="
