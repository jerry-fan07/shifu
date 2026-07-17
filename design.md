# Shifu — Design Specification

> *Shifu watches you work.*

**Date:** 2026-07-17
**Status:** Draft v1 (expanded from [instructions.md](instructions.md))
**Target platform:** macOS 14+ (Apple Silicon first)

---

## 1. Product Overview

Shifu is a local-first, always-on observer that captures what is on your screen with near-zero perceptible overhead, then turns those observations into three outputs:

1. **Productivity ledger** — an accurate, automatic accounting of where your time went (work, entertainment, socializing/networking, learning, admin, idle).
2. **Knowledge vault** — new information you encountered, distilled into reviewable notes and surfaced on a spaced-repetition schedule.
3. **Efficiency radar** — detection of repetitive or manual workflows that could be automated or delegated to AI, with concrete suggestions.

### Design principles (in priority order)

1. **Invisible.** The user should never feel Shifu running. No fan spin, no dropped frames, no battery anxiety. Capture must be event-driven, never polling-heavy.
2. **Minimalist.** In every dimension: a UI with the fewest possible surfaces (one menu bar item, one window, one review card), features that earn their place or don't ship, plain formats over clever ones (Markdown, SQLite), and a codebase small enough to audit. When in doubt, leave it out — every addition must justify itself against this principle.
3. **Private by default.** All raw captures stay on-device. Nothing leaves the machine unless the user explicitly opts into cloud analysis, and even then only derived text/summaries are sent — never raw pixels.
4. **Trustworthy.** The user can inspect, export, and delete everything. Sensitive apps and sites are excluded by default. There is a single obvious kill switch.
5. **Useful without babysitting.** Insights arrive as a daily digest and an on-demand dashboard, not a stream of notifications.

### Non-goals (v1)

- Windows/Linux support (architecture should not preclude it; see §12).
- Multi-device sync.
- Keystroke logging or input capture of any kind.
- Employer/surveillance use cases. Shifu is a personal tool; no remote reporting features will be built.

---

## 2. Platform, Language, and High-Level Architecture (§0 of instructions)

### 2.1 Language choices

| Component | Language | Rationale |
|---|---|---|
| Capture daemon | **Swift** | The only first-class way to use ScreenCaptureKit, Accessibility (AX) APIs, NSWorkspace events, and the Vision OCR framework. These native APIs are what make near-zero-overhead capture possible; Rust would have to bridge into them anyway, adding complexity without saving resources. |
| Analysis engine | **Swift** (same process family), with classification prompts to a local or remote LLM | Keeps the stack single-language; analysis is I/O- and model-bound, not CPU-bound, so a "faster language" buys nothing. |
| Storage | **SQLite** (via GRDB.swift) + plain Markdown files | SQLite for events/metrics (queryable, compact, battle-tested). Markdown for knowledge notes so the vault is readable and portable without Shifu. |
| UI (menu bar + dashboard + review) | **SwiftUI** | Native look, trivial menu-bar apps, low memory. |

**Why not Rust?** The instructions float Rust as a resource-minimization strategy. The insight is right (avoid heavy runtimes) but the conclusion is wrong for macOS: the expensive operations — screen capture, OCR, window metadata — are all done by system frameworks running in Apple's own processes. The efficiency win comes from *capturing less and capturing smarter* (event-driven triggers, text-only extraction, on-device OCR on the Neural Engine), not from the host language. Swift compiles to native code with no GC pauses and gives direct access to every API we need. Rust remains a reasonable choice for a future cross-platform core (§12).

### 2.2 Process architecture

Three cooperating pieces, deliberately decoupled so the capture path stays tiny:

