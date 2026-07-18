#!/bin/bash
# Convert a source image (PNG or JPG) into a standard macOS .icns file.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path-to-source-image>"
    exit 1
fi

SRC_IMAGE="$1"
TARGET_DIR="Sources/ShifuApp"
ICONSET_DIR="${TARGET_DIR}/AppIcon.iconset"
ICNS_FILE="${TARGET_DIR}/AppIcon.icns"

echo "Creating iconset directory..."
mkdir -p "$ICONSET_DIR"

echo "Generating PNG sizes with sips..."
sips -s format png -z 16 16   "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_16x16.png" > /dev/null
sips -s format png -z 32 32   "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_16x16@2x.png" > /dev/null
sips -s format png -z 32 32   "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_32x32.png" > /dev/null
sips -s format png -z 64 64   "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_32x32@2x.png" > /dev/null
sips -s format png -z 128 128 "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_128x128.png" > /dev/null
sips -s format png -z 256 256 "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_128x128@2x.png" > /dev/null
sips -s format png -z 256 256 "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_256x256.png" > /dev/null
sips -s format png -z 512 512 "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_256x256@2x.png" > /dev/null
sips -s format png -z 512 512 "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_512x512.png" > /dev/null
sips -s format png -z 1024 1024 "$SRC_IMAGE" --out "${ICONSET_DIR}/icon_512x512@2x.png" > /dev/null

echo "Compiling .icns file with iconutil..."
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"

echo "Cleaning up temporary iconset directory..."
rm -rf "$ICONSET_DIR"

echo "Successfully generated: $ICNS_FILE"
