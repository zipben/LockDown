#!/bin/bash
# Builds dist/LockDown.app (release, ad-hoc signed). No Apple Developer account needed.
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds for both Apple silicon and Intel (needs full Xcode).
FLAGS=(-c release)
[[ "${UNIVERSAL:-0}" == 1 ]] && FLAGS+=(--arch arm64 --arch x86_64)
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

APP="dist/LockDown.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/LockDown" "$APP/Contents/MacOS/LockDown"
cp "$BIN/lockdownd" "$APP/Contents/MacOS/lockdownd"
cp Resources/PressStart2P-Regular.ttf Resources/OFL-PressStart2P.txt "$APP/Contents/Resources/"
cp Resources/padlock-kenney-1bit.png Resources/LICENSE-Kenney-1BitPack.txt "$APP/Contents/Resources/"
cp scripts/install.sh scripts/uninstall.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh

# App icon rendered from the mascot sprite.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/LockDown" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The agent is a separate helper app with its own bundle ID. If it shared the main app's ID,
# opening LockDown.app would just activate the windowless agent instead of showing the UI.
AGENT="$APP/Contents/Library/LoginItems/LockDown Agent.app"
mkdir -p "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources"
cp "$BIN/LockDown" "$AGENT/Contents/MacOS/LockDown Agent"
cp Resources/PressStart2P-Regular.ttf "$APP/Contents/Resources/AppIcon.icns" "$AGENT/Contents/Resources/"
cp Support/Info.plist "$AGENT/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.lockdown.agent "$AGENT/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "LockDown Agent" "$AGENT/Contents/Info.plist"
plutil -replace CFBundleName -string "LockDown Agent" "$AGENT/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "LockDown Agent" "$AGENT/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$AGENT/Contents/Info.plist"

codesign --force -s - --identifier com.lockdown.daemon "$APP/Contents/MacOS/lockdownd"
codesign --force -s - "$AGENT"
codesign --force -s - "$APP"

echo "Built $APP"
