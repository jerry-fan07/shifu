# Shifu

Local-first macOS screen observer → productivity ledger, knowledge vault, automation radar.

- [ARCHITECTURE.md](ARCHITECTURE.md) — **start here.** Pipeline, concept→file map,
  consolidated schema, invariant→guard table, extension recipes.
- [design.md](design.md) — the spec (§-numbers are cited throughout the code).
- [implementation.md](implementation.md) — the phase plan.

## Build & test

- `make check` — build all targets + unit tests + SwiftLint + privacy invariants
  (no network symbols in shifud). Must be green before every commit.
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
| `ShifuApp` | SwiftUI desktop app + menu bar item | §7 |

## Standing invariants (violations are bugs, no exceptions)

1. **No network code in `shifud`.** Only `shifu-analyzer` may touch the network, and only to the
   configured LLM endpoint (DeepSeek, or the hosted Shifu Cloud proxy) once the user has opted in —
   their own API key, or the explicit, never-preselected Shifu Cloud choice (§8).
2. **Redaction is a single choke point** before every DB write — cards, SSNs, key/JWT shapes (§8).
3. **Exclusions are enforced before capture**, not filtered after (§8).
4. **Pixels are never persisted** — screenshots live in memory only for the OCR call (§3.2).
5. **Pause tears down observers**, it doesn't just gate writes (§8).
6. Perf budgets (§3.4) are CI: <0.5% avg CPU, <80 MB RSS for the daemon.
7. **LLM prompts are token-budgeted.** Every prompt sent through `LLMBackend.complete` must fit
   the backend's `contextWindowTokens` (DeepSeek is deliberately capped at 60k, prompt + response
   combined). Size batches with `LLMTokens.estimate`, never by item count alone.
8. Variables must be named with greater than 1 character.

## Minimalism rule

Cut anything not needed for the current phase's exit criteria (implementation.md).
Log deferred ideas in design.md §12 instead of building them.

## Parallel workspaces

Several worktrees feed this repo and share one machine-global install
(/Applications/Shifu.app, the daemon, ~/Shifu). Re-fetch and diff `origin/main` before
resuming stale work — main moves mid-session and has already landed another workspace's
version of the same change. "The app looks old" is an install-provenance question before
it is a code question (skill: `ship`); real-data checks go through a copy (skill: `dogfood`).
