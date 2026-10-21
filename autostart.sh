#!/usr/bin/env bash
# Make the MILLS OS board server run forever on the hub (survives logout/reboot).
# Run once on the hub:  cd ~/Scripts/tv && bash autostart.sh
set -e
PLIST="$HOME/Library/LaunchAgents/com.millsos.tvboard.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.millsos.tvboard</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HOME/Scripts/tv/dashboard/start.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Scripts/tv/dashboard/server.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Scripts/tv/dashboard/server.err.log</string>
</dict></plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 2
echo "LaunchAgent installed and loaded."
echo -n "health check: "; curl -s "http://localhost:8777/api/status" | head -c 60; echo
echo "The board server now starts at login and restarts itself if it ever dies."