```
┌─────────────────────────────────────────────────────────────┐
│  shifud (capture daemon, LaunchAgent, headless)             │
│  • listens for focus/window/URL-change events               │
│  • captures text (AX tree) or screenshot→OCR on trigger     │
│  • writes raw observations to SQLite (WAL mode)             │
│  • target: <0.5% avg CPU, <80 MB RSS                        │
└────────────────────────┬────────────────────────────────────┘
                         │ SQLite (single local DB, WAL)
┌────────────────────────┴────────────────────────────────────┐
│  shifu-analyzer (scheduled worker)                          │
│  • runs opportunistically: on AC power / idle / hourly      │
│  • sessionizes observations → activities                    │
│  • classifies activities (rules first, LLM for ambiguous)   │
│  • extracts knowledge candidates → Markdown vault           │
│  • detects repetition patterns → automation suggestions     │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────┴────────────────────────────────────┐
│  Shifu.app (menu bar UI)                                    │
│  • status, pause/kill switch, work-mode toggle              │
│  • dashboard (time breakdown, trends)                       │
│  • review mode (spaced repetition over the vault)           │
│  • settings: exclusions, categories, analysis backend       │
└─────────────────────────────────────────────────────────────┘
```

- **shifud** is a `LaunchAgent` so it survives logouts of the UI app and starts at login. It holds the Screen Recording and Accessibility permissions.
- **shifu-analyzer** is spawned by shifud on a schedule (or by the UI on demand). Keeping it out of the daemon means analysis spikes can never make the capture path feel heavy, and the OS can deprioritize it (`QoS: .utility`, scheduled via `BGProcessingTask`-style constraints: prefer AC power + user idle).
- **Shifu.app** owns nothing critical; quitting it changes nothing about capture.

### 2.3 Data flow summary

```
screen event ──► observation (text + metadata) ──► SQLite
SQLite ──► sessionizer ──► activity blocks ──► classifier ──► ledger
activity text ──► knowledge extractor ──► note candidates ──► vault (.md) ──► SRS queue
activity sequences ──► pattern miner ──► automation suggestions ──► digest
```

---

## 3. Capture Design — Minimal Resource Use (§1 of instructions)

The core trick: **never poll pixels; react to events, and prefer text over images.**

### 3.1 Trigger events (when we look)

Subscribed via cheap system notification APIs — all of these cost ~nothing while idle:

| Event | Source | Debounce |
|---|---|---|
| App activation / frontmost change | `NSWorkspace.didActivateApplicationNotification` | immediate |
| Window focus/title change | AX observer (`kAXFocusedWindowChanged`, `kAXTitleChanged`) | 500 ms |
| Browser URL change | AX title/URL observation on browser windows (no extension needed for v1) | 1 s |
| Content settled after interaction | user-input quiet period (2 s after last HID activity, via `CGEventSource.secondsSinceLastEventType` checked lazily) | — |
| Heartbeat | timer, only if none of the above fired | every 60 s while non-idle |
| Idle detection | no HID input for 5 min → suspend all capture | — |

There is **no fixed screenshot interval**. A user reading one page for 10 minutes generates one capture, not 600.

### 3.2 Capture ladder (what we grab, cheapest first)

For each trigger, Shifu walks down this ladder and stops at the first rung that yields enough signal:

1. **Metadata only** (~free): app bundle ID, window title, browser URL, timestamp. For a large fraction of triggers (app switches within known apps) this is sufficient — no content capture at all.
2. **Accessibility text extraction** (cheap): read visible text from the focused window's AX tree (`AXStaticText`, `AXTextArea` values, capped at ~8 KB). Works for most native apps and browsers; costs microseconds-to-milliseconds and zero GPU.
3. **Screenshot → on-device OCR** (fallback): only when the AX tree is empty/blocked (games, Electron apps with poor AX, video conferencing, images/PDF viewers). Single-window capture via **ScreenCaptureKit** (`SCScreenshotManager`, one frame — not a stream), downscaled to ≤1280 px wide, fed to **Vision `VNRecognizeTextRequest`** (runs on the Neural Engine/GPU, `fast` recognition level). The bitmap is discarded immediately after OCR; **pixels are never persisted** in the default configuration.
4. **Skip**: if the frontmost app is on the exclusion list (§8), record only `app: excluded, duration` and capture nothing.

