#!/bin/bash
# Builds dist/LockDown.app (release, ad-hoc signed). No Apple Developer account needed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="dist/LockDown.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/LockDown" "$APP/Contents/MacOS/LockDown"
cp "$BIN/lockdownd" "$APP/Contents/MacOS/lockdownd"
cp Resources/PressStart2P-Regular.ttf Resources/OFL-PressStart2P.txt "$APP/Contents/Resources/"
cp scripts/install.sh scripts/uninstall.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh

# App icon rendered from the mascot sprite.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/LockDown" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force -s - --identifier com.lockdown.daemon "$APP/Contents/MacOS/lockdownd"
codesign --force -s - "$APP"

echo "Built $APP"
