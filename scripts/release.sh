#!/bin/bash
# Build a signed, notarized, stapled Shifu release: Shifu.app + Shifu-<v>.dmg
# in dist/. Requires a "Developer ID Application" identity in the keychain and
# a notarytool keychain profile (default name: shifu).
#
#   scripts/release.sh                 # full run: bundle, sign, notarize, DMG
#   scripts/release.sh --no-notarize   # local dry run, still Developer ID signed
#
# Env overrides:
#   SHIFU_VERSION         marketing version (default 0.1.0)
#   SHIFU_BUILD           CFBundleVersion (default: git commit count)
#   SHIFU_NOTARY_PROFILE  notarytool keychain profile (default: shifu)
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

VERSION="${SHIFU_VERSION:-0.1.0}"
PROFILE="${SHIFU_NOTARY_PROFILE:-shifu}"
APP="dist/Shifu.app"
DMG="dist/Shifu-$VERSION.dmg"

# Never select an identity positionally: this keychain also holds Apple
# Development certs, and a release signed with one fails notarization.
IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
    echo "ERROR: no 'Developer ID Application' identity in the keychain." >&2
    echo "Releases cannot be signed with an Apple Development certificate." >&2
    exit 1
fi
echo "signing as: $IDENTITY"

scripts/bundle-app.sh "$APP"

# Sign inside-out, hardened runtime + secure timestamp on everything. No
# entitlements: the app is not sandboxed, and Accessibility/Screen Recording
# are TCC-gated without one. Helpers are signed individually — signing the
# bundle only covers the main executable and the resource seal.
SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
"${SIGN[@]}" "$APP/Contents/Frameworks/GRDB.framework"
"${SIGN[@]}" --identifier com.shifu.shifud "$APP/Contents/MacOS/shifud"
"${SIGN[@]}" --identifier com.shifu.analyzer "$APP/Contents/MacOS/shifu-analyzer"
"${SIGN[@]}" --identifier com.shifu.cli "$APP/Contents/MacOS/shifu"
"${SIGN[@]}" "$APP"

codesign --verify --strict --verbose=2 "$APP"

if [ "$NOTARIZE" = 1 ]; then
    ditto -c -k --keepParent "$APP" dist/Shifu.zip
    xcrun notarytool submit dist/Shifu.zip --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm dist/Shifu.zip
fi

# DMG with a drag-to-Applications layout, then sign (and notarize) it too so
# Gatekeeper trusts the container as well as the app.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Shifu" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = 1 ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -vvv -t install "$APP"
    echo "release ready: $DMG (notarized + stapled)"
else
    echo "release built WITHOUT notarization: $DMG"
    echo "Gatekeeper will refuse it on other Macs — rerun without --no-notarize to ship."
fi
