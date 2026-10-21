#!/usr/bin/env bash
# Is UniFi ad-block actually blocking? Checks how your network resolves known ad hosts.
echo "== Ad-block check (via your network DNS) =="
for h in googleadservices.com doubleclick.net googlesyndication.com ads.google.com; do
  ip=$(dig +short "$h" 2>/dev/null | tail -1)
  [ -z "$ip" ] && ip=$(nslookup "$h" 2>/dev/null | awk '/^Address: /{a=$2} END{print a}')
  case "$ip" in
    0.0.0.0|127.0.0.1|"") echo "  BLOCKED   $h  -> ${ip:-no answer}" ;;
    *)                    echo "  allowed   $h  -> $ip" ;;
  esac
done
echo
echo "If these say BLOCKED, ad-block is on. If 'allowed', turn it on in the UniFi app:"
echo "  Network > Settings > Security > Content Filtering (or CyberSecure > Ad Blocking) > enable for your network."
