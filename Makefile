# Shifu build/check entry points. `make check` is the gate for every change.

.PHONY: build test lint check perf clean

build:
	swift build

# Not a bare `swift test`: one suite pumps the main run loop and kills the test
# process mid-run with status 0, so a plain run reports green over a red suite.
# The script splits that suite out and fails on a run that never finished.
test:
	./scripts/run-tests.sh

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint --strict --quiet; \
	else \
		echo "swiftlint not installed; skipping lint (brew install swiftlint)"; \
	fi

check: build test lint invariants

# Privacy invariants enforced as CI (CLAUDE.md): no network symbols in shifud.
invariants:
	./scripts/check-no-network.sh

# Perf harness: runs shifud against a synthetic event feed and asserts
# CPU/RSS budgets (design.md §3.4), plus vault index/search budgets
# (vault-features.md §V8). Grows with each phase.
perf:
	./scripts/perf-harness.sh
	./scripts/perf-vault.sh

clean:
	swift package clean
