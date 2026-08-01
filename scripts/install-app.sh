#!/bin/bash
# Dev install: bundle Shifu.app (via bundle-app.sh, same layout as a release)
# and drop it in /Applications. Signs with whatever codesigning identity is
# available — enough to keep TCC grants stable across rebuilds, NOT enough to
# ship: releases go through release.sh, which requires Developer ID.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -w /Applications ]; then
    APP_ROOT=/Applications
else
    APP_ROOT="$HOME/Applications"
    mkdir -p "$APP_ROOT"
fi
APP="$APP_ROOT/Shifu.app"

rm -rf "$APP"
scripts/bundle-app.sh "$APP"

# install_name_tool (in bundle-app.sh) invalidates the linker signature, and
# arm64 refuses unsigned code, so always re-sign — every nested binary, then
# the bundle. A certificate identity (vs ad-hoc) keeps TCC grants across
# rebuilds; the positional pick is fine here because any stable cert will do.
IDENTITY="${SHIFU_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/[0-9]+\)/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Frameworks/GRDB.framework"
codesign --force --sign "${IDENTITY:--}" --identifier com.shifu.shifud "$APP/Contents/MacOS/shifud"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/shifu-analyzer"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/shifu"
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "installed $APP"
echo "launch: open \"$APP\"   (desktop app + menu bar sensei)"
echo "start at login: System Settings → General → Login Items → + → Shifu.app"
