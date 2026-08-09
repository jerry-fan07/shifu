# Shifu

Local-first macOS screen observer → productivity ledger, knowledge vault, automation radar.

- [ARCHITECTURE.md](ARCHITECTURE.md) — **start here.** Pipeline, concept→file map,
  consolidated schema, invariant→guard table, extension recipes.
- [design.md](design.md) — the spec (§-numbers are cited throughout the code).
- [implementation.md](implementation.md) — the phase plan.

## Build & test

- `make check` — build all targets + unit tests + SwiftLint + privacy invariants
  (no network symbols in shifud). Must be green before every commit.
- **Never trust a bare `swift test`** — one suite pumps the main run loop and kills the
  test process mid-run with status 0, so it reports green over a red suite. Go through
  `make test` (`scripts/run-tests.sh`), which splits that suite out and fails a run that
  never printed its closing summary.
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
   configured LLM endpoint (DeepSeek, the hosted Shifu Cloud proxy, or the local server) once the
   user has opted in — their own API key, or the explicit, never-preselected Shifu Cloud choice (§8).
   One narrow carve-out: in the **qwen edition**, `ShifuApp` may perform the one-time model-weights
   fetch (`ModelFetcher`), a GET of the pinned Hugging Face artifact only, after the user chooses
   the local backend — setup with a progress bar, carrying nothing about the user. No other network
   code in the app, ever.
2. **Redaction is a single choke point** before every DB write — cards, SSNs, key/JWT shapes (§8).
3. **Exclusions are enforced before capture**, not filtered after (§8).
4. **Pixels are never persisted by the capture path** — a rung-3 screenshot lives in memory for
   the OCR call and is discarded (§3.2). **Rewind is the one exception, and it is bounded**
   (§3.6): only `RewindShot` may encode a frame and only `RewindStore` may write one, only to
   `~/Shifu/rewind/`, only while the user has switched `rewind.recording` on (it defaults to
   **off**), and only through the same exclusion predicate and the same pause/lock teardown as
   every other observer. Nothing else in any target may write an image, and no frame may ever
   reach the `observations` table, the vault, or the network.
5. **Pause tears down observers**, it doesn't just gate writes (§8).
6. Perf budgets (§3.4) are CI: <0.5% avg CPU, <80 MB RSS for the daemon.
   **One knowing exception, added 2026-08-07 by request:** Rewind's default
   high-fidelity head (`rewind.hot_minutes` 5, `rewind.hot_fps` 8) costs
   **~13% of a core, measured 2026-08-08** on the current one-shot capture path
   — ~27× the budget, and 3× the 4.5% that extrapolating one warm grab
   predicted. It is
   deliberate and reversible (`rewind.hot_minutes = 0`), documented in §3.6, and
   the fix is the streaming path in §12. **Do not "correct" it as drift**, and
   do not treat it as licence for a second overrun anywhere else.
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