### 3.3 Deduplication and change detection

- Before OCR, compare a **perceptual hash** (dHash, 8×8) of the downscaled frame against the last capture for that window; if distance < threshold, drop it.
- After text extraction, compare a **SimHash of the text** to the previous observation for the same window; near-duplicates update the existing observation's `last_seen` instead of inserting a new row.
- Net effect: stable screens cost one row regardless of duration.

### 3.4 Resource budget (hard targets, enforced in CI-style perf tests)

| Metric | Target | Notes |
|---|---|---|
| Avg CPU (daemon, active use) | < 0.5% of one core | measured over 8 h workday |
| CPU during a capture burst | < 20% for < 300 ms | OCR on Neural Engine keeps CPU low |
| Memory (daemon RSS) | < 80 MB steady | no frame buffers retained |
| Disk write rate | < 5 MB/hour typical | text-only observations |
| Battery impact | not attributable in macOS Battery UI | QoS `.utility` for everything off the event path |
| Analyzer | runs only on AC or user-idle by default | user-configurable |

### 3.5 Observation record

```sql
CREATE TABLE observations (
  id            INTEGER PRIMARY KEY,
  started_at    INTEGER NOT NULL,     -- unix ms
  last_seen     INTEGER NOT NULL,
  app_bundle    TEXT NOT NULL,
  window_title  TEXT,
  url           TEXT,
  capture_kind  TEXT NOT NULL,        -- meta | ax | ocr | excluded
  text          TEXT,                 -- extracted content, capped
  text_simhash  INTEGER,
  session_id    INTEGER               -- filled in by analyzer
);
```

Raw text is retained for a configurable window (default **14 days**), after which only derived artifacts (ledger entries, notes, suggestions) survive. This bounds disk use and privacy exposure simultaneously.

---

## 4. Analysis Pipeline (§2 of instructions)

Runs in `shifu-analyzer`, batch-style. Three stages share one pass over new observations.

### 4.1 Sessionization

Contiguous observations are folded into **activity blocks**: same app/domain, gaps < 2 min, split on idle. An 8-hour day typically reduces to 40–120 blocks. Blocks carry: time range, app, titles/URLs seen, concatenated representative text (sampled, capped).

### 4.2 Classification (tiered, cheap-first)

1. **Rules layer** (instant, covers ~80%): a user-editable mapping of bundle IDs and URL domains → categories. Ships with sensible defaults (`Xcode → work`, `youtube.com → entertainment*`, `mail → admin`, …). `*` marks *ambiguous* defaults that always escalate.
2. **Local LLM layer**: ambiguous blocks (unknown apps, mixed-content sites like YouTube/Twitter/Reddit) are classified from their text sample by a small on-device model (Apple Foundation Models framework where available, or a bundled ~3B quantized model via MLX). Prompt returns `{category, confidence, topic}`.
3. **Cloud layer (opt-in)**: users may point classification and summarization at the Claude API for better topic labeling. Only text samples are sent, post-exclusion-filtering, and this is off by default.

Categories (v1, user-extensible): `work`, `learning`, `entertainment`, `social`, `communication`, `admin`, `idle`. Every block also gets a free-text `topic` ("debugging shifu capture daemon", "watching F1 highlights") used by the knowledge and automation stages.

### 4.3 Outputs

- **Ledger**: per-block rows in `activities`; rollups by day/week/category/topic power the dashboard.
- **Daily digest** (generated at a configurable time, default 18:00): time breakdown, top topics, streaks/anomalies ("2.1 h on social, 3× your average"), new notes captured, new automation suggestions. Delivered as a local notification linking into the dashboard.

### 4.4 Work Mode

