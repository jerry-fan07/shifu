#!/bin/bash
# Assemble a self-contained, UNSIGNED Shifu.app at $1 (default: dist/Shifu.app).
# All four executables ship in Contents/MacOS so they resolve each other as
# siblings (ShifuPaths.helper); GRDB rides in Contents/Frameworks via one rpath
# rule. Shared by install-app.sh (dev signing) and release.sh (Developer ID +
# notarization) so bundle layout is defined exactly once.
#
# Env: SHIFU_VERSION (default: the version in ShifuCore), SHIFU_BUILD (default:
# git commit count), SHIFU_EDITION (standard | qwen, default standard — which
# backend choices the bundle offers; see Edition in ShifuCore),
# SHIFU_LLAMA_TAG (qwen edition: the llama.cpp release tag to build the
# bundled llama-server from).
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

# The qwen edition carries its own model server (design.md §4.2): llama-server,
# built from a pinned llama.cpp release — never a prebuilt download, so the
# binary we sign is the source we read. Cached by tag under .build; a tag bump
# rebuilds, a rerun on the same tag costs a cmake no-op. Built static
# (BUILD_SHARED_LIBS=OFF) with the Metal shader embedded, so the one
# executable is the whole server and rides Contents/MacOS like the helpers.
LLAMA_SERVER=""
if [ "$EDITION" = "qwen" ]; then
    command -v cmake >/dev/null || {
        echo "ERROR: the qwen edition builds llama-server from source and needs" >&2
        echo "cmake (brew install cmake)." >&2
        exit 1
    }
    # b10200 = commit 5f55650a7, the build the 2026-07-31 spike measured
    # (the homebrew llama-server that served every §12 number reports
    # "version: 10200 (5f55650a7)") — so the bundled server is the measured
    # one until a tag bump re-measures.
    LLAMA_TAG="${SHIFU_LLAMA_TAG:-b10200}"
    LLAMA_SRC=".build/llama.cpp-$LLAMA_TAG"
    if [ ! -d "$LLAMA_SRC" ]; then
        git clone --depth 1 --branch "$LLAMA_TAG" \
            https://github.com/ggml-org/llama.cpp "$LLAMA_SRC"
    fi
    cmake -S "$LLAMA_SRC" -B "$LLAMA_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_CURL=OFF
    cmake --build "$LLAMA_SRC/build" --target llama-server -j "$(sysctl -n hw.ncpu)"
    LLAMA_SERVER="$LLAMA_SRC/build/bin/llama-server"
    [ -x "$LLAMA_SERVER" ] || {
        echo "ERROR: llama.cpp $LLAMA_TAG built no llama-server at $LLAMA_SERVER" >&2
        exit 1
    }
fi

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
if [ -n "$LLAMA_SERVER" ]; then
    cp "$LLAMA_SERVER" "$APP/Contents/MacOS/llama-server"
fi
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
