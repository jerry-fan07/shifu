#!/bin/bash
# Perf harness (implementation.md §0): run shifud's synthetic event feed
# through the real write path and assert design.md §3.4 budgets.
set -euo pipefail

RSS_BUDGET_MB=80
FEED_COUNT=5000
# Budget: a full workday is <2000 real triggers; 5000 in a few seconds is
# generous headroom. Fail if it takes longer than this many seconds.
TIME_BUDGET_S=10

# Budgets are measured on the release build — that's what ships.
cd "$(dirname "$0")/.."
swift build -c release --product shifud >/dev/null
BIN="$(swift build -c release --show-bin-path)/shifud"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

START=$(date +%s)
OUTPUT=$(SHIFU_HOME="$SCRATCH" "$BIN" --synthetic-feed "$FEED_COUNT")
ELAPSED=$(( $(date +%s) - START ))
echo "$OUTPUT"

RSS_MB=$(echo "$OUTPUT" | sed -n 's/.*peak RSS \([0-9.]*\) MB.*/\1/p' | cut -d. -f1)

if [ -z "$RSS_MB" ]; then
    echo "perf-harness: FAIL — could not parse RSS from output"
    exit 1
fi
if [ "$RSS_MB" -ge "$RSS_BUDGET_MB" ]; then
    echo "perf-harness: FAIL — peak RSS ${RSS_MB} MB over ${RSS_BUDGET_MB} MB budget"
    exit 1
fi
if [ "$ELAPSED" -gt "$TIME_BUDGET_S" ]; then
    echo "perf-harness: FAIL — ${ELAPSED}s over ${TIME_BUDGET_S}s budget for ${FEED_COUNT} triggers"
    exit 1
fi
echo "perf-harness: PASS (RSS ${RSS_MB} MB < ${RSS_BUDGET_MB} MB, ${ELAPSED}s ≤ ${TIME_BUDGET_S}s)"
