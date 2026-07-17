#!/bin/bash
# Privacy invariant (CLAUDE.md #1, design.md §8): shifud must contain no
# network code. Enforced by symbol inspection so it's auditable — only
# shifu-analyzer may reference URL-loading machinery.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --product shifud >/dev/null
BIN="$(swift build --show-bin-path)/shifud"

FORBIDDEN='NSURLSession|NSURLConnection|CFHTTPMessage|nw_connection_create|CFSocketCreate'
if HITS=$(nm -u "$BIN" 2>/dev/null | grep -E "$FORBIDDEN"); then
    echo "check-no-network: FAIL — shifud references network symbols:"
    echo "$HITS"
    exit 1
fi
echo "check-no-network: PASS (no network symbols in shifud)"
