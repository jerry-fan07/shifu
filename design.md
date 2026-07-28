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
3. **Private by default.** All raw captures stay on-device. LLM analysis is cloud-based (DeepSeek — see §4.2), but nothing leaves the machine until the user supplies an API key, and even then only derived, redacted text samples are sent — never raw pixels or raw captures. *(Revised 2026-07: v1 aspired to on-device-only analysis; Apple Foundation Models' 4k window, weak labels, and macOS 26+ gate made that path useless in practice.)*
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
3. **Screenshot → on-device OCR** (fallback): only when the AX tree is empty/blocked (games, Electron apps with poor AX, video conferencing, images/PDF viewers). Single-window capture via **ScreenCaptureKit** (`SCScreenshotManager`, one frame — not a stream), captured at up to 2× (Retina) pixel density capped at ≤2560 px wide, fed to **Vision `VNRecognizeTextRequest`** (runs on the Neural Engine/GPU, `fast` recognition level with language correction). Capture density is the accuracy lever: `fast` at 1× produced unusable text on Retina UI, while at 2× it is near-perfect in ~200 ms; `accurate` adds ~550 ms/burst for marginal gains and would break the §3.4 burst budget. The bitmap is discarded immediately after OCR; **pixels are never persisted** in the default configuration.
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
2. **LLM layer (DeepSeek)**: ambiguous blocks (unknown apps, mixed-content sites like YouTube/Twitter/Reddit) are classified from their text sample by DeepSeek; prompt returns `{category, confidence, topic}`. Two model slots share one key and endpoint (`deepseek.base_url` accepts any OpenAI-compatible server): the **fast slot** (`deepseek.model`, default `deepseek-v4-flash` — cheap, non-reasoning) runs the high-volume stages — this classification, knowledge extraction, work-note narratives, radar descriptions; the **reasoning slot** (`deepseek.reasoning_model`, default `deepseek-v4-pro`, a thinking model) runs semantic task grouping and theme clustering (§5.3), where naming the user's intent is the whole job. Only redacted, post-exclusion text samples are sent, and only once an API key is set — without a key this layer is skipped and rules-only output stands. *(Revised 2026-07: this tier was originally an on-device model — Apple Foundation Models or bundled MLX — with cloud as an opt-in third tier. The 4k combined window forced tiny batches, labels were weak, and Foundation Models needs macOS 26+; the on-device tier was dropped and DeepSeek promoted to the sole LLM backend.)*

Categories (v1, user-extensible): `work`, `learning`, `entertainment`, `social`, `communication`, `admin`, `idle`. Every block also gets a free-text `topic` ("debugging shifu capture daemon", "watching F1 highlights") used by the knowledge and automation stages.

### 4.3 Outputs

- **Ledger**: per-block rows in `activities`; rollups by day/week/category/topic power the dashboard.
- **Daily digest** (generated at a configurable time, default 18:00): time breakdown, top topics, streaks/anomalies ("2.1 h on social, 3× your average"), new notes captured, new automation suggestions. Delivered as a local notification linking into the dashboard.

### 4.4 Work Mode

A user-invoked focus contract, toggled from the menu bar (and optionally auto-scheduled, e.g. weekdays 9–12).

- While active, the daemon classifies the *current* block in near-real-time using the rules layer only (no LLM on the hot path). Unknown → treated as neutral, never nagged.
- If the current block has been non-`work`/non-`learning` for a grace period (default 3 min), Shifu shows the **glow pulse**: a full-screen, click-through overlay window (`NSWindow` at `.screenSaver` level, `ignoresMouseEvents = true`) that breathes a soft colored vignette at the screen edges for ~2 s, then fades, with a short translucent motivational line centered on the screen the user is working on (e.g. "Believe in yourself"). Repeats at most every 4 min while off-task. No sound, no modal — a nudge, not a scold.
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
- Review UI: a SwiftUI card session launched from the menu bar ("Review · 7 due") or the *Cards* tab, plus a `shifu review` CLI for terminal users. Space reveals, 1–4 grades (with next-interval previews); cards can be edited (E), skipped (S), or deleted mid-session, and "Again" cards rotate to the back of the session queue. Card text renders inline/fenced code and $LaTeX$ natively via `CardMarkup` (no web views).
- **Cards home** (dashboard *Cards* tab): review-activity calendar heatmap (from `srs_reviews`), per-card urgency overview (overdue / due today / new / soon / scheduled), and the deck picker. Inbox triage and the review session are separate screens pushed from here.
- **Decks** (dashboard *Cards* tab): the session pulls from a selectable deck — all notes, one theme, or one task (§5.3). Notes match a task by grouping key (topic slug, with containment fallback for topic keys).
- Target session length: < 5 minutes/day. The digest nags gently if the due queue exceeds a threshold.

### 5.3 Tasks, themes & work logs (vault-features.md)

> Vault second-brain phases V1–V4 shipped per vault-implementation.md: FTS5
> search index, per-(task, day) work notes, user-confirmed merge suggestions
> (assignment deferred — §12) and hybrid bm25 ∪ cosine
> search. Deferred follow-ons stay logged in vault-features.md §10.

The vault is a work database, not just flashcards:

- **Tasks**: the analyzer groups activities into ongoing tasks. With an LLM backend, `SemanticTaskGrouper` assigns blocks to *intent-level* tasks — "Applying to YC afterparties", "Booking flights for the trip" — spanning apps and domains: each block's evidence (titles, topics, text samples) plus a roster of recent semantic tasks goes to the model, which joins existing tasks or mints new ones (title + one-line gist), confidence-gated (0.6) and attempt-capped (3, like §4.2's classifier). The verdict lands in `activities.sem_key`, carried across rebuilds by span identity. Blocks the model can't place — and all blocks when no backend is configured — fall back to the mechanical key: classified topic, else domain, else app (`TaskGrouper`). The fallback is hardened against fragmentation: the classifier prompt lists recent topics and the model repeats one verbatim when a block continues that effort (keys only recur if wording recurs), a never-seen mechanical key mints a task only once a window shows ≥ 5 min behind it (`minNewTaskMs`), and sub-threshold, never-renamed, never hand-filed tasks inactive for a week are pruned (`TaskStore.prune`) — passing subjects stay task-less while their time still counts in the ledger. System shell surfaces — the lock screen, the Dock, one-shot dialogs, Shifu's own UI, bundle-less `unknown.<pid>` processes — are denylisted from grouping outright (`TaskGrouper.isSystemBundle`): they carry no topic or domain, so they'd bottom out at the `app:` key and mint permanent nonsense tasks ("loginwindow") that accrue time daily and never go stale; their blocks keep ledger time but never mint or join a task, and prune reaps ones minted before the list existed regardless of size, recency, or theme filing (the denylist starves them of new blocks anyway) — only a rename spares one. Tasks span days (the key recurs), are renameable, and renames survive re-analysis (keys never overwrite names, and the semantic pass never overwrites either).
- **Work logs**: one compiled log row per task per local day (`task_logs`): duration plus a "where — what" line ("Xcode, github.com — debugging capture daemon"). Rebuilt idempotently for every day an analyzer window touches; `private` time never becomes a task.
- **Themes** (replaced projects, v14): the broad initiatives blocks cluster into (`ThemeClusterer`), which is also what the user files a task under by hand. Filing is per block, so a task's theme is the one its time mostly sits in; filing one from the Task log writes all of that task's blocks and sets `theme_user_set`, the bit prune and auto-merge read as "the user judged this". A theme's tasks also form a review deck (§5.2).
- **Vault tab** shows today's compiled log (most recently worked task first) and the task list with its latest log line, behind a Themes / Task log toggle. Inbox triage lives on the *Cards* tab with the decks.
- **Task log filters**: a filter bar pinned above the log — range (today / 7 days / 30 days / all time), minimum time spent (default 5 min+), order (most recent / most time), and theme (all / one / unfiled). The range doubles as the window the time column counts, so a row's hours always match the range on screen. The section header carries "N of M" because the list is capped at 50 rows: a roster runs to hundreds of tasks, most of them a stray minute, and a capped recency-sorted list looks identical under every range without it. Minimum time and theme also scope the *Today* day log; range and sort don't — that log is already a single day, and its most-recent-first order is part of what makes it a log rather than a task list. The *Cards* deck picker still reads the unfiltered roster. Session state, not persisted.
- **Task detail page**: every task row opens as a full dashboard page (`TaskDetailView`): the LLM gist of what the task *is*, day-by-day history with the work-note narratives (§2.1 of vault-features.md) expandable inline, where the time went per source, the knowledge notes captured under the task, recent activity blocks, inline rename, and theme assignment (including creating a new theme in place).
- **Themes — the second clustering mode**: `ThemeClusterer` runs an *independent* LLM clustering of the same blocks into 3–8 broad initiatives spanning weeks ("YC Startup School", "Shifu development", "Travel") — one level above tasks, assigned per block (`activities.theme_key`, `"thm:"` namespace), so a task's blocks may straddle themes. Same engine discipline as semantic tasks: roster reuse (30-day window), confidence floor, `theme_attempts` cap, rebuild carry, fail-soft. Each theme keeps an LLM **running narrative** ("the story so far"), regenerated only when the hash of its *completed* days changes — at most one generation per active theme per day. The Vault tab gains a segmented **Themes / Task log** toggle; a theme's page shows the narrative, computed per-day history (no parallel log table — days derive from `theme_key` on read), the tasks its time flowed through (linking to their pages), and recent activity. Themes are renameable; renames stick.

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
- **Dashboard window**: four tabs — *Time*, *Vault* (today's work log, tasks, themes — §5.3), *Cards* (home screen with activity heatmap + card urgency; inbox and review as separate screens — §5.2), *Radar* (suggestions). Charts native SwiftUI; no web views.
- **The Time tab** carries one window (Day / Week) and one lens (Category / Theme / Task, §5.3) across two modes:
  - *Summary* — where the time went. A hero total with its change against the same window before it, a donut, and one row per group: color, name, duration, share, a proportional bar, expanding into the apps and domains inside it, its block count, and the hour it peaked. This is what makes "3 h 10 m of today was work, and 40 m of that was Chrome" a thing you can read at a glance.
  - *Timeline* — when it happened. Stacked bars over the hours or days, plus the block list. Its legend carries each group's total, so the strip under the chart is a breakdown rather than a color key.
  - A group wears the same color in both modes; category hues are fixed, theme/task hues come from a stable hash of the name so a theme keeps its color as the window changes. Past the top 7 groups everything folds into "Other" rather than growing the palette.
- **Review session**: minimal card interface (see §5.2).
- **Onboarding**: a 4-screen flow that (1) explains exactly what is and isn't captured, (2) requests Screen Recording + Accessibility permissions with live previews of what Shifu sees, (3) sets exclusions (pre-checked: password managers, banking category, private browsing), (4) picks analysis backend (local-only default).

---

## 8. Privacy & Security

This section is load-bearing; a screen watcher lives or dies on trust.

- **Local-first capture, forever.** Raw observations never leave the device. LLM analysis goes to DeepSeek, but it is text-only, post-filtering and post-redaction, clearly labeled in settings, and inert until the user pastes an API key — the key is the opt-in. "Rules only" turns it off entirely.
- **No pixel persistence.** Screenshots exist in memory only for the OCR call in the default configuration. (A debug flag can retain them, visibly indicated in the menu bar.)
- **Exclusion list**, enforced in the daemon *before* capture (not filtered after):
  - Default-excluded apps: password managers, Keychain, system auth dialogs.
  - Default-excluded domains: banking/financial category list, health portals; user-editable.
  - Private/incognito browser windows: always excluded, not configurable off.
  - Regex redaction pass over all extracted text for credit-card numbers, SSNs, and obvious secrets (`AKIA…`, `-----BEGIN`, JWT shapes) before anything touches disk.
- **Encryption at rest**: SQLite via SQLCipher; vault folder optionally encrypted (off by default since users may want Obsidian interop — the tradeoff is stated plainly in settings).
- **Retention**: raw text 14 days (configurable 1–90); ledger aggregates and confirmed notes indefinitely; one-click "delete everything," and a date-range delete ("forget this afternoon").
- **Pause semantics**: pause = the AX observers and event taps are torn down, not just ignored. The menu bar glyph makes state unambiguous.
- **No network access in shifud at all** — only the analyzer can touch the network, and only to the configured DeepSeek endpoint when an API key is set. Enforced via separate binaries so this is auditable.

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

Key tables: `observations` (§3.5), `activities` (block, category, topic, confidence, task), `tasks` / `themes` / `task_logs` (§5.3), `rules` (user classification overrides), `suggestions`, `srs_reviews` (review log for FSRS optimization), `settings` (key/value user preferences).

User-tunable settings are declared once in `SettingsCatalog` (key, default, bounds, copy) and read through typed accessors that clamp on both read and write, so the daemon and the Settings UI cannot disagree about a bound. `shifud` applies interval changes live via `Daemon.reloadIntervals()` — a new daemon-consumed setting must add its own changed-guard there, or it will persist and render correctly but be ignored until restart. Work Mode's distracting-site list is deliberately *not* in `rules`: it drives the glow only, leaving ledger categories untouched.

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
- ~~SQLCipher at rest~~ — shipped after v1 via DuckDuckGo's GRDB 7.4.1 +
  SQLCipher 4.7.0 xcframework (`shifu encrypt`, key in the login Keychain,
  `SHIFU_DB_KEY` override for tests). Follow-up done: `install-daemon.sh`
  code-signs the binaries with a stable identity — required anyway because TCC
  keys Accessibility/Screen Recording grants to the code signature, and the
  ad-hoc linker signature orphaned them on every rebuild (toggles stayed ON in
  System Settings while capture degraded to metadata-only).
- ~~**Bundled MLX local model** (deferred from Phase 3)~~ — mooted 2026-07:
  the on-device tier was dropped altogether (§4.2) and DeepSeek is the only
  LLM backend. On-device analysis returns only if a local model ever matches
  cloud quality at ledger-scale batch sizes.
- Signed + notarized DMG packaging (needs Developer ID certs; `install-daemon.sh`
  + `install-app.sh` cover the from-source path until then — the latter bundles
  ShifuApp into a standalone menu bar `Shifu.app` in /Applications).
- Exclusion-list editing UI (defaults + `exclusions` table rows work today).
  The Settings window (§9) is the natural home once built: `exclusions` needs a
  new descriptor shape in `SettingsCatalog`, not a new window.
- **OCR-inclusive per-trigger perf measurement** — required before the capture
  heartbeat floor (§9) can drop below 30s. `make perf` cannot answer this today
  for two independent reasons: `--synthetic-feed` exits before `Daemon` is
  constructed, so no heartbeat timer ever runs; and `SyntheticFeed` records
  `captureKind: .ax` only, so its cost-per-trigger excludes the
  ScreenCaptureKit + Vision rung that dominates real capture cost. The 30s
  floor is therefore chosen conservatively (~960 heartbeat triggers per 8h day,
  against the harness's "<2000 real triggers" baseline) rather than measured
  against the §3.4 budgets.
- ~~Cap LLM re-attempts on low-confidence ambiguous blocks.~~ Shipped: with
  the `LedgerBuilder` carry (confident verdicts + `extracted` survive the
  idempotent rebuild), migration v10 adds `activities.llm_attempts` — the
  classifier retries a sub-floor block at most `maxAttempts` (3) times, the
  counter is carried across rebuilds by span, and a changed span resets it so
  genuinely new evidence retries. On an unchanged window the billable pool now
  drains to zero and LLM billing terminates.
- **Semantic task clustering, assignment half (vault V3)** — the day-one
  NLEmbedding spike (2026-07-19, 103 contentful signatures from the dogfood
  DB) showed separation too weak for *silent* centroid assignment: same-task
  pairwise cosine mean 0.78 vs cross-task 0.66, precision ≈0.38 at the
  planned 0.75 threshold (cross-task p90 = 0.805). Bare bundle-id signatures
  are degenerate (unrelated apps score ≈0.97). Auto-assignment waits for a
  better on-device embedder. The merge-*suggestion* half looks viable:
  at ≥0.9 precision ≈0.8 even against lexical labels, and the top-scoring
  "false" pairs were in fact true fragmentations (same GitHub page under two
  keys) — with the overlapping-sources filter and user confirmation it fails
  safe. Decide V3 scope (suggestions-only vs wait) before building.
  **Update (2026-07-27):** intent-level grouping shipped by a different route —
  `SemanticTaskGrouper` (§5.3) asks the *LLM tier* to assign blocks to
  goal-level tasks, sidestepping the weak-embedder problem entirely.
  Embedding-based centroid assignment stays deferred; the merge-suggestion
  half remains useful for consolidating pre-existing mechanical tasks into
  their semantic successors.
  **Update (2026-07-28):** that consolidation now runs itself —
  `TaskMerges.autoMerge` (vault-features.md §5.2) folds the fragment end of the
  suggestion queue at 0.9 and substantial pairs only at 0.97, never across a
  user-typed name or a hand-filed theme boundary. It exists because the suggestion-only
  design produced 679 open pairs against 1,183 tasks: precision was never the
  binding constraint, triage throughput was. The queue's remainder moved off the
  Vault tab into `MergeReviewView`, with a bulk dismiss. The same dogfood explosion (977 tasks in ten
  days, 620 under 5 min) also traced to the *mechanical* layer: unanchored
  per-block topic wording plus unconditional task minting for one-off
  domain/app keys — fixed in §5.3 with prompt-anchored topics, the 5-min
  substance gate, and prune, so the fallback path can't refill the roster
  with debris.
- ~~LLM-written narrative work logs~~ — shipped in vault phase V2
  (vault-features.md §2.1): per-(task, day) work notes whose `## Sessions`
  prose regenerates only when the day's activities change (content-hash gate
  keyed on spans + text samples, not row ids — LedgerBuilder rebuilds recreate
  row ids every run).
- **Structural cleanups, deferred deliberately** (surveyed 2026-07-24 against
  a green `make check` — build, tests, SwiftLint `--strict`, and the privacy
  invariants all passing). None of these is a correctness bug; each is a
  maintainability debt worth fixing the next time its file is opened for real
  work, not as a standalone churn commit. Recorded in ARCHITECTURE.md too.
  - `shifu-cli/main.swift` (480 lines) has top-level statements interleaved
    with declarations: `let args` sits mid-file, and `do { try run() }` appears
    before `run()` is declared. Split the command bodies into sibling files
    (top-level code must stay in `main.swift`, functions may move) and drop the
    `args` global in favor of passing arguments explicitly. `VaultBench.swift`
    was already carved out for exactly this reason — the 500-line SwiftLint
    file limit — which is the signal the file wants a real split.
  - The `pause_until` expiry parse exists three times, in `shifu-cli/main.swift`,
    `shifud/PauseController.swift`, and `ShifuApp/LedgerStore.swift`; the
    `work_mode` existence check likewise. A change to either control-file
    format silently breaks two of the three. One small injectable type in
    ShifuCore (following `VaultStore(root:)`) would make the format testable
    and single-sourced.
  - `Retention` is declared at the bottom of `Analysis/LedgerBuilder.swift`,
    where nobody grepping for the concept will find it. Move to its own file
    under `Storage/` next to `DeletionTools`, which shares its concern.
  - `ShifuApp/LedgerStore.swift` (326 lines) is the app's single read model for
    pause, vault, tasks, themes, radar, and search, with 16 repetitions of
    `try? db()` swallowing errors into empty state. Feature-scoped stores would
    help, but the UI layer has no test coverage, so this one waits for a reason
    beyond tidiness.
  - `Tests/ShifuCoreTests/ShifuCoreTests.swift` is still the 6-line
    `swift package init` placeholder.
  - Do **not** "clean up" `shifu-cli/VaultBench.swift`: `scripts/perf-vault.sh`
    invokes `shifu vault bench` and parses its output, so deleting it breaks
    `make perf`.

---

## 13. Open Questions

1. Should the heartbeat interval adapt to category (e.g., 30 s during `work` for finer ledger resolution, 5 min during `entertainment`)?
2. ~~Local model choice: Apple Foundation Models framework (zero bundle cost, OS-version-gated) vs. bundled MLX model (~2 GB, works everywhere) — ship both with runtime selection?~~ Resolved 2026-07: neither. Foundation Models shipped first and lost on its 4k window, weak labels, and macOS 26+ gate; both on-device paths were dropped for DeepSeek (`deepseek-v4-flash` default) as the sole backend (§4.2).
3. Is glow-pulse enough for Work Mode, or is an optional hard mode (block-list with confirm-to-continue) worth its complexity and adversarial feel?
4. Vault dedupe: how aggressively should near-duplicate knowledge candidates merge across days (same fact re-encountered is itself an SRS signal)?
5. Should `excluded` time still count toward the ledger as an opaque "private" category (better totals) or vanish entirely (better deniability)? Default proposal: opaque category, toggleable.
