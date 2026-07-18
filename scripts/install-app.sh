#!/bin/bash
# Bundle ShifuApp into a standalone Shifu.app (menu bar app) and install it.
# The capture daemon is separate — see install-daemon.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product ShifuApp
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ -w /Applications ]; then
    APP_ROOT=/Applications
else
    APP_ROOT="$HOME/Applications"
    mkdir -p "$APP_ROOT"
fi
APP="$APP_ROOT/Shifu.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN_DIR/ShifuApp" "$APP/Contents/MacOS/Shifu"
cp -R "$BIN_DIR/GRDB.framework" "$APP/Contents/Frameworks/"
# The build product resolves GRDB via @loader_path (framework next to the
# binary); inside a bundle it lives in Contents/Frameworks instead.
if ! otool -l "$APP/Contents/MacOS/Shifu" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Shifu"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Shifu</string>
    <key>CFBundleIdentifier</key><string>com.shifu.app</string>
    <key>CFBundleName</key><string>Shifu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Same identity logic as install-daemon.sh; install_name_tool invalidates the
# linker signature, and arm64 refuses to run unsigned code, so always re-sign.
IDENTITY="${SHIFU_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/[0-9]+\)/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/GRDB.framework"
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "installed $APP"
echo "launch: open \"$APP\"   (menu bar eye icon; no Dock icon)"
echo "start at login: System Settings → General → Login Items → + → Shifu.app"
