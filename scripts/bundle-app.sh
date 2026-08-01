#!/bin/bash
# Assemble a self-contained, UNSIGNED Shifu.app at $1 (default: dist/Shifu.app).
# All four executables ship in Contents/MacOS so they resolve each other as
# siblings (ShifuPaths.helper); GRDB rides in Contents/Frameworks via one rpath
# rule. Shared by install-app.sh (dev signing) and release.sh (Developer ID +
# notarization) so bundle layout is defined exactly once.
#
# Env: SHIFU_VERSION (default: the version in ShifuCore), SHIFU_BUILD (default:
# git commit count), SHIFU_EDITION (standard | qwen, default standard — which
# backend choices the bundle offers; see Edition in ShifuCore).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-dist/Shifu.app}"
# The version is written once, in ShifuCore, and stamped from there into the
# plist below — which Shifu.version reads back at runtime. A bundle therefore
# cannot report a version other than the one it was assembled as; v0.1.1 shipped
# an About page saying 0.1.0 because the two were separate constants.
VERSION="${SHIFU_VERSION:-$(sed -n \
    's/^ *static let fallbackVersion = "\(.*\)"$/\1/p' Sources/ShifuCore/ShifuCore.swift)}"
if [ -z "$VERSION" ]; then
    echo "ERROR: no version in Sources/ShifuCore/ShifuCore.swift — did fallbackVersion move?" >&2
    exit 1
fi
BUILD="${SHIFU_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# The edition is a stamp, not a build variant: the binaries are identical,
# and Edition.current reads this plist key back at runtime. Validated here
# because a typo would silently assemble a standard bundle.
EDITION="${SHIFU_EDITION:-standard}"
case "$EDITION" in
    standard|qwen) ;;
    *) echo "ERROR: SHIFU_EDITION must be 'standard' or 'qwen', got '$EDITION'" >&2
       exit 1 ;;
esac

swift build -c release --product ShifuApp
swift build -c release --product shifud
swift build -c release --product shifu-analyzer
swift build -c release --product shifu
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" \
         "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"

# The GUI executable keeps its product name: as "Shifu" it collides with the
# CLI "shifu" on case-insensitive filesystems, and the last copy silently
# wins — v0.1.0 shipped with the CLI in the app's seat.
cp "$BIN_DIR/ShifuApp" "$APP/Contents/MacOS/ShifuApp"
cp "$BIN_DIR/shifud" "$BIN_DIR/shifu-analyzer" "$BIN_DIR/shifu" "$APP/Contents/MacOS/"
for PRODUCT in ShifuApp shifu; do
    cmp -s "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT" || {
        echo "ERROR: $PRODUCT in the bundle is not the built $PRODUCT — name collision?" >&2
        exit 1
    }
done
cp -R "$BIN_DIR/GRDB.framework" "$APP/Contents/Frameworks/"
cp "Sources/ShifuApp/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "scripts/com.shifu.shifud.bundled.plist" \
   "$APP/Contents/Library/LaunchAgents/com.shifu.shifud.plist"

# Build products resolve GRDB via @loader_path (framework beside the binary);
# inside the bundle it lives in Contents/Frameworks instead. install_name_tool
# invalidates the linker signature, so callers must always re-sign after this.
for BINARY in ShifuApp shifud shifu-analyzer shifu; do
    if ! otool -l "$APP/Contents/MacOS/$BINARY" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$BINARY"
    fi
done

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    -e "s/__EDITION__/$EDITION/" \
    scripts/Info.plist.template > "$APP/Contents/Info.plist"

echo "assembled $APP (version $VERSION, build $BUILD, edition $EDITION) — unsigned"
