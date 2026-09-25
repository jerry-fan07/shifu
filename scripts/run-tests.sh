#!/bin/bash
# The test gate: two `swift test` invocations, plus a guard that a run which
# never finished is never mistaken for a run that passed.
#
# A plain `swift test` cannot be trusted to fail on a red suite here.
# FocusReliefTests drives a real NSWindow and pumps the main run loop on the
# main actor; when it finishes with other tests still in flight, the Swift
# runtime's async-main drain calls _swift_exit(0). The process dies mid-run,
# swift-testing never prints its closing summary and never sets its own exit
# code, and SwiftPM faithfully reports the 0 it was handed. Measured
# 2026-08-07: the run was cut off at ~886 of 914 tests every time, hiding four
# real issues behind a green `make check`.
#
# Running that suite by itself finishes before the drain, so both slices below
# report honestly. The guard is the general case: any future test that pumps
# the run loop truncates the same way, and by exit code alone a truncated run
# is indistinguishable from a clean one. The summary line is the only tell, so
# its absence is a failure. A slice that matched nothing fails too — filters
# are spelled by hand and a renamed suite would otherwise pass silently.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# The suite that has to run alone. Named twice below — once to exclude, once
# to select — and the two must stay in step, which the 0-tests check enforces.
ISOLATED='FocusReliefTests'

FAILED=0

# Runs one slice and decides whether its exit code can be believed.
# $1 is the label; everything after it is passed to `swift test`.
slice() {
    local label="$1"
    shift
    local log
    log=$(mktemp -t shifu-run-tests) || return 1
    printf '\n==> %s\n' "$label"
    swift test "$@" 2>&1 | tee "$log"
    local code=${PIPESTATUS[0]}
    local verdict=0

    if ! grep -q 'Test run started\.' "$log"; then
        printf 'run-tests: FAIL — %s never started; see the build output above.\n' \
            "$label" >&2
        rm -f "$log"
        exit 1
    fi

    if ! grep -q 'Test run with ' "$log"; then
        printf 'run-tests: FAIL — %s was truncated.\n' "$label" >&2
        printf '  swift-testing never printed its closing summary, so the exit code\n' >&2
        printf '  it gave (%s) means nothing — the process died mid-run. Something in\n' \
            "$code" >&2
        printf '  this slice pumps the main run loop; see scripts/run-tests.sh.\n' >&2
        verdict=1
    elif grep -q 'Test run with 0 tests' "$log"; then
        printf 'run-tests: FAIL — %s matched no tests.\n' "$label" >&2
        printf '  A --filter or --skip name in scripts/run-tests.sh has gone stale.\n' >&2
        verdict=1
    elif [ "$code" -ne 0 ]; then
        verdict="$code"
    fi

    rm -f "$log"
    return "$verdict"
}

slice "everything except $ISOLATED" --skip "$ISOLATED" || FAILED=1
slice "$ISOLATED, alone" --filter "$ISOLATED" || FAILED=1

if [ "$FAILED" -ne 0 ]; then
    echo "run-tests: FAIL" >&2
    exit 1
fi
echo "run-tests: PASS (both slices ran to completion)"