A user-invoked focus contract, toggled from the menu bar (and optionally auto-scheduled, e.g. weekdays 9–12).

- While active, the daemon classifies the *current* block in near-real-time using the rules layer only (no LLM on the hot path). Unknown → treated as neutral, never nagged.
- If the current block has been non-`work`/non-`learning` for a grace period (default 3 min), Shifu shows the **glow pulse**: a full-screen, click-through overlay window (`NSWindow` at `.screenSaver` level, `ignoresMouseEvents = true`) that breathes a soft colored vignette at the screen edges for ~2 s, then fades. Repeats at most every 4 min while off-task. No sound, no modal, no text — a nudge, not a scold.
- Escalation is configurable: off → glow → glow + haptic (on supported trackpads) → gentle notification. Default is glow only.
- Work Mode sessions are themselves logged, so the dashboard can report "focus session adherence."

---

## 5. Knowledge Vault & Spaced Repetition (§2 of instructions)

### 5.1 Extraction

During analysis, blocks tagged `learning` (and `work` blocks with high novel-content signal) are scanned for **knowledge candidates**: definitions, facts, how-tos, error→fix pairs, shortcuts, names/terms the user hasn't seen before. The extractor LLM prompt produces zero or more candidate notes per block:

```yaml
# ~/Shifu/vault/2026/07/17-scrncapturekit-single-frame.md
---
id: 01J2X…            # ULID
captured: 2026-07-17T14:32:00-07:00
source_app: Safari
source_url: https://developer.apple.com/documentation/screencapturekit
topic: macOS screen capture
confidence: 0.86
srs: {ease: 2.5, interval_days: 0, due: 2026-07-18, reps: 0}
---
**ScreenCaptureKit can take one-off screenshots** via `SCScreenshotManager`
without opening a stream — much cheaper than `SCStream` for infrequent captures.

Q: What SCK API takes a single screenshot without a stream?
A: `SCScreenshotManager` (macOS 14+).
```

- The vault is **plain Markdown in a plain folder** (`~/Shifu/vault/`), one note per fact, YAML frontmatter for metadata. Fully usable with Obsidian/any editor; Shifu is not a lock-in layer.
- Every note carries an optional Q/A pair for review; notes without a good Q/A are kept as reference notes and excluded from the SRS queue.
- New candidates land in an **inbox state**; the daily digest shows them and the user can keep/edit/discard in one keystroke each. Nothing enters the review queue unconfirmed (prevents SRS pollution from bad extractions).

### 5.2 Review (spaced repetition)

- Scheduler: **FSRS** (modern, better-calibrated than SM-2; a Swift implementation is small). SRS state lives in the note's frontmatter so the folder stays self-contained.
- Review UI: a minimal SwiftUI card session launched from the menu bar ("Review · 7 due"), plus a `shifu review` CLI for terminal users. Grade with 1–4 / arrow keys.
- Target session length: < 5 minutes/day. The digest nags gently if the due queue exceeds a threshold.

---

## 6. Efficiency & Automation Radar (§2 of instructions)

Two complementary detectors run over the ledger:

### 6.1 Pattern miner (deterministic)

Looks for structural repetition in activity sequences:

- **Recurring n-grams** of (app/domain, topic) transitions — e.g. `Gmail → Sheets → Gmail` every weekday morning suggests a report-forwarding ritual.
- **High-frequency short visits** — 30 visits/day to the same dashboard suggests an alerting gap.
- **Manual transfer signatures** — rapid alternation between two apps with copy-adjacent dwell times.

Cheap to compute (SQL + a small suffix-array pass), runs entirely locally.

### 6.2 Opportunity describer (LLM)

Mined patterns (plus sampled text context) go to the LLM with a prompt that asks: *is this automatable, and how?* Output is a structured suggestion:

