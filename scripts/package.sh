#!/bin/bash
# Builds dist/LockDown-<version>.dmg holding an installer package and an uninstaller.
# The package is unsigned (no paid Apple Developer account): recipients open it with
# right-click > Open, or System Settings > Privacy & Security > Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL="${UNIVERSAL:-1}" ./scripts/build-app.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/root" "$WORK/scripts" "$WORK/dmg"
# No extended attributes: pkgbuild would store them as ._ files inside the bundle.
ditto --norsrc --noextattr --noacl dist/LockDown.app "$WORK/root/LockDown.app"
export COPYFILE_DISABLE=1

# Install to /Applications only; never "relocate" onto another copy of the app found elsewhere.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool false "$WORK/component.plist"

# The payload puts the app in place; install.sh then installs the daemon and agent.
cat > "$WORK/scripts/postinstall" <<'SH'
#!/bin/bash
exec "/Applications/LockDown.app/Contents/Resources/install.sh" /Applications/LockDown.app
SH
chmod +x "$WORK/scripts/postinstall"

PKG="$WORK/dmg/Install LockDown.pkg"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" \
  --scripts "$WORK/scripts" --identifier com.lockdown.pkg --version "$VERSION" \
  --install-location /Applications "$PKG"

cat > "$WORK/dmg/Uninstall LockDown.command" <<'SH'
#!/bin/bash
echo "Removing LockDown (asks for your password; refused while a block is locked)."
sudo /Applications/LockDown.app/Contents/Resources/uninstall.sh
SH
chmod +x "$WORK/dmg/Uninstall LockDown.command"

cat > "$WORK/dmg/READ ME.txt" <<TXT
LockDown $VERSION

INSTALL
1. Right-click "Install LockDown.pkg" and choose Open, then Open again.
   (If macOS only offers "Done": System Settings > Privacy & Security > Open Anyway.)
2. Enter your password when asked. Then open LockDown from Applications.

LockDown points your DNS at itself while a website block runs. Turn off encrypted DNS
profiles (e.g. NextDNS, under System Settings > Network > Filters) or blocks won't apply.

UNINSTALL
Double-click "Uninstall LockDown.command". It won't uninstall while a block is locked.

Requires macOS 14 or later.
TXT

DMG="dist/LockDown-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "LockDown $VERSION" -srcfolder "$WORK/dmg" -format UDZO "$DMG"
echo "Built $DMG"
