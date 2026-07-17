# Shifu

Local-first macOS screen observer → productivity ledger, knowledge vault, automation radar.
Read [design.md](design.md) for the spec and [implementation.md](implementation.md) for the phase plan.

## Build & test

- `make check` — build all targets + unit tests + SwiftLint. Must be green before every commit.
- `make perf` — perf harness: shifud against a synthetic feed, asserts design.md §3.4 budgets.
  **A perf budget regression blocks like a test failure.**
- Swift Package workspace; macOS 14+ deployment target, Apple Silicon primary.

## Targets

| Target | Role | Design ref |
|---|---|---|
| `ShifuCore` | models, DB, capture-ladder logic, sessionizer, classifier, FSRS — all testable logic | §2 |
| `shifud` | capture daemon (LaunchAgent, headless) | §3 |
| `shifu-analyzer` | batch analysis worker | §4–6 |
| `shifu-cli` (product `shifu`) | CLI: log, review, pause, status | §5, §11 |
| `ShifuApp` | SwiftUI menu bar app + dashboard | §7 |

## Standing invariants (violations are bugs, no exceptions)

1. **No network code in `shifud`.** Only `shifu-analyzer` may touch the network, and only when
   cloud analysis is opted in (§8).
2. **Redaction is a single choke point** before every DB write — cards, SSNs, key/JWT shapes (§8).
3. **Exclusions are enforced before capture**, not filtered after (§8).
4. **Pixels are never persisted** — screenshots live in memory only for the OCR call (§3.2).
5. **Pause tears down observers**, it doesn't just gate writes (§8).
6. Perf budgets (§3.4) are CI: <0.5% avg CPU, <80 MB RSS for the daemon.

## Minimalism rule

Cut anything not needed for the current phase's exit criteria (implementation.md).
Log deferred ideas in design.md §12 instead of building them.
