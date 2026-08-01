#!/bin/bash
# Assemble a self-contained, UNSIGNED Shifu.app at $1 (default: dist/Shifu.app).
# All four executables ship in Contents/MacOS so they resolve each other as
# siblings (ShifuPaths.helper); GRDB rides in Contents/Frameworks via one rpath
# rule. Shared by install-app.sh (dev signing) and release.sh (Developer ID +
# notarization) so bundle layout is defined exactly once.
#
# Env: SHIFU_VERSION (default 0.1.0), SHIFU_BUILD (default: git commit count).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-dist/Shifu.app}"
VERSION="${SHIFU_VERSION:-0.1.0}"
BUILD="${SHIFU_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release --product ShifuApp
swift build -c release --product shifud
swift build -c release --product shifu-analyzer
swift build -c release --product shifu
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" \
         "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"

cp "$BIN_DIR/ShifuApp" "$APP/Contents/MacOS/Shifu"
cp "$BIN_DIR/shifud" "$BIN_DIR/shifu-analyzer" "$BIN_DIR/shifu" "$APP/Contents/MacOS/"
cp -R "$BIN_DIR/GRDB.framework" "$APP/Contents/Frameworks/"
cp "Sources/ShifuApp/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "scripts/com.shifu.shifud.bundled.plist" \
   "$APP/Contents/Library/LaunchAgents/com.shifu.shifud.plist"

# Build products resolve GRDB via @loader_path (framework beside the binary);
# inside the bundle it lives in Contents/Frameworks instead. install_name_tool
# invalidates the linker signature, so callers must always re-sign after this.
for BINARY in Shifu shifud shifu-analyzer shifu; do
    if ! otool -l "$APP/Contents/MacOS/$BINARY" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$BINARY"
    fi
done

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    scripts/Info.plist.template > "$APP/Contents/Info.plist"

echo "assembled $APP (version $VERSION, build $BUILD) — unsigned"
