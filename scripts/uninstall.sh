#!/bin/bash
# Removes LockDown. Refused while any block is locked. Run with sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo \"$0\"" >&2
  exit 1
fi

HELPER="/Library/PrivilegedHelperTools/com.lockdown.daemon"
USER_ID="${SUDO_UID:-$(stat -f %u /dev/console)}"

if [[ -x "$HELPER" ]] && ! "$HELPER" --can-uninstall; then
  exit 1
fi

# The daemon restores the original DNS settings and removes its firewall rules on a clean stop.
launchctl bootout "gui/$USER_ID/com.lockdown.agent" 2>/dev/null || true
launchctl bootout system/com.lockdown.daemon 2>/dev/null || true

rm -f /Library/LaunchDaemons/com.lockdown.daemon.plist /Library/LaunchAgents/com.lockdown.agent.plist "$HELPER"
rm -f /var/run/lockdownd.sock
/sbin/pfctl -a com.apple/250.LockDown -F all 2>/dev/null || true
rm -rf "/Library/Application Support/LockDown"
rm -rf /Applications/LockDown.app
echo "LockDown removed."
