# Shifu — Implementation Plan

**Date:** 2026-07-17
**Companion to:** [design.md](design.md) — section references (§) point there.
**Guiding constraint:** minimalism (§1, principle 2). Every phase ships the smallest thing that proves its milestone, and each phase ends with a dogfoodable build.

---

## 0. Repo & Toolchain Setup

**Goal:** a buildable skeleton with all three targets and CI-style checks from day one.

- [ ] Swift Package–based workspace, Xcode 16+, macOS 14 deployment target, Apple Silicon primary.
- [ ] Targets:
  - `ShifuCore` (library) — models, DB access, capture ladder logic, sessionizer, classifier, FSRS. Everything testable lives here.
  - `shifud` (executable) — capture daemon, LaunchAgent plist, no UI, **no network entitlement** (§8).
  - `shifu-analyzer` (executable) — batch worker.
  - `Shifu` (app) — SwiftUI menu bar app + dashboard.
  - `shifu` (executable) — CLI (`log`, `review`, `pause`, `status`).
- [ ] Dependencies (keep to three): **GRDB.swift** (SQLite), **SQLCipher** (deferred to Phase 6, behind a flag), FSRS (vendor a small Swift implementation, ~300 lines — write it ourselves rather than adding a dependency if nothing clean exists).
- [ ] `make check`: build all targets, unit tests, SwiftLint with a strict-but-short ruleset.
- [ ] Perf harness stub: a script that runs `shifud` against a synthetic event feed and asserts CPU/RSS budgets (§3.4) via `proc_pid_rusage`. Grows with each phase.
- [ ] `CLAUDE.md`: build/test commands (`make check`, perf harness), the standing invariants (no network code in `shifud`, redaction as the single choke point before DB writes, exclusions enforced before capture, perf budget regressions block like test failures), the minimalism rule (cut anything not needed for the phase's exit criteria; log deferred ideas in design.md §12), and pointers to the relevant design.md section per component.

**Exit:** `make check` green; all five targets build and run as no-ops.

---

## Phase 1 — Watcher (milestone M0)

**Goal:** `shifud` records an accurate, cheap trace of the day. This phase is the foundation everything else reads from; it gets the most care.

Order of work:

1. **Schema + storage.** `observations` table (§3.5), WAL mode, single write queue. Migrations from v1 (GRDB migrator).
2. **Event sources.** `NSWorkspace` app-activation notifications; AX observers on the frontmost app for window/title changes; lazy idle check via `CGEventSource.secondsSinceLastEventType`; 60 s heartbeat timer that self-suspends on idle. Debounce per §3.1.
3. **Capture ladder, rungs 1–2.** Metadata-only records; AX text extraction with the 8 KB cap. SimHash dedupe → `last_seen` updates.
4. **Capture ladder, rung 3.** `SCScreenshotManager` single-frame capture of the focused window → downscale → dHash gate → Vision OCR (`.fast`) → discard bitmap. Only reached when AX yields < a text-length floor.
5. **Exclusions (§8).** Bundle-ID and domain lists checked *before* any capture; hardcoded defaults + a `rules` table. Private-window detection for Safari/Chrome via AX attributes. Regex redaction pass (cards, SSNs, key/JWT shapes) as the single choke point before every DB write.
6. **Pause semantics.** `shifu pause 1h` / signal-based control file; tear down observers, don't just gate writes.
7. **LaunchAgent packaging** + permissions flow (Screen Recording, Accessibility) with clear failure states.
8. **CLI `shifu log`** — human-readable dump of today's observations. This is the phase's acceptance UI; no GUI yet.

**Verification:** run it for a full workday. Perf harness passes budgets; `shifu log` matches reality when spot-checked; a password manager session leaves zero content rows; kill -9 mid-write loses at most one observation (WAL).

**Risk to retire early:** AX text quality across the user's real app mix (browsers, terminal, Electron apps). Spend a day cataloging which rung each daily-driver app lands on; this data decides how much rung-3 OCR matters.

---

## Phase 2 — Ledger (milestone M1)

**Goal:** observations become honest time accounting.

1. **Sessionizer** in `ShifuCore`: fold observations → activity blocks (§4.1). Pure function over rows; property-test with synthetic days (gaps, idle, app-switch storms, sleep/wake).
2. **Rules classifier**: seed table of bundle-ID/domain → category, `*`-marked ambiguous entries; user overrides persist in `rules`.
3. **`shifu-analyzer` scaffold**: invoked by shifud hourly and on-demand; processes only new observations (high-water mark); QoS `.utility`; skips on battery unless forced.
4. **Menu bar app, first cut**: status glyph, today's totals line, Pause, Open Dashboard. Dashboard = *Time* tab only: stacked bars, day/week toggle, block drill-down. SwiftUI `Charts`, no custom styling beyond §7's rules.
5. **Retention job**: nightly delete of raw text > N days (default 14), keeping activity aggregates.

**Verification:** keep a manual diary for 2–3 days; ledger within ~10%. Reclassifying a block via UI creates a rule and re-labels history.

---

## Phase 3 — Brains (milestone M2)

**Goal:** ambiguous time gets labeled; Work Mode exists; the digest arrives.

1. **LLM abstraction** in `ShifuCore`: one protocol (`classify(block)`, `extract(block)`, `describe(pattern)`), three impls — Apple Foundation Models (if OS supports), MLX local model, Claude API (opt-in, analyzer-only). Runtime selection in settings; rules-only fallback when none available (§10). *Decide open question §13.2 here with a spike: benchmark Foundation Models vs. bundled MLX on 100 real ambiguous blocks; ship the winner, keep the loser's impl behind the protocol.*
2. **Ambiguous-block classification + topics** (§4.2, tier 2): batch prompt, JSON out, confidence-gated; low-confidence stays `unclassified` rather than guessing.
3. **Daily digest**: markdown generated at 18:00 → `digests/`, local notification linking to dashboard. Content per §4.3.
4. **Work Mode**: menu bar toggle; near-real-time rules-only classification in shifud; glow overlay window (click-through, `.screenSaver` level, 2 s breathe, ≥4 min spacing, 3 min grace). Log sessions for adherence stats.

**Verification:** spot-check 50 ambiguous blocks ≥85% agreement; glow demo feels gentle (subjective gate — iterate until it does); digest generated from a real day reads well; Work Mode with LLM backend disabled still functions.

---

## Phase 4 — Vault (milestone M3)

**Goal:** knowledge capture + spaced repetition, end to end.

1. **Extractor**: prompt over `learning`/novel `work` blocks → zero or more candidate notes; write to `vault/` as Markdown with YAML frontmatter (§5.1), inbox state.
2. **Inbox triage** in dashboard *Vault* tab: keep/edit/discard, single-keystroke. Digest lists new candidates.
3. **FSRS scheduler**: state in frontmatter; `srs_reviews` log table for later parameter fitting.
4. **Review UI**: card session from menu bar + `shifu review` CLI. Grade 1–4, arrow keys, done in <5 min.
5. **Vault dedupe (minimal)**: exact-topic + high text-similarity merge only; re-encounter bumps a `seen_count` (defers §13.4's harder version).

**Verification:** one week dogfooding: >70% keep-rate on candidates, review session actually completable daily, vault opens cleanly in Obsidian.

---

## Phase 5 — Radar (milestone M4)

**Goal:** at least one genuinely useful automation suggestion per week.

1. **Pattern miner** (§6.1): recurring (app/domain, topic) n-grams, high-frequency short visits, alternation signatures. SQL + small in-memory pass; runs weekly in analyzer.
2. **Suggestion describer** (§6.2): LLM prompt over mined patterns → structured suggestion; rank by `time_saved × confidence`.
3. **Radar tab** + digest section; Dismiss (remembered, resurface only on 2× frequency), Snooze, and "copy automation prompt" action (the v1 form of Claude Code handoff).

**Verification:** two weeks dogfooding; ≥1 suggestion/week the user rates useful; dismissed patterns stay dismissed.

---

## Phase 6 — Hardening & Ship (milestone M5)

1. **SQLCipher** at rest; key in Keychain. Optional vault encryption with the Obsidian-interop tradeoff stated in settings (§8).
2. **Onboarding flow** (§7): 4 screens, live capture preview, exclusion defaults, backend choice.
3. **Deletion tooling**: delete-everything, date-range forget, per-app purge.
4. **Failure-mode sweep** (§10): permission revocation, DB corruption rotation, disk-full, sleep/wake — each gets a test or a scripted manual check.
5. **Perf test suite finalized**: 8 h replay under budget is a release gate.
6. **Packaging**: signed + notarized DMG, `defaults`-style config export, README.

**Exit:** clean machine → install → permissions → 24 h later a useful digest with zero configuration.

---

## Cross-Cutting Practices

- **Dogfood from Phase 1.** Shifu develops Shifu; every phase's verification is primarily "did it work on the author's real day."
- **Subagent delegation, correctness-gated.** Claude Code may delegate work to Opus/Sonnet subagents as it sees fit — parallel exploration, well-scoped implementation tasks (e.g., the FSRS port, dHash/SimHash utilities, synthetic-feed generators), and independent code review are good fits. Two rules keep quality intact: (1) subagent output is never merged unverified — the main session reviews the diff, runs `make check` and the relevant phase verification before accepting it; (2) core capture-path and privacy-invariant code (capture ladder, redaction, exclusions, pause semantics) is either written in the main session or given a dedicated review pass against design.md §3/§8 after delegation. Bug-freeness outranks delegation speed.
- **Perf budget is CI.** The synthetic-feed harness runs on every merge; a budget regression blocks like a test failure.
- **Minimalism check per phase.** Before starting each phase, re-read its design section and cut anything not needed for the exit criteria; log deferred ideas in design.md §12 instead of building them.
- **Privacy invariants as tests**: excluded app ⇒ no content rows; redaction patterns ⇒ never on disk; `shifud` binary ⇒ no network symbols (checked by a script against the linked frameworks).

## Sequencing & Effort (rough)

| Phase | Depends on | Rough size |
|---|---|---|
| 0 Setup | — | 1–2 days |
| 1 Watcher | 0 | 1.5–2 weeks (the hard one) |
| 2 Ledger | 1 | 1 week |
| 3 Brains | 2 | 1.5 weeks (incl. model spike) |
| 4 Vault | 3 | 1 week |
| 5 Radar | 2 (miner) / 3 (describer) | 1 week |
| 6 Hardening | all | 1–1.5 weeks |

Phases 4 and 5 are independent of each other and can swap order if vault dogfooding data is more valuable early.
