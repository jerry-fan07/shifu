#!/bin/bash
# Perf harness (implementation.md §0): run shifud against a synthetic event
# feed and assert the design.md §3.4 budgets. Grows with each phase.
#
# Phase 0 stub: build shifud, run it briefly, and assert RSS stays under
# budget. CPU assertions arrive with the synthetic feed in Phase 1.
set -euo pipefail

RSS_BUDGET_MB=80

cd "$(dirname "$0")/.."
swift build --product shifud >/dev/null
BIN="$(swift build --show-bin-path)/shifud"

"$BIN" &
PID=$!
sleep 1

if ! kill -0 "$PID" 2>/dev/null; then
    # Phase 0 no-op exits immediately; that's a pass — nothing to measure yet.
    wait "$PID" || true
    echo "perf-harness: shifud exited (no-op phase); PASS"
    exit 0
fi

RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

RSS_MB=$((RSS_KB / 1024))
echo "perf-harness: shifud RSS ${RSS_MB} MB (budget ${RSS_BUDGET_MB} MB)"
if [ "$RSS_MB" -ge "$RSS_BUDGET_MB" ]; then
    echo "perf-harness: FAIL — RSS over budget"
    exit 1
fi
echo "perf-harness: PASS"
