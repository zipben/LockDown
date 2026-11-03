#!/bin/bash
# Removes Cold Turkey Blocker (app, keep-alive agent, helpers, data). Run with sudo.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_ID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"

# The agent is KeepAlive, so unload it before killing anything or launchd restarts it.
launchctl bootout "gui/$USER_ID/launchkeep.cold-turkey" 2>/dev/null
launchctl bootout "gui/$USER_ID" /Library/LaunchAgents/com.getcoldturkey.blocker.agent.plist 2>/dev/null
pkill -f "/Applications/Cold Turkey Blocker.app/" 2>/dev/null
sleep 1
pkill -9 -f "/Applications/Cold Turkey Blocker.app/" 2>/dev/null

rm -f /Library/LaunchAgents/com.getcoldturkey.blocker.agent.plist
rm -rf "/Applications/Cold Turkey Blocker.app"
rm -rf "/Library/Application Support/Cold Turkey"
rm -f "$USER_HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.coldturkey.coldturkey.json"
rm -f "$USER_HOME/Library/Application Support/Mozilla/NativeMessagingHosts/com.coldturkey.coldturkey.json"
rm -f "$USER_HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.coldturkey.coldturkey.json"
rm -f "$USER_HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.coldturkey.coldturkey.json"
rm -f "$USER_HOME/Library/Preferences/com.getcoldturkey.blocker.plist"
rm -rf "$USER_HOME/Library/Application Support/Cold Turkey"
# Sandbox containers are protected by macOS; these may be refused, which is harmless.
rm -rf "$USER_HOME/Library/Containers/com.getcoldturkey.blocker-safari-ext" 2>/dev/null
rm -rf "$USER_HOME/Library/Group Containers/group.getcoldturkey.blocker-shared-data" 2>/dev/null

if pgrep -f "Cold Turkey Blocker" >/dev/null || [ -e "/Applications/Cold Turkey Blocker.app" ]; then
  echo "Cold Turkey is still partly present:"; pgrep -lf "Cold Turkey Blocker"; exit 1
fi
echo "Cold Turkey removed. Remove its extension from Chrome/Firefox/Edge/Safari by hand if it's still listed."
