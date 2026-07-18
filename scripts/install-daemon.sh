#!/bin/bash
# Install (or --uninstall) shifud as a LaunchAgent (implementation.md Phase 1 item 7).
# Builds release, copies the binary to ~/Shifu/bin, and bootstraps the agent.
set -euo pipefail

LABEL="com.shifu.shifud"
SHIFU_HOME="${SHIFU_HOME:-$HOME/Shifu}"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    echo "uninstalled $LABEL (data in $SHIFU_HOME left intact)"
    exit 0
fi

cd "$(dirname "$0")/.."
swift build -c release --product shifud
swift build -c release --product shifu-analyzer
swift build -c release --product shifu
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$SHIFU_HOME/bin" "$SHIFU_HOME/logs"
# shifud spawns shifu-analyzer from its own directory; keep them together.
cp "$BIN_DIR/shifud" "$BIN_DIR/shifu-analyzer" "$BIN_DIR/shifu" "$SHIFU_HOME/bin/"
# GRDB (with SQLCipher) is a dynamic framework resolved via @loader_path —
# it must sit next to the binaries.
rm -rf "$SHIFU_HOME/bin/GRDB.framework"
cp -R "$BIN_DIR/GRDB.framework" "$SHIFU_HOME/bin/"

# TCC keys Accessibility/Screen Recording grants to the code signature. The default
# linker ad-hoc signature changes every build, orphaning the grants on each reinstall;
# a certificate-based signature keeps them valid across rebuilds.
IDENTITY="${SHIFU_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/[0-9]+\)/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$SHIFU_HOME/bin/GRDB.framework"
    codesign --force --sign "$IDENTITY" --identifier com.shifu.shifud "$SHIFU_HOME/bin/shifud"
    codesign --force --sign "$IDENTITY" "$SHIFU_HOME/bin/shifu-analyzer" "$SHIFU_HOME/bin/shifu"
else
    echo "WARNING: no codesigning identity found — TCC grants will break on every rebuild"
fi

mkdir -p "$(dirname "$AGENT_PLIST")"
sed -e "s|__BIN__|$SHIFU_HOME/bin/shifud|" -e "s|__HOME__|$SHIFU_HOME|" \
    scripts/$LABEL.plist.template > "$AGENT_PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"

echo "installed and started $LABEL"
echo "grant permissions in System Settings → Privacy & Security:"
echo "  • Accessibility → $SHIFU_HOME/bin/shifud   (window titles + text)"
echo "  • Screen Recording → $SHIFU_HOME/bin/shifud (OCR fallback rung)"
echo "logs: $SHIFU_HOME/logs/shifud.log"
