#!/bin/bash
# Retry pairing for up to ~15 minutes, so the Nest's sharing window can be opened at any point.
cd "$(dirname "$0")"
CODE="${1:?code}"
for i in $(seq 1 7); do
  echo "== attempt $i $(date +%T)"
  if node bridge.mjs pair "$CODE" 2>&1 | grep -vE "development values|test vendor" | tee -a pair.log | grep -q "^Paired"; then
    echo "PAIRED"; exit 0
  fi
  sleep 3
done
echo "GAVE UP"; exit 1