```
title:      "Morning metrics ritual (~22 min/week)"
evidence:   pattern seen 9× in 14 days, avg 4.4 min
suggestion: "This looks like manual copying of ad metrics into a sheet.
             A scheduled script or a Claude Code task could pull the API
             data directly. Estimated setup: <1 h."
actions:    [Draft the automation with Claude Code] [Dismiss] [Snooze 30d]
```

- Suggestions appear in the digest and a dashboard tab, ranked by `estimated_time_saved × confidence`.
- Dismissals are remembered; a dismissed pattern never resurfaces unless its frequency doubles.
- "Draft it" deep-links into the user's tool of choice (v1: copies a well-formed prompt describing the workflow; later: direct Claude Code session handoff).

---

## 7. User Interface

Minimalism governs the UI (§1, principle 2): monochrome menu bar glyph, generous whitespace, system fonts and colors, no badges or gamification, no settings page longer than one screen. Three surfaces total:

- **Menu bar item** (the only always-visible surface): status glyph (watching / paused / excluded app), Work Mode toggle, "Review · N due", "Today: 4.2 h work · 1.1 h learning", Pause 1h / until tomorrow, Open Dashboard, Quit & Stop Capture.
- **Dashboard window**: three tabs — *Time* (stacked day/week bars, topic drill-down), *Vault* (inbox triage + browse), *Radar* (suggestions). Charts native SwiftUI; no web views.
- **Review session**: minimal card interface (see §5.2).
- **Onboarding**: a 4-screen flow that (1) explains exactly what is and isn't captured, (2) requests Screen Recording + Accessibility permissions with live previews of what Shifu sees, (3) sets exclusions (pre-checked: password managers, banking category, private browsing), (4) picks analysis backend (local-only default).

---

## 8. Privacy & Security

This section is load-bearing; a screen watcher lives or dies on trust.

- **Local-first, forever.** Raw observations never leave the device. Cloud LLM use is opt-in, text-only, post-filtering, and clearly labeled in settings.
- **No pixel persistence.** Screenshots exist in memory only for the OCR call in the default configuration. (A debug flag can retain them, visibly indicated in the menu bar.)
- **Exclusion list**, enforced in the daemon *before* capture (not filtered after):
  - Default-excluded apps: password managers, Keychain, system auth dialogs.
  - Default-excluded domains: banking/financial category list, health portals; user-editable.
  - Private/incognito browser windows: always excluded, not configurable off.
  - Regex redaction pass over all extracted text for credit-card numbers, SSNs, and obvious secrets (`AKIA…`, `-----BEGIN`, JWT shapes) before anything touches disk.
- **Encryption at rest**: SQLite via SQLCipher; vault folder optionally encrypted (off by default since users may want Obsidian interop — the tradeoff is stated plainly in settings).
- **Retention**: raw text 14 days (configurable 1–90); ledger aggregates and confirmed notes indefinitely; one-click "delete everything," and a date-range delete ("forget this afternoon").
- **Pause semantics**: pause = the AX observers and event taps are torn down, not just ignored. The menu bar glyph makes state unambiguous.
- **No network access in shifud at all** — only the analyzer can touch the network, and only when cloud analysis is enabled. Enforced via separate binaries so this is auditable.

---

## 9. Storage Layout

```
~/Shifu/
  shifu.db            # SQLite: observations, activities, patterns, suggestions, settings
  vault/              # Markdown knowledge notes (portable)
    YYYY/MM/*.md
  digests/            # daily digest archives (markdown)
  logs/               # daemon logs, size-capped
```

Key tables: `observations` (§3.5), `activities` (block, category, topic, confidence), `rules` (user classification overrides), `suggestions`, `srs_reviews` (review log for FSRS optimization).

---

## 10. Failure Modes & Edge Cases

