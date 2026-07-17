# Shifu build/check entry points. `make check` is the gate for every change.

.PHONY: build test lint check perf clean

build:
	swift build

test:
	swift test

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint --strict --quiet; \
	else \
		echo "swiftlint not installed; skipping lint (brew install swiftlint)"; \
	fi

check: build test lint

# Perf harness: runs shifud against a synthetic event feed and asserts
# CPU/RSS budgets (design.md §3.4). Grows with each phase.
perf:
	./scripts/perf-harness.sh

clean:
	swift package clean
