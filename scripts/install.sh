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

# launchctl bootout returns before the old process has fully exited; bootstrapping during
# that window fails with "Bootstrap failed: 5: Input/output error". Wait, then retry.
stop_service() {  # domain/label
  launchctl bootout "$1" 2>/dev/null || true
  for _ in $(seq 1 40); do
    launchctl print "$1" >/dev/null 2>&1 || return 0
    sleep 0.25
  done
}

start_service() {  # domain plist label
  for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$1" "$2" 2>/dev/null; then return 0; fi
    launchctl print "$1/$3" >/dev/null 2>&1 && return 0  # already loaded
    sleep 1
  done
  echo "Couldn't start $3:" >&2
  launchctl bootstrap "$1" "$2"  # one last try that shows launchd's error
}

if [[ ! -x "$SRC_APP/Contents/MacOS/lockdownd" ]]; then
  echo "Can't find LockDown.app at $SRC_APP" >&2
  exit 1
fi

# Copy the app into /Applications unless we're already running from there.
if [[ "$SRC_APP" != "$APP" ]]; then
  echo "Copying app to $APP"
  stop_service "gui/$USER_ID/com.lockdown.agent"
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
  <key>ProgramArguments</key><array><string>$APP/Contents/Library/LoginItems/LockDown Agent.app/Contents/MacOS/LockDown Agent</string><string>--agent</string></array>
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
stop_service system/com.lockdown.daemon
start_service system "$DAEMON_PLIST" com.lockdown.daemon

echo "Starting agent for user $USER_ID"
stop_service "gui/$USER_ID/com.lockdown.agent"
start_service "gui/$USER_ID" "$AGENT_PLIST" com.lockdown.agent

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
