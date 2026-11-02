#!/bin/bash
# Installs LockDown's root daemon and per-user agent. Run with sudo.
# Usage: sudo install.sh [path/to/LockDown.app]   (defaults to the app containing this script)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo \"$0\"" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="${1:-$(cd "$HERE/../.." && pwd)}"
APP="/Applications/LockDown.app"
HELPER="/Library/PrivilegedHelperTools/com.lockdown.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/com.lockdown.daemon.plist"
AGENT_PLIST="/Library/LaunchAgents/com.lockdown.agent.plist"
USER_ID="${SUDO_UID:-$(stat -f %u /dev/console)}"

if [[ ! -x "$SRC_APP/Contents/MacOS/lockdownd" ]]; then
  echo "Can't find LockDown.app at $SRC_APP" >&2
  exit 1
fi

# Copy the app into /Applications unless we're already running from there.
if [[ "$SRC_APP" != "$APP" ]]; then
  echo "Copying app to $APP"
  launchctl bootout "gui/$USER_ID/com.lockdown.agent" 2>/dev/null || true
  rm -rf "$APP"
  ditto "$SRC_APP" "$APP"
fi
chown -R root:wheel "$APP"
chmod -R go-w "$APP"

# The daemon lives outside the app bundle so deleting the app doesn't remove it.
mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$APP/Contents/MacOS/lockdownd" "$HELPER"

cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.lockdown.daemon</string>
  <key>ProgramArguments</key><array><string>$HELPER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardErrorPath</key><string>/var/log/lockdownd.log</string>
  <key>AssociatedBundleIdentifiers</key><array><string>com.lockdown.app</string></array>
</dict>
</plist>
EOF

cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.lockdown.agent</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/LockDown</string><string>--agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>AssociatedBundleIdentifiers</key><array><string>com.lockdown.app</string></array>
</dict>
</plist>
EOF
chown root:wheel "$DAEMON_PLIST" "$AGENT_PLIST"
chmod 644 "$DAEMON_PLIST" "$AGENT_PLIST"

echo "Starting daemon"
launchctl bootout system/com.lockdown.daemon 2>/dev/null || true
launchctl bootstrap system "$DAEMON_PLIST"

echo "Starting agent for user $USER_ID"
launchctl bootout "gui/$USER_ID/com.lockdown.agent" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" "$AGENT_PLIST"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -S /var/run/lockdownd.sock ]] && break
  sleep 0.5
done
if [[ -S /var/run/lockdownd.sock ]]; then
  echo "LockDown is installed. Open /Applications/LockDown.app to set up blocks."
else
  echo "Daemon didn't start; see /var/log/lockdownd.log" >&2
  exit 1
fi