| Case | Behavior |
|---|---|
| Screen Recording permission revoked | Daemon degrades to metadata+AX-only, menu bar shows warning state |
| AX blocked for an app (some Electron/games) | Fall to OCR rung; if excluded from capture too, metadata only |
| Multiple displays | Capture focused window's display only; other displays only via focus changes |
| Fullscreen video / presentations | Heartbeat captures suppressed when a single frame persists (pHash stable) — one observation for the whole movie |
| Fast app-switch storms | Debounce collapses to final foreground app; intermediate switches recorded as metadata only |
| DB corruption / disk full | WAL + daily integrity check; on failure, rotate DB aside and start fresh rather than dropping capture silently |
| Clock changes / sleep | Blocks split on wake; durations computed from monotonic clock deltas |
| LLM backend unavailable | Rules-layer classification only; ambiguous blocks queue for later; nothing blocks capture |

---

## 11. Milestones

| | Scope | Exit criteria |
|---|---|---|
| **M0 — Watcher** | shifud: events, capture ladder, dedupe, SQLite, exclusions, pause | Runs 8 h under budget (§3.4); `shifu log` CLI shows a sane trace of the day |
| **M1 — Ledger** | analyzer sessionization + rules classifier; menu bar app with Time tab | Day view matches a hand-kept diary within ~10% |
| **M2 — Brains** | local LLM classification + topics; daily digest; Work Mode + glow | Ambiguous-block accuracy spot-checked >85%; glow works and is likeable |
| **M3 — Vault** | knowledge extraction, inbox triage, FSRS review UI + CLI | 1 week of dogfooding yields >70% keep-rate on candidates |
| **M4 — Radar** | pattern miner + suggestion describer, Radar tab | ≥1 genuinely useful suggestion per week of dogfooding |
| **M5 — Hardening** | SQLCipher, retention jobs, onboarding, perf test suite, notarized build | Clean install → useful digest with zero config |

---

## 12. Future Directions (explicitly out of v1)

- **Cross-platform core**: extract sessionization/classification/SRS/mining into a Rust core with platform-specific capture shims (Windows: `Windows.Graphics.Capture` + UIA; Linux: wayland portals) — this is where Rust earns its place.
- Browser extension for exact URL + selection-level capture where AX falls short.
- Calendar/task integration to label blocks with intended work ("was I doing what I planned?").
- Audio-free meeting awareness (detect meeting apps, log attendance time, never record content).
- Vault embeddings for semantic search ("what did I read about SQLite WAL?").
- Direct Claude Code handoff for automation suggestions (§6.2).
- **SQLCipher at rest** (deferred from Phase 6): GRDB's SQLCipher flavor isn't
  distributable via SwiftPM without switching to a community fork. v1 ships with
  `~/Shifu` locked to owner-only permissions (0700) instead; revisit when GRDB
  gains first-party SPM SQLCipher support or the storage layer is worth forking for.
- **Bundled MLX local model** (deferred from Phase 3): Apple Foundation Models
  covers the on-device path on macOS 26+; a ~2 GB bundled model only earns its
  place if dogfooding shows meaningful demand on older systems.
- Signed + notarized DMG packaging (needs Developer ID certs; `install-daemon.sh`
  covers the from-source path until then).
- Exclusion-list editing UI (defaults + `exclusions` table rows work today).

---

## 13. Open Questions

1. Should the heartbeat interval adapt to category (e.g., 30 s during `work` for finer ledger resolution, 5 min during `entertainment`)?
2. Local model choice: Apple Foundation Models framework (zero bundle cost, OS-version-gated) vs. bundled MLX model (~2 GB, works everywhere) — ship both with runtime selection?
3. Is glow-pulse enough for Work Mode, or is an optional hard mode (block-list with confirm-to-continue) worth its complexity and adversarial feel?
4. Vault dedupe: how aggressively should near-duplicate knowledge candidates merge across days (same fact re-encountered is itself an SRS signal)?
5. Should `excluded` time still count toward the ledger as an opaque "private" category (better totals) or vanish entirely (better deniability)? Default proposal: opaque category, toggleable.
