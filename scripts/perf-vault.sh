#!/bin/bash
# Vault search perf case (vault-features.md §V8): 10k synthetic notes,
# no-change reconcile and single-query latency must stay under budget.
set -euo pipefail

NOTE_COUNT=10000
SEARCH_BUDGET_MS=50
# Reconcile with nothing changed is O(files) stat + one index read; it runs
# on every analyzer pass, so it must stay cheap.
RECONCILE_BUDGET_MS=1000

# Budgets are measured on the release build — that's what ships.
cd "$(dirname "$0")/.."
swift build -c release --product shifu >/dev/null
BIN="$(swift build -c release --show-bin-path)/shifu"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

OUTPUT=$(SHIFU_HOME="$SCRATCH" "$BIN" vault bench "$NOTE_COUNT")
echo "$OUTPUT"

RECONCILE_MS=$(echo "$OUTPUT" | sed -n 's/.*reconcile \([0-9]*\) ms.*/\1/p')
SEARCH_MS=$(echo "$OUTPUT" | sed -n 's/.*search \([0-9.]*\) ms.*/\1/p' | cut -d. -f1)
HITS=$(echo "$OUTPUT" | sed -n 's/.*(\([0-9]*\) hits).*/\1/p')

if [ -z "$RECONCILE_MS" ] || [ -z "$SEARCH_MS" ] || [ -z "$HITS" ]; then
    echo "perf-vault: FAIL — could not parse bench output"
    exit 1
fi
if [ "$HITS" -eq 0 ]; then
    echo "perf-vault: FAIL — search returned no hits; the index is broken"
    exit 1
fi
if [ "$SEARCH_MS" -ge "$SEARCH_BUDGET_MS" ]; then
    echo "perf-vault: FAIL — search ${SEARCH_MS} ms over ${SEARCH_BUDGET_MS} ms budget"
    exit 1
fi
if [ "$RECONCILE_MS" -ge "$RECONCILE_BUDGET_MS" ]; then
    echo "perf-vault: FAIL — reconcile ${RECONCILE_MS} ms over ${RECONCILE_BUDGET_MS} ms budget"
    exit 1
fi
echo "perf-vault: PASS (search ${SEARCH_MS} ms < ${SEARCH_BUDGET_MS} ms, reconcile ${RECONCILE_MS} ms < ${RECONCILE_BUDGET_MS} ms, ${HITS} hits)"
