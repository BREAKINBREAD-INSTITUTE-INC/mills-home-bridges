#!/usr/bin/env bash
# tv_look.sh v1.0 (Oct 19 2026). Switch the MILLS OS TV look and put it on the TV.
#   bash tv_look.sh roomy    one idea per page, bigger type, 10 pages (the default)
#   bash tv_look.sh dense    more on each page, 8 pages (the first TV v2 look)
#   bash tv_look.sh          says which look is on
set -uo pipefail
cd "$(dirname "$0")"
L="${1:-}"
if [ -z "$L" ]; then echo "Look now: $(cat dashboard/look.txt 2>/dev/null || echo roomy)"; exit 0; fi
case "$L" in roomy|dense) ;; *) echo "Use: bash tv_look.sh roomy  or  bash tv_look.sh dense"; exit 1 ;; esac
echo "$L" > dashboard/look.txt
(cd dashboard && bash build_tv.sh >/dev/null) || { echo "FAIL: build failed. TV unchanged."; exit 1; }
bash show_dashboard.sh
echo "Look: $L"
