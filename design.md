# Shifu — Design Specification

> *Shifu watches you work.*

**Date:** 2026-07-17
**Status:** Draft v1 (expanded from [instructions.md](instructions.md))
**Target platform:** macOS 14+ (Apple Silicon first)

---

## 1. Product Overview

Shifu is a local-first, always-on observer that captures what is on your screen with near-zero perceptible overhead, then turns those observations into three outputs:

1. **Productivity ledger** — an accurate, automatic accounting of where your time went (work, entertainment, socializing/networking, learning, admin, idle).
2. **Knowledge vault** — flashcard decks you ask for, built from what you actually worked on and surfaced on a spaced-repetition schedule.
3. **Efficiency radar** — detection of repetitive or manual workflows that could be automated or delegated to AI, with concrete suggestions.

### Design principles (in priority order)

1. **Invisible.** The user should never feel Shifu running. No fan spin, no dropped frames, no battery anxiety. Capture must be event-driven, never polling-heavy.
2. **Minimalist.** In every dimension: a UI with the fewest possible surfaces (one menu bar item, one window, one review card), features that earn their place or don't ship, plain formats over clever ones (Markdown, SQLite), and a codebase small enough to audit. When in doubt, leave it out — every addition must justify itself against this principle.
3. **Private by default.** All raw captures stay on-device. LLM analysis is cloud-based (DeepSeek — see §4.2), but nothing leaves the machine until the user opts in — choosing the hosted Shifu Cloud backend, or supplying their own API key — and even then only derived, redacted text samples are sent — never raw pixels or raw captures. *(Revised 2026-07: v1 aspired to on-device-only analysis; Apple Foundation Models' 4k window, weak labels, and macOS 26+ gate made that path useless in practice.)*
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
│  • builds requested flashcard decks → Markdown vault        │
│  • detects repetition patterns → automation suggestions     │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────┴────────────────────────────────────┐
│  Shifu.app (menu bar UI)                                    │
│  • status, pause/kill switch, focus-mode toggle              │
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
requested deck ──► deck builder ──► cards ──► vault (.md) ──► SRS queue
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
| Screen lock / user switch | screen locked, or another session on the console → tear capture down; back up when that clears. Re-decided on `com.apple.screenIsLocked`/`Unlocked`, `NSWorkspace.didWake`, session resign/become active | — |

There is **no fixed screenshot interval**. A user reading one page for 10 minutes generates one capture, not 600.

The locked screen is a separate rung from idle detection because **idle detection does not
cover it**. `CGEventSource.secondsSinceLastEventType` reports the *user session's* HID idle
time, and at the lock screen that session is not the one receiving events, so the counter
never crosses the 5-minute threshold. The heartbeat then samples `loginwindow` every interval;
each sample is a near-duplicate of the last (both content-free `meta`) and every dedupe hit
slides the row's TTL forward again, so `ObservationRecorder` keeps bumping one row's
`last_seen` for as long as the machine stays locked — the dogfood ledger grew a single
observation spanning 60 hours, and the 60-hour activity block built from it. Tearing capture
down breaks the loop: with no heartbeat there is nothing to bump, the row's dedupe TTL expires
during the gap, and the next capture starts a fresh observation that the sessionizer reads as a
new block.

**Sleep is not on this list, deliberately.** It needs no handling of its own: while a machine
is asleep nothing executes — no timer fires, no capture is taken, no `last_seen` is bumped —
and on wake the wall clock has moved past the dedupe TTL, so the next capture inserts a new row
and the sessionizer splits the block there. The gap ends the session by itself. Adding a
sleep/wake state on top bought nothing and cost the correctness of the case below, so it was
removed.

What sleep *does* do is deliver a wake **while the screen is still locked** — the ordinary case
on a machine that autolocks. So `didWake` is subscribed, but only as a trigger to re-decide,
never as a resume: *waking is not unlocking.* `didWake` arrives while the password prompt is
still up, seconds later if you are sitting there and hours later if the lid was bumped or a
scheduled wake fired, and a daemon that treated it as a resume would hand the heartbeat straight
back to `loginwindow` for the rest of the lock.

That case is what shapes the state, or rather the absence of it: **every reason capture is down
is queried, not remembered**, and capture returns only when all of them have cleared
(`Daemon.syncCapture`, the sole caller of the start/stop pair). The screen lock and console
ownership come from the window server (`CGSSessionScreenIsLocked`, `kCGSSessionOnConsoleKey`) and
the pause from its control file (§8). So no reason can clear another's teardown, ordering between
notifications stops mattering, and a daemon launched while the machine already sits locked needs
no special case. Both window-server flags fall back to "don't suspend" when absent, which is the
safe direction — an unreadable key degrades to capturing a stray lock-screen block, filtered from
every display (§7), rather than to silently capturing nothing at all.

**While the window server is what holds capture down, the daemon re-asks every 5 s**
(`Daemon.syncRecheckTimer`), and *that* is what ends the suspension — the notifications are only
an optimization for how fast it notices. This is measured, not defensive, over four real
lock/unlock trials (2026-07-29, macOS 26):

- **Locking is reliable.** Every trial suspended capture the same second the screen locked, and
  held it clean: 16 minutes locked with not one row inserted and no `last_seen` bumped, where
  roughly sixteen heartbeats would each have bumped it before. A daemon *launched* into a locked
  machine took zero captures — no lock edge to hear, and the query caught it anyway.
- **Unlocking is not.** One trial delivered `com.apple.screenIsUnlocked` with the flag already
  clear and capture returned in about a second. Another never resumed at all — still suspended
  13 seconds after the unlock, which is where this timer came from. So the notification *is*
  delivered on this OS but is **not ordered against the flag it describes**, and a re-decide
  prompted by it can read a screen that still says locked.

Querying rather than remembering keeps the answer from being *wrong*; nothing about it makes the
answer *timely*, and a suspension that cannot end itself is silent data loss — worse than the
marathon block this rung exists to prevent. The asymmetry is the whole argument: a missed lock
costs one lock-screen block that no page charts anyway (§7), while a missed unlock costs every
observation until the daemon restarts. The recheck costs one dictionary read per interval and
only while the machine is locked or switched away, which is exactly when nothing else is
happening; it never captures, it only re-decides. Timer throttling under lock doesn't weaken it
either — the run loop unfreezes at the unlock, which is precisely when the recheck is needed.

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
2. **LLM layer (DeepSeek)**: ambiguous blocks (unknown apps, mixed-content sites like YouTube/Twitter/Reddit) are classified from their text sample by DeepSeek; prompt returns `{category, confidence, topic}`. Two model slots share one key and endpoint (`deepseek.base_url` accepts any OpenAI-compatible server): the **fast slot** (`deepseek.model`, default `deepseek-v4-flash` — cheap, non-reasoning) runs the high-volume stages — this classification, knowledge extraction, work-note narratives, radar descriptions; the **reasoning slot** (`deepseek.reasoning_model`, default `deepseek-v4-pro`, a thinking model) runs semantic task grouping and theme clustering (§5.3), where naming the user's intent is the whole job. Only redacted, post-exclusion text samples are sent, and only once the user has opted in — their own API key, or the hosted **Shifu Cloud** proxy (`analysis.backend = shifu-cloud`, no user key; the analyzer mints a device token from `shifu_cloud.base_url` and speaks the identical wire protocol through it). Without either opt-in this layer is skipped and rules-only output stands. Two more settings make a **local profile** of the same backend: `deepseek.context_tokens` (default 60,000, clamped 8k–200k) is the window every stage sizes its batches to (invariant 7), and `deepseek.reasoning_thinking` (default on) turns the reasoning slot's chain-of-thought off — off, it behaves like a second fast slot with zero response headroom, which is what keeps a 16k local-server window from going budget-negative. Point `deepseek.base_url` at e.g. a llama-server, state the window it serves, turn reasoning thinking off, and the whole pipeline adapts with no other dial. A loopback endpoint is additionally **paced** (`LLMPacer`; `llm.duty_active` default 40%, `llm.duty_idle` default 75%): the analyzer rests before each call in proportion to the previous call's length — harder while the user is present, gentler once the screen locks or input idles five minutes, halved again under `.serious` thermal pressure and paused outright at `.critical` — so a catch-up run reads as bursts with cool-down gaps instead of minutes of pinned GPU, and the fans stay quiet. Total work is unchanged; only wall time stretches, and the daemon already skips a tick while a run is still going. Interactive launches (`--build-deck`, `--radar`, `--digest`) and cloud endpoints are never paced. Launching llama-server with `-ub 256 -b 512` shrinks each prefill burst's power draw further. *(Revised 2026-07: this tier was originally an on-device model — Apple Foundation Models or bundled MLX — with cloud as an opt-in third tier. The 4k combined window forced tiny batches, labels were weak, and Foundation Models needs macOS 26+; the on-device tier was dropped and DeepSeek promoted to the sole LLM backend.)*

Categories (v1, user-extensible): `work`, `learning`, `entertainment`, `social`, `communication`, `admin`, `idle`. Every block also gets a free-text `topic` ("debugging shifu capture daemon", "watching F1 highlights") used by the knowledge and automation stages.

### 4.3 Outputs

- **Ledger**: per-block rows in `activities`; rollups by day/week/category/topic power the dashboard.
- **Daily digest** (generated at a configurable time, default 18:00): time breakdown, top topics, streaks/anomalies ("2.1 h on social, 3× your average"), new notes captured, new automation suggestions. Delivered as a local notification linking into the dashboard.

### 4.4 Focus Mode

A user-invoked focus contract, toggled from the menu bar (and optionally auto-scheduled, e.g. weekdays 9–12).

- While active, the daemon classifies the *current* block in near-real-time using the rules layer only (no LLM on the hot path). Unknown → treated as neutral, never nagged.
- If the current block has been non-`work`/non-`learning` for a grace period (default 1 s), Shifu shows the **glow pulse**: a full-screen, click-through overlay window (`NSWindow` at `.screenSaver` level, `ignoresMouseEvents = true`) that breathes a soft colored vignette at the screen edges for ~2 s, then fades, with a short translucent motivational line centered on the screen the user is working on (e.g. "Believe in yourself"). Repeats at most every 10 s while off-task. No sound, no modal — a nudge, not a scold.
- Escalation is configurable: off → glow → glow + haptic (on supported trackpads) → gentle notification. Default is glow only.
- Focus Mode sessions are themselves logged, so the dashboard can report "focus session adherence."

---

## 5. Knowledge Vault & Spaced Repetition (§2 of instructions)

### 5.1 The vault

The vault is **plain Markdown in a plain folder** (`~/Shifu/vault/`), one note
per fact, YAML frontmatter for metadata. Fully usable with Obsidian/any editor;
Shifu is not a lock-in layer.

**Nothing writes a note automatically.** Earlier versions ran a
`KnowledgeExtractor` over learning and work blocks, proposing cards into an
inbox for keep/discard triage. It was removed in 2026-07 on the evidence: on
the dogfood vault it had produced **1,162 proposals against 1 kept card**. A
suggestion queue nobody drains is not a feature, it is a chore with a badge on
it — and every one of those proposals cost a model call to write and a decision
not to make. There is no extractor, no inbox, and no triage step.

What remains is one rule: a card exists because the user asked for a deck
(§5.2). That is what "nothing enters the review queue unconfirmed" means now —
the deck request *is* the confirmation, so deck cards are born `kept` with FSRS
seeded rather than routed through a second approval. Pruning happens during
review, with the card actually in front of you.

`Note.State.inbox` survives in the model as a **guard, not a workflow**: a
vault is user-owned Markdown, and an old file or a restored backup can still
carry `state: inbox`. Keeping the case means such a note parses as itself and
stays out of the review queue; deleting it would make it fall through to
`kept` and silently turn months of declined suggestions into cards.

### 5.2 Review (spaced repetition)

- Scheduler: **FSRS** (modern, better-calibrated than SM-2; a Swift implementation is small). SRS state lives in the note's frontmatter so the folder stays self-contained.
- Review UI: a SwiftUI card session launched from the menu bar ("Review · 7 due") or the *Practice* page, plus a `shifu review` CLI for terminal users. Space reveals, 1–4 grades (with next-interval previews); cards can be edited (E), skipped (S), or deleted mid-session, and "Again" cards rotate to the back of the session queue. Card text renders inline/fenced code and $LaTeX$ natively via `CardMarkup` (no web views): symbols, `^`/`_` scripts, `\frac`, `\sqrt`, accents, the math alphabets (`\mathbb{R}` → ℝ, `\mathbf{1}` → 𝟏) and `\begin{pmatrix}` environments become styled runs, with variables italic and digits/operators/function names upright the way a typeset formula has them. Unknown commands degrade to their bare name, so nothing ever disappears from a card. **Spacing is computed, not inherited** (`CardMarkupSpacing.swift`): TeX sets a formula by what its symbols *are* — a relation gets a wider gap than a binary operator, a sign gets none, an italic glyph gets an italic correction before an upright one so `‖x‖` doesn't weld the bars onto the x — and the "author" here is a model that types math with wildly uneven spacing. Gaps are Unicode fixed spaces, scaled down inside scripts the way TeX's `mu` units are, so the runs stay plain text. Surfaces that can't style runs — the card-list snippet, the `shifu review` terminal — go through `CardMarkup.plainText`, which undoes that spacing and flattens the markup to Unicode super/subscripts rather than showing the reviewer raw LaTeX.
- **The Practice band** (§7) is two places. *Due* is the queue: the due count, the deck picker (ready, unpaused decks; themes and tasks as filters), the review-activity calendar heatmap (from `srs_reviews`), the due cards with per-card urgency (overdue / due today / new / soon / scheduled), and the one button that starts a session. *Decks* is the shelf as a **list**: one row per deck — title over its source task and its never-started count, then card count, **behind**, due-now, and the **next 7 days** as a spark (`ForecastSpark`: the band's grammar at table scale, backlog mark then a mark a day, every row scaled to one shared ceiling so their heights can be compared down the column) — with **suggested decks** above it (title, source task, sample cards, Keep/Discard) and the loose cards (kept before decks existed, or whose deck's task was pruned) closing the list; over the list sits the **load-ahead band** (`ReviewForecastView`), a column per day for four weeks with everything already past its day gathered into one column behind a divider at the left — the Due tab's heatmap is the record of having shown up, this is the bill for it, and it belongs on the shelf because it is a fact about everything kept rather than about the next sitting. Never-reviewed cards are left out of the columns entirely, never counted as backlog: they are born due (below) but rationed by `ReviewGate`, so drawing them as debt would report a fresh hundred-card deck as a hundred reviews of neglect — the shelf row names them under the deck instead. Paused decks sit the band out the way they sit out every queue, and cards scheduled past the window are named in the eyebrow rather than drawn (one column holding a hundred days beside columns holding one has no honest height). The band carries no summary line: every figure it holds is also a shelf column below it, so spelling them out again under the chart was clutter. Urgency reads twice over, from a column's distance along the axis and from the same three status hues the card rows use. *Behind* and *due now* are deliberately both on a row and deliberately different: the first is the debt (reviews whose day has passed), the second is the session `ReviewGate` would actually hand you, new-card ration included. A deck no queue is drawing from — paused, or still building — shows a dash for both and no spark, since a zero there would read as "caught up" rather than "not playing"; a building deck's spinner rides beside its name, where the eye lands first. a **New deck** button opens the form a deck is made on (`NewDeckPage`, its own pushed page): pick the source task from the recent tasks without one, retitle the deck, give the builder optional free-text **instructions** (stored on the row, folded into every build prompt including drain retries), pick a **card count** (automatic — the builder judges, no hard limit — or a range whose top the build enforces in code, trimming overshoot and skipping leftover batches), and set the review settings before the deck exists — the same one-deck-per-task route as the task page's button. A deck row opens as its own page — cards are never inlined in the list, because a deck built for the long haul runs to hundreds of them — with rename and delete in the rail and the deck's **review settings** in the head. *Paused* takes the deck's cards out of every queue and count; *new cards per day* (default 20, liftable) caps how many never-reviewed cards the deck may introduce per local day — deck cards are born due-now, so an uncapped hundred-card deck would otherwise land in one sitting. Both act through **`ReviewGate`**, which every queue builder passes (the app's vault snapshot and `VaultStore.due()` behind `shifu review`), spending the daily allowance oldest-first and counting introductions as first-grades in `srs_reviews` — a due *review* is never gated, only introductions are rationed. **Deleting a deck deletes its cards** (they exist because the deck was asked for; the review log stays, being a record of what happened) and writes a dismissed `deck_suggestions` row so the suggester can't propose back what was just thrown away — the task page button and New deck remain the deliberate routes back. The review session is the one screen pushed from here — there is no card inbox.
- **Decks are user-requested and persisted** (`decks`). A deck is one row per task — `key` (`deck:<slug>`), `task_key`, `title`, a one-way `pending → building → ready` status, the review settings `paused` and `new_per_day` (v19), the optional `instructions` brief the builder folds into its prompt (v20; NULL when none were given), and the optional `cards_min`/`cards_max` range (v21; both NULL is automatic, `cards_max` is code-enforced). There is no `card_count` column: the user prunes cards during review, so a stored count would start drifting the moment the feature is used as designed. The count is always derived from `vault_index.deck_key`.

  There are two ways to get one. The analyzer's weekly **`DeckSuggester`** looks for a task substantial enough to deserve a deck — intent-named key, ≥45 min of learning/work in 14 days, and that time *dominant* rather than incidental — and asks the model whether it is worth it, with two or three real sample cards if so. Most tasks aren't, and the answer is stored either way: a `deck_suggestions` row keyed on `task_key` (not `task_id` — prune and merge delete task rows and SQLite reuses rowids, so an id-keyed permanent row could suppress an unrelated future task). That row is what stops a task being re-billed for the same verdict every week. Caps: ≤3 open proposals, ≤2 *model calls* per run. The second is the **Create flashcard deck** button on a task's page, which is also the escape hatch from a dismissed or declined proposal.

  Accepting writes the sample cards immediately and asks the analyzer to fill in the rest. Building needs the network, which only `shifu-analyzer` may touch (§8), so the app launches it with `--build-deck <key>`; that flag takes an early exit before the ledger rebuild, since the request is interactive. **There is no analyzer single-instance lock**, so concurrent builds are kept apart by a compare-and-set on `decks.status` rather than a lock — a claim older than an hour is reclaimable, and an hourly drain picks up any deck whose build never happened (a keyless launch, a process that died). Both mint-a-deck actions are gated on a configured LLM backend: without one nothing could ever finish the build, and the deck would sit "Building…" forever.

  Deck writes dedupe **only within their own deck**. The vault-wide `mergeIfDuplicate` could match a requested card against an unrelated note, bump *that* note's `seen_count`, and leave the deck quietly short a card with no `deck:` stamp to show where it went.

  Cards carry `deck: deck:<slug>` in frontmatter, which is all a deck *is* on disk:

  ```yaml
  ---
  id: 01J2Y…
  captured: 2026-07-29T14:02:00-07:00
  topic: FSRS stability
  task_key: sem:fsrs-tuning
  deck: deck:fsrs-tuning
  confidence: 0.90
  state: kept
  srs: {stability: 0.0, difficulty: 0.0, interval_days: 0.0, due: 2026-07-29T21:02:00Z, reps: 0}
  ---
  Stability is the number of days until recall probability falls to 90%.
  It grows with each successful review, and the growth is larger the longer
  the interval that was survived.

  Q: In FSRS, what does a card's *stability* measure?
  A: The number of days until its recall probability decays to 90% — so a
  higher stability means a longer safe interval.
  ```

- **Deck picker**: the session pulls from a selectable deck — all notes, one **deck**, one theme, or one task (§5.3), in that order. Only `ready` decks are offered; picking one mid-build would show a half-empty deck and read as a bug. Themes and tasks remain runtime filters over whatever cards exist, matched by grouping key (topic slug, with containment fallback for topic keys) — only decks are persisted. Cards kept from before decks existed carry no `deck:` and keep serving the All queue.
- Target session length: < 5 minutes/day. The digest nags gently if the due queue exceeds a threshold.

### 5.3 Tasks, themes & work logs (vault-features.md)

> Vault second-brain phases V1–V4 shipped per vault-implementation.md: FTS5
> search index, per-(task, day) work notes, user-confirmed merge suggestions
> (assignment deferred — §12) and hybrid bm25 ∪ cosine
> search. Deferred follow-ons stay logged in vault-features.md §10.

The vault is a work database, not just flashcards:

- **Tasks**: the analyzer groups activities into ongoing tasks. With an LLM backend, `SemanticTaskGrouper` assigns blocks to *intent-level* tasks — "Applying to YC afterparties", "Booking flights for the trip" — spanning apps and domains: each block's evidence plus a roster of recent semantic tasks goes to the model, which joins existing tasks or mints new ones (title + one-line gist), confidence-gated (0.6) and attempt-capped (3, like §4.2's classifier). The prompt is built around what a human watching over your shoulder actually uses (`SemanticTaskEvidence.swift`). **The roster is a weighted prior, not a list of names**: every entry carries its minutes and days logged over the 14-day window, days since last worked, and the domains its time actually went to — so a `partiful.com` block matches the task that already lives there, not merely the one whose title reads closest. **Work is sticky**: the already-grouped blocks on either side of a batch ride along read-only (id-less, so they can't be re-assigned), with the instruction to prefer the surrounding task when a block's own evidence is thin — the strongest cue a human has, since switches are punctuated events. That prior is explicitly **fenced against interruptions**: a short messaging/social/entertainment detour between two stretches of one task is a break from it, never part of it — the *return* is the continuity evidence, not the detour. **The cheapest claims never reach the model**: an unplaced sub-minute glance with the same task running on both sides of it, every gap inside one sitting (`Sessionizer.gapThresholdMs`), inherits the sandwich's task outright (`SemanticTaskInheritance.swift`) — zero tokens, run before the model pass so its candidate pool is already smaller; break categories (messaging/social/entertainment) never inherit, the same interruption fence, and exhausted `sem_attempts` are honoured, so inheritance can't back-door a verdict the model refused. **The evidence per block is denser at the same token cost**: observations are sampled across the block's whole span (first, last, and an even fan between) instead of its opening minutes, and browser blocks carry sanitized page identities (`github.com/org/repo` — origin plus two path segments, query and fragment dropped, then re-redacted, since `observations.url` is stored raw) instead of the bare host. Sub-minute glances are pooled, not discarded: one 40-second glance is not worth tokens (`minBlockMs`), but the same app and domain glanced at a dozen times in a quarter hour is one act of attention — a hop-style tool (Conductor in the dogfood ledger) produces *only* such slivers — so they coalesce into **runs** (`SemanticTaskSlivers.swift`): same app+domain, gaps to 15 min, other apps freely in between, pooled active time clearing the same 60 s floor one block must (a 48 h dogfood window collapsed ~1.5k sliver candidates into ~105 runs; the lone glances left behind are what the floor exists for). A run is one candidate at one block's token cost — its evidence fans across the members through the same five-sample spread, its prompt line reads as what it is ("7 visits · 3m over 41m"), it is assigned all-or-nothing (hops straddling two intents land on one key, bought back by the 15-minute cut), and a declined run burns an attempt on every member, so exhausted ones drop out and the run re-forms smaller, no stored identity. The candidate limit is a **quota** — long blocks take slots first, runs fill the remainder by pooled time; admitting by recency alone once let a hop-heavy afternoon buy 59 glances and 1 block of real work. Everything stays token-budgeted (CLAUDE.md invariant 7): backends under 16k context get the compact tier — the twelve heaviest tasks, names and gists only, and a shorter context section — which keeps on-device Foundation Models' 4k window in budget. The verdict lands in `activities.sem_key`, carried across rebuilds by span identity. Blocks the model can't place — and all blocks when no backend is configured — fall back to the mechanical key: classified topic, else domain, else app (`TaskGrouper`) — an `app:` task minting under the installed app's own Launch Services name rather than the bundle-id tail, which is wrong exactly when the tail is generic (`com.conductor.app` would otherwise mint a task literally named "app"). With a backend configured the fallback is also a **last resort** (`TaskGrouper.MechanicalMinting`): a *container* key — `domain:`/`app:`, the namespaces that name where time went rather than what it was for — mints a task, or keeps attaching to an existing one, only from blocks the semantic pass has *finished declining*, summing past `minNewTaskMs`; `TaskStore.prune` reaps existing container tasks below the same bar on sight, on the same flag, so reap and mint cannot disagree. "Instagram" stays a task because the model keeps declining to place it; a 40-second message check stays task-less instead of becoming a task called "MobileSMS". A rename or a merge into the task spares it from both (a merge rewrites the absorbed blocks' `sem_key` to the survivor's key, so the fold holds across rebuilds), and the policy derives from *configuration*, never from whether a pass's calls succeeded — a network timeout must not mint; with no backend at all, minting is unrestricted and the rules-only roster stands whole (§10). The fallback is hardened against fragmentation: the classifier prompt lists recent topics and the model repeats one verbatim when a block continues that effort (keys only recur if wording recurs), a never-seen mechanical key mints a task only once a window shows ≥ 5 min behind it (`minNewTaskMs`), and sub-threshold, never-renamed, never hand-filed tasks inactive for a week are pruned (`TaskStore.prune`) — passing subjects stay task-less while their time still counts in the ledger. System shell surfaces — the lock screen, the Dock, one-shot dialogs, Shifu's own UI, bundle-less `unknown.<pid>` processes — never enter the ledger at all (`TaskGrouper.isSystemBundle`, applied where `LedgerBuilder` writes blocks; `v26-system-shell-purge` removed the rows written before that gate): they carry no topic or domain, so they'd bottom out at the `app:` key and mint permanent nonsense tasks ("loginwindow") that accrue time daily and never go stale — and keeping them out of `activities` keeps them out of grouping, the Time page (§7), and every query added later, by construction. Browser-internal pages get the same treatment one level down: a block's domain derives from http(s) URLs only (`Sessionizer.domain`), so `chrome://`/`chrome-extension://`/`devtools://` surfaces ("new-tab-page", "contextual-tasks", "omnibox-popup.top-chrome", extension ids) never mint `domain:` tasks — the dogfood ledger had 145 min filed under "contextual-tasks" — and prune reaps pre-gate ones on sight (`TaskGrouper.isBrowserInternalHost`), a rename again being the only shield. Tasks span days (the key recurs), are renameable, and renames survive re-analysis (keys never overwrite names, and the semantic pass never overwrites either).
- **Work logs**: one compiled log row per task per local day (`task_logs`): duration plus a "where — what" line ("Xcode, github.com — debugging capture daemon"). Rebuilt idempotently for every day an analyzer window touches; `private` time never becomes a task.
- **Day notes come in two tiers** (vault-features.md §2.1). A day whose *dominant* category is work or learning earns a `## Notes` document alongside its session bullets — what was worked on, what was learned or decided and why, problems paired with their fixes. Every other day keeps the short form. Dominance rather than presence is the test, so an afternoon of admin with twenty minutes of reading in it stays light. Both prose sections carry across an unchanged-day rebuild; carrying only the bullets would silently delete `## Notes` and the hash gate would then never regenerate it.
- **Per-task overview document**: one living Markdown file per task under `vault/tasks/<slug>.md` (`kind: task_overview`), rewritten in full whenever the task's *completed* days change — Status / Timeline / Key knowledge / Open threads. A three-week task has twenty day notes and nowhere that says what it *is*; the day notes are the diary, this is the documentation. Gating on completed days caps it at one generation per task per day however often the analyzer runs. Its own frontmatter kind is what keeps a compiled document out of the review queue.
- **Themes** (replaced projects, v14): the broad initiatives blocks cluster into (`ThemeClusterer`), which is also what the user files a task under by hand. Filing is per block, so a task's theme is the one its time mostly sits in; filing one from the Task log writes all of that task's blocks and sets `theme_user_set`, the bit prune and auto-merge read as "the user judged this". A theme's tasks also form a review deck (§5.2).
- **The Task log page** shows today's compiled log (most recently worked task first) and the task list with its latest log line. Themes get their own page beside it, and vault search a third (*Scrolls*) — the old Vault tab's segmented toggle became three stations on the trail (§7).
- **Task log filters**: a filter bar pinned above the log — range (today / 7 days / 30 days / all time), minimum time spent (default 5 min+), order (most recent / most time), and theme (all / one / unfiled). The range doubles as the window the time column counts, so a row's hours always match the range on screen. The section header carries "N of M" because the list is capped at 50 rows: a roster runs to hundreds of tasks, most of them a stray minute, and a capped recency-sorted list looks identical under every range without it. Minimum time and theme also scope the *Today* day log; range and sort don't — that log is already a single day, and its most-recent-first order is part of what makes it a log rather than a task list. The *Cards* deck picker still reads the unfiltered roster. Session state, not persisted.
- **Task detail page**: every task row opens as a full dashboard page (`TaskDetailView`): the LLM gist of what the task *is*, the **Overview** document above the history, day-by-day history with the work-note narratives and their `## Notes` sections (§2.1 of vault-features.md) expandable inline, where the time went per source, the knowledge notes captured under the task, recent activity blocks, inline rename, theme assignment (including creating a new theme in place), and the **Create flashcard deck** button (§5.2) — or the deck's live card count once one exists.
- **Themes — the second clustering mode**: `ThemeClusterer` runs an *independent* LLM clustering of the same blocks into 3–8 broad initiatives spanning weeks ("YC Startup School", "Shifu development", "Travel") — one level above tasks, assigned per block (`activities.theme_key`, `"thm:"` namespace), so a task's blocks may straddle themes. Same engine discipline as semantic tasks: roster reuse (30-day window), confidence floor, `theme_attempts` cap, rebuild carry, fail-soft. Each theme keeps an LLM **running narrative** ("the story so far"), regenerated only when the hash of its *completed* days changes — at most one generation per active theme per day. Themes get their own page on the trail, beside the Task log (§7); a theme's page shows the narrative, computed per-day history (no parallel log table — days derive from `theme_key` on read), the tasks its time flowed through (linking to their pages), and recent activity. **Themes are authored by the user, suggested by the model** *(revised 2026-07-28, v17)*: the clusterer files blocks into themes that exist but can no longer found one — an initiative it invents lands in `theme_proposals` and renders in a **Suggested themes** section below the grid, with the hours and block count behind it, as Add / Dismiss. Accepting mints the theme *and* files the recorded blocks, so it is never a named empty box; dismissing is permanent (unique `key`), and so is deleting, which unfiles the theme's blocks, burns their `theme_attempts`, and records the key as dismissed so it can't be proposed straight back — the time itself stays in the ledger. Themes are renameable and their gist editable in place; the key never moves, so renames keep the history. The original design let the clusterer mint themes silently: the grid then filled with the model's carve-up of the user's life faster than anyone could correct it, which is exactly backwards for the one layer that is supposed to be the user's own.

---

## 6. Efficiency & Automation Radar (§2 of instructions)

**The unit of automation candidacy is the task.** The first version of this
section mined labels — domains and bundle tails — out of activity sequences,
and the tab it produced was uniformly useless: "google.com visited 255× → set
up Google Analytics 4", "Chrome→Reddit sequence → write Puppeteer scripts,
10–15 h setup" to save 15 min/week. Labels name *containers*, and a container
holds every kind of work at once, so no describer downstream can say anything
true about one. Tasks (§5.3) already name what the user was doing, their day
logs already carry recurrence, and their blocks carry the schedule, the
sources and the samples. So the miner ranks tasks; the LLM judges them.

### 6.1 Candidate miner (deterministic)

Runs weekly over a 14-day window and builds an in-memory **dossier** per
candidate. Two kinds:

- **`task`** — a task with ≥3 active days and ≥20 minutes in the window, or
  ≥2 days and ≥1 hour: the second door exists because the intent-level `sem:`
  layer is by nature the youngest thing in the database, and a three-day bar
  alone leaves the tab empty for a fortnight after every fresh install. Both
  numbers are counted from the task's *blocks*, not its day logs — a merge
  repoints activities without rewriting older logs, so the logs are the cheap
  sieve and the blocks are the verdict. Only keys that *name intent* qualify:
  `sem:` (the LLM's goal-level title) and `topic:` (the classifier's
  description of the ongoing task). `app:` and `domain:` keys mean nothing ever learned what the work
  was — on the dogfood ledger they are also the heaviest rows, so they are
  filtered in SQL, before the ranking spends its budget on them. Also dropped:
  tasks whose *time-weighted* dominant category is entertainment, social,
  private or unclassified (communication and admin stay — mail triage is
  exactly the chore worth automating), and system shells, which never join a
  task any more but survive in old rows.
- **`polling`** — one domain opened ≥10×/day for under 2 minutes a visit: the
  alerting gap. The only non-task kind, because by construction those glances
  never accrue the minutes to mint a task. Search engines are excluded (they
  are visited briefly and constantly by definition — that structural bias is
  what put google.com at the top of the old tab), as are browser-internal
  pseudo-domains (`chrome://new-tab-page`, `*.top-chrome`) and glances that
  are already filed under a task candidate: the work has a name, so the
  suggestion should be about the work. That last test is per *block*, not per
  domain — `github.com` can hold a week of real work and, in the same
  fortnight, 150 refreshes of an unrelated repo.

The dossier carries: name and gist, days active, minutes, a plain-language
**schedule line** ("weekday mornings, usually 9–11" — regularity is itself an
automation signal, and a thing that happens every weekday at 9 can be
*scheduled*), top sources with minutes, the recent `task_logs` summaries,
≤4 sampled window titles and a ≤300-char text sample spread across the whole
window, plus derived **signal** lines. Rapid A↔B alternation with
copy-adjacent dwell times — the old "manual transfer" detector — survives only
as one of those signals: on its own it said "you switched between Chrome and
Terminal a lot", which is not a workflow; attached to a task it says what the
user was moving by hand.

At most 12 dossiers per run (3 slots reserved for polling), ranked by observed
minutes: a cap on LLM spend, and on the queue a human has to read.

### 6.2 Opportunity describer (LLM)

Each batch of dossiers goes to the reasoning model with framing ("most habits
are fine — say no"), a **named tool catalog**, honesty rules, and the evidence
above. The catalog is the part the old prompt lacked entirely, and without it
the model reached for whatever automation advice was common in its training
data: Claude Code (terminal agent — scripts, data and file chores, API glue,
schedulable with cron/launchd); claude.ai / Claude Desktop (Projects, MCP
connectors to Gmail/Drive/Calendar/Notion/GitHub/Slack, scheduled tasks);
Claude in Chrome (repetitive web workflows with no API); OS-native automation
when the job is deterministic (Shortcuts, AppleScript, launchd, Hazel,
Keyboard Maestro); alerting instead of polling. Claims must be grounded in the
evidence shown — never an invented data source, file or account.

The answer is `verdict` (yes/partial/no), `title`, `suggestion` (2–4 grounded
sentences: what the workflow is, which tool, and the first concrete step),
`setup_minutes`, `saved_minutes_weekly`, `teach` (one sentence naming a
capability the user may not know exists — teaching AI tooling is half the
point of the tab) and `confidence`.

**Gates run in code, not in the ranking.** Confidence used to scale rank only,
which meant everything shipped and the weak ones merely shipped lower. Now:

- The claimed saving is **clamped to the minutes actually observed** — "ground
  every claim in the evidence" is a prompt rule, and prompt rules are requests.
- Verdict `no`, confidence < 0.6, or a payback failure
  (`setup_minutes > 4 × saved_minutes_weekly`) **auto-dismisses** the row at its
  current recurrence, and stamps a re-ask date 90 days out. A user's dismissal
  is permanent until the habit doubles; a *model's* is an opinion, and for a
  task — where recurrence is days active inside a 14-day window — doubling is
  unreachable above 7 days, so without the date a model's "no" would be
  forever. Either way the row returns *undescribed*, judged fresh.
- A `yes` that omits the numbers the gates need is neither accepted nor
  dismissed: the row stays pending and is asked about again next week. A
  formatting slip must not bury a real suggestion.
- Once a row *is* described, its evidence line, sizing and rank freeze
  together. Recurrence keeps tracking the fresh mine (the dismissal memory
  reads it), but refreshing the caption under an already-written suggestion
  would leave the evidence arguing with the advice above it.

Prompts are batched by rendered-token size (invariant 7), never by item count.

- Suggestions appear in the digest and on the *Radar* page, ranked by
  `saved_minutes_weekly × confidence` — the model's grounded estimate, which
  overwrites the miner's mechanical "minutes at stake" on the way in.
- **Only described rows are ever shown.** A mined row is evidence, not advice;
  with no backend configured the tab is empty rather than full of raw counts.
- The tab is honest about numbers: "saves ≈45 min/wk (est.) · setup ≈30 min",
  never a bare promise.
- Dismissals are remembered; a dismissed candidate resurfaces only if its
  recurrence doubles.
- **Copy** puts a brief on the clipboard — the workflow, the observed
  evidence, the assessment, and an instruction to interview the user before
  building. Direct handoff ("Open in Claude", a `shifu radar draft` CLI) stays
  deferred (§12).

---

## 7. User Interface

Shifu is a full desktop app with a menu bar companion, and it is not a window that shows a place — it **is** the place. One mountain fills the window edge to edge: a stair of stone terraces climbing left to right, a temple on every terrace, and the whole app laid out along it. Changing places does not swap a screen; it flies the camera to another terrace, and Shifu hops up the steps to meet you there. The metaphor the product already runs on — a path, a climb, a guide who has been up it — is the interface, not decoration on top of one.

**The artwork** is flat 2D vector, drawn entirely in `Canvas` — no bitmaps, no image assets, so every surface is resolution-free and themable from a palette. Nothing in the scene ticks on its own: parked, the world is a still image, which is the bargain an app you leave open all day has to make.

- `ShifuApp/World.swift` — **the map**, and the single source of truth for it. Seven stations 700 world units apart, each 150 units higher than the last, joined by flights of four broad treads. One list of flat runs feeds the silhouette, the lit tread tops, and where Shifu puts his feet, so what you see and what he walks on cannot disagree. It also carries the `Camera` (a world point and how many units of height the window shows), the `Projection` that turns world into screen, and the procedural ridgelines — sampled straight from world x, so a range is endless in both directions and never has to be tiled.
- `ShifuApp/WorldStage.swift` — **the painter**. Sky, sun or moon, stars or birds, clouds, three ranges at rising parallax, the terraces, the temples, Shifu, and a near bank in front of him moving faster than anything else. Background ranges attenuate the camera's travel but keep their size, and take only a fraction of its climb — a literal vertical parallax would drop the whole range off the bottom of the frame two terraces up, and the point of climbing is to watch the horizon sink slowly, not to lose it. The view is `Animatable` on the camera, so a move between terraces is interpolated frame by frame by SwiftUI itself; the drawing reads *travelling* off how far the live camera is from either end of the leg, which is what keeps the mid-flight pull-back and Shifu's gait in step with the animation curve without a timer.
- `ShifuApp/WorldLandmarks.swift` — what stands on a terrace. Five parts — stacked pagoda roofs, a vermilion gate, standing stones, a banner, a beacon — in fixed slots, combined differently per place: seven distinct silhouettes without seven drawings. The tiers climb with the mountain, so the skyline tells you how far into the app you are before you read a word.
- `ShifuApp/SenseiView.swift` — **Shifu himself**. Not a person, and deliberately not the same medium as the world behind him: a **16 × 16 pixel sprite** of a small creature in a tied terracotta headband. Blocky, six colors, and completely static — mood is carried by the face (`watching` while capture runs, `resting` with a `z` while paused, `proud` when a queue is cleared), never by motion. The grid is the drawing, so one render is a few dozen rectangle fills: a sprite costs nothing to leave on screen, which is the whole point in an app you keep open all day. He stands on the front dune's crest wherever the scene appears — Today's hero, onboarding, empty states, the app icon — and a crisp sprite against a soft vector landscape is the composition, not an accident.
- `ShifuApp/DayTrail.swift` — today drawn as **stepping stones**, one per hour, sized by how much of that hour the ledger holds and colored by what most of it was, laid along a climbing route with Shifu standing on the last stone. Same numbers as the Time page's bars, told as a walk.

**The Dojo design system** (`ShifuApp/Dojo.swift`, `DojoChrome.swift`) sets everything that isn't the painting: rice-paper surfaces in light, cool slate in dark, and one terracotta accent — the headband. Pages sit on `dojoPanel` — a material with a paper wash over it, so the world's colour and the hour's light reach the room without the landscape ever competing with a column of numbers. Three type registers and no more: SF at display weight (`Dojo.display`) for titles and hero numbers, where weight alone carries the hierarchy; uppercase tracked SF Mono (`Eyebrow`) for section labels, units, and ticks — the terminal register that says "this is a log"; and the plain system face for everything you actually read. The mentor's aphorisms (`Wisdom` — original lines, not quotes) get a system italic. Minimalism still governs (§1, principle 2): generous whitespace, no gamification, badges only where a number is actionable (cards due, radar suggestions), no settings page longer than one screen.

- **Menu bar item** (the always-visible surface): Shifu's own face, rendered from the vector figure rather than an SF Symbol — awake while watching, asleep while paused. Focus Mode toggle, "Review · N due", "Today: 4.2 h work · 1.1 h learning", Pause 1h / until tomorrow, Open Shifu, Settings, Quit.
- **Main window**: the mountain, full-bleed under a hidden title bar, with two things over it. There is no sidebar — the places hang in the sky on the left as stations on a dashed switchback (`TrailRail`), lowest first: *Today* at the foot, then **The path** (*Time*, *Themes*, *Task log* — §5.3), **The mind** (*Practice* — §5.2 — and *Scrolls*, vault search — vault-features.md §4), **The watch** (*Radar*) at the summit. No panel behind them, only a wash of the hour's own top-sky colour, which is the one band every palette already guarantees its ink reads against. Shifu's mark heads the trail; capture state, rest, Focus Mode, and the door to Settings sit at its foot. Charts native SwiftUI; no web views.
- **Travel**: picking a station flies the camera along the mountain — pulling back at the midpoint so you see the whole climb, settling on arrival — while the page's scroll rolls up and unfurls again at the destination. It costs about 0.8 s, which is long enough to read as a climb and short enough never to feel like a wait. Every terrace wears its name carved into the cliff under its lip, drawn inside the world so the signs travel with the camera: the place you are heading for is legible from the one you are leaving.
- Every page except Today rides in a **scroll** — frosted rice paper over the mountain, inset on the right — and wears one `PageScaffold` inside it: region eyebrow, title, one line on what the page is for, and the page's own controls in the header's trailing slot. The camera aims at the middle of the gap the scroll leaves, so the terrace you travelled to is never the thing the scroll is covering.
- **Today**: the window *is* the hero. The camp terrace and Shifu stand in the open with the hour's sky behind a time-of-day salutation and the day's aphorism laid straight on the painting; a narrower scroll beside them carries the tracked-today total, the counts that want attention, the day's stones, and today's task log.
- **The Time page** carries one window (Day / Week) and one lens (Category / Theme / Task, §5.3) across two modes:
  - *Summary* — where the time went. A hero total with its change against the same window before it, a donut, and one row per group: color, name, duration, share, a proportional bar, expanding into the apps and domains inside it, its block count, and the hour it peaked. This is what makes "3 h 10 m of today was work, and 40 m of that was Chrome" a thing you can read at a glance.
  - *Timeline* — when it happened. Stacked bars over the hours or days, plus the block list. Its legend carries each group's total, so the strip under the chart is a breakdown rather than a color key.
  - A group wears the same color in both modes. Every chart hue comes from the eight `Dojo.chartSlots`, validated for color-vision-deficiency separation (adjacent ΔE ≥ 12) and ≥3:1 contrast on both surfaces, with light and dark steps chosen separately. Category hues are fixed — work wears the accent terracotta — while theme/task hues come from a stable hash of the name so a theme keeps its color as the window changes. Past the top 7 groups everything folds into "Other" rather than growing the palette.
  - **System shells are not charted.** The reads behind the page (`LedgerBuilder.labeledActivities` and `.totals`, so Today's rings, the menu bar's hours and the digest agree with it) have no system-shell rows to count: `rebuild` never writes a block for one (`TaskGrouper.isSystemBundle`, §5.3), and `v26-system-shell-purge` removed the rows written before that gate. The lock screen, the Dock, auth prompts and Shifu's own UI are not groups any lens can name, and charting them puts hours on screen that the Task log has no row for. Not a rounding difference: the dogfood ledger held 849 h of `loginwindow`, enough that opening Time on one of those days showed nothing else at all.
- **Review session**: minimal card interface (see §5.2), also openable as its own small window from the menu bar.
- **Onboarding** (`OnboardingView.swift`): six beats — (1) what is and isn't captured, (2) the two permissions the daemon needs (Accessibility, Screen Recording), (3) what stays unseen (password managers, banking, private browsing, redaction), (4) whether a model may be consulted (rules-only is the default, and the cloud options are never preselected, §8), (5) what Focus Mode's nudge actually does, (6) what the first hour, day and week fill in.

  It is drawn as **the window it hands you**: a rail listing the six beats on the left, the page on the right, in a fixed 660 × 460 panel centred in the window. First run is the one place a permanent source list can be taught rather than discovered — the rail ticks off what is behind you, takes you back to any of it, and its foot carries the beat's promise and then, on the last two beats, the two things that live there for the rest of the app's life: the Focus Mode switch and the capture line.

  Beat five carries the **nudge demonstration** (`NudgeDemo.swift`): "Show me the nudge" hands the whole screen to one real glow pulse, with a bar along the bottom naming each phase against the ten-second gap the daemon enforces after it, then hands the window back. It takes the screen because what is being consented to is a full-screen event — a thumbnail would answer "what colour is it" and leave "how much of my attention does this take" to the first unannounced firing. The pulse's phase durations, vignette grade and line size come from `FocusNudge` (ShifuCore), which is also what `shifud`'s `GlowOverlay` animates, so the demonstration cannot drift from the thing it demonstrates. Running it turns nothing on: Focus Mode stays where the user left it, and no session is logged.

---

## 8. Privacy & Security

This section is load-bearing; a screen watcher lives or dies on trust.

- **Local-first capture, forever.** Raw observations never leave the device. LLM analysis goes to DeepSeek, but it is text-only, post-filtering and post-redaction, clearly labeled in settings, and inert until the user's affirmative act — **the opt-in is explicit and defaults to off**. With their own API key, pasting the key is the opt-in. With the hosted Shifu Cloud backend there is no key to paste, so the choice itself is the opt-in: never preselected, stated in onboarding and Settings with exactly what is sent (derived, redacted, post-exclusion text samples) and to whom (Shifu's proxy, forwarding to DeepSeek — an AI provider based in China). "Rules only" turns it off entirely.
- **No pixel persistence.** Screenshots exist in memory only for the OCR call in the default configuration. (A debug flag can retain them, visibly indicated in the menu bar.)
- **Exclusion list**, enforced in the daemon *before* capture (not filtered after):
  - Default-excluded apps: password managers, Keychain, system auth dialogs.
  - Default-excluded domains: banking/financial category list, health portals; user-editable.
  - Private/incognito browser windows: always excluded, not configurable off.
  - Regex redaction pass over all extracted text for credit-card numbers, SSNs, and obvious secrets (`AKIA…`, `-----BEGIN`, JWT shapes) before anything touches disk.
- **Encryption at rest**: SQLite via SQLCipher; vault folder optionally encrypted (off by default since users may want Obsidian interop — the tradeoff is stated plainly in settings).
- **Retention**: raw text 14 days (configurable 1–90); ledger aggregates and confirmed notes indefinitely; one-click "delete everything," and a date-range delete ("forget this afternoon").
- **Pause semantics**: pause = the AX observers and event taps are torn down, not just ignored. The menu bar glyph makes state unambiguous.
- **No network access in shifud at all** — only the analyzer can touch the network, and only to the configured LLM endpoint (DeepSeek directly, or the Shifu Cloud proxy) once the user has opted in. Enforced via separate binaries so this is auditable.

---

## 9. Storage Layout

```
~/Shifu/
  shifu.db            # SQLite: observations, activities, patterns, suggestions, settings
  vault/              # Markdown knowledge notes (portable)
    YYYY/MM/*.md      # knowledge notes: reference notes and deck cards
    work/YYYY/MM/*.md # per-(task, day) work notes
    tasks/*.md        # per-task living overview documents
  digests/            # daily digest archives (markdown)
  logs/               # daemon logs, size-capped
```

Key tables: `observations` (§3.5), `activities` (block, category, topic, confidence, task), `tasks` / `themes` / `task_logs` (§5.3), `decks` / `deck_suggestions` (§5.2), `rules` (user classification overrides), `suggestions`, `srs_reviews` (review log for FSRS optimization), `settings` (key/value user preferences), plus the disposable `vault_index` / `vault_fts` / `vault_vectors` search index — rebuildable from the Markdown, which is the source of truth.

User-tunable settings are declared once in `SettingsCatalog` (key, default, bounds, copy) and read through typed accessors that clamp on both read and write, so the daemon and the Settings UI cannot disagree about a bound. `shifud` applies interval changes live via `Daemon.reloadIntervals()` — a new daemon-consumed setting must add its own changed-guard there, or it will persist and render correctly but be ignored until restart. Focus Mode's distracting-site list is deliberately *not* in `rules`: it drives the glow only, leaving ledger categories untouched. Raw-text retention is a catalog setting too (`privacy.text_retention_days`, 1–90, default 14) and the analyzer reads it on every run, so shortening it takes effect at the next scrub rather than at the next release.

**Settings is one place with a rail of its own** (`SettingsView`): the `SettingsSection` cases *are* that rail, in declaration order, and each carries its own summary and the one guarantee that governs it. This is what keeps §7's "no settings page longer than one screen" true now that the analyzer alone has nine dials. Three columns: sections, the section's rows — every control landing on one right-hand edge, so the page reads as a panel of dials rather than a form — and, on a window wide enough for it, a column of **measured** readings (`SettingsDiagnostics`: today's captures split by ladder rung, what the LLM sent, database size). Nothing in that column restates a setting; it exists to answer "is this actually working", which is the one question a settings screen normally cannot. It deliberately does *not* report the daemon's TCC grants: `shifud` is a separate binary with its own identity and this process cannot read them, and a green tick we cannot see would be the one lie on the page whose whole job is to be believed.

Exclusions (§8) are not settings — they live in the `exclusions` table, merged with the hardcoded defaults at capture time — but the Privacy section is where they are edited, and `Exclusions.add/remove/userValues` is the only writer. Adding something already built in is a no-op rather than a row, so nothing in the user's list carries a "remove" that would not actually remove the exclusion.

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
| **M2 — Brains** | local LLM classification + topics; daily digest; Focus Mode + glow | Ambiguous-block accuracy spot-checked >85%; glow works and is likeable |
| **M3 — Vault** | user-requested decks (suggested + manual), FSRS review UI + CLI | Every deck the user accepts is one they still want after reviewing it. (The predecessor — automatic extraction into a triage inbox — failed this at 1,162 proposals to 1 kept card and was removed.) |
| **M4 — Radar** | pattern miner + suggestion describer, Radar tab | ≥1 genuinely useful suggestion per week of dogfooding |
| **M5 — Hardening** | SQLCipher, retention jobs, onboarding, perf test suite, notarized build | Clean install → useful digest with zero config |

---

## 12. Future Directions (explicitly out of v1)

- **The rest of the Settings readings column (§9)** — the design it was built
  from also shows daemon uptime, CPU and RSS, the last analysis time, the
  daemon's own Accessibility/Screen Recording grants, and a preview of the last
  payload sent. All four need something that does not exist: a heartbeat row
  `shifud` writes with its own pid and grant state (the app cannot read another
  binary's TCC), a stamp the analyzer writes on every run, and a retained
  sample of the last request body — which is a new place redacted text would
  sit on disk and wants its own retention decision before it is built. Today's
  capture split is the honest proxy for all of them and cost nothing new.
- **Redaction counters on the Privacy row (§8)** — the design shows KEY/JWT/
  CARD/PEM hit counts beside the choke point. `Redactor.redact` returns only
  the redacted string; counting means a per-pattern tally threaded out of the
  hot write path and somewhere to accumulate it. Worth doing when there is a
  reason to doubt the patterns, not before.
- **Export and delete-everything from Privacy (§8)** — `DeletionTools` already
  backs `shifu forget`, so this is a UI affordance over existing machinery.
  Deliberately not wired to a button yet: irreversible bulk deletion wants a
  confirmation design (what exactly goes, what survives, how it is undone) that
  is more work than the button.
- **One "Models" row instead of two (§9)** — the design pairs the fast and
  reasoning model fields under a single label with sub-captions. Better
  reading, but it means the Settings page stops being a pure render of
  `SettingsCatalog` and starts hand-arranging keys, which is the property that
  makes adding a setting free. Wants a `group:` on `TextSetting` first.

- **Retry backoff for LLM attempt credits (§4.2)** — attempts are spent on
  consecutive eligible runs until the cap (3). A backoff (next run, +4h, +24h)
  would spread them, but the closed-block gate plus the cap already bound the
  waste to two extra calls per stubborn block; not worth a timestamp column.
- **Cross-run prompt-cache alignment as its own effort (§4.2)** — the ordering
  wins are taken: rosters render in stable key order, `CardBuilder.ongoingTopics`
  in slug order, and the task-overview prompt puts the overview it is revising
  *after* the day notes rather than ahead of them (it is rewritten every pass,
  so anything behind it was a guaranteed miss). What is left is the part that
  costs something to keep: the roster's per-task counters (`2.4h over 3d · last
  2d ago`) move hourly and sit inline with the names, so the byte-identical
  prefix still ends at the instruction header — splitting them into their own
  section after the stable name/gist block is the fix. Alongside it, the
  grouping and clustering prompts append their output-format spec *after* the
  block list, where it can never be cached. Measure both against the per-stage
  attribution below before spending anything on them; note also that input is
  only worth chasing once thinking mode is off the fast slot — with
  chain-of-thought billed as output, input was under a fifth of the bill.
- **Per-stage attribution in `llm_usage` (§4.2)** — *done, v27.* The table
  recorded what each response cost but never what it bought, so "which stage
  is expensive?" could only be answered by lining rows up against the order
  main.swift runs its stages — an inference that batching, truncation retries,
  `LLMStageGate` skips, fail-soft throws, and the second process `--build-deck`
  starts each break independently. `llm_usage.stage` is now stamped by the
  backend handle each stage is handed (`DeepSeekBackend.labeled`), and
  `shifu status` prints the split beneath the per-model lines. The label rides
  on the handle rather than through `LLMBackend.complete` because Swift forbids
  default arguments in protocol requirements: a `stage:` parameter could not
  have been added compatibly, and all twenty-odd conformers would have taken an
  argument only one implementation uses. Rows written before v27 stay NULL
  rather than `'unknown'` — they are the baseline the first before/after
  comparison is made against.
- **Card-fed light-tier work notes and radar/deck evidence (§5.3)** — cards
  could stand in for raw screen-text in the light day-note prompt and the
  weekly evidence dossiers. After the open-day throttle those stages are
  pennies a day, and bullets written from raw text read better than bullets
  written from gists — swap only if the meter says otherwise.
- **Feeding coalesced runs to `CardBuilder` (§5.3)** — the semantic grouper
  pools sub-minute slivers into runs; `CardBuilder` still holds the plain
  60 s floor, so a run goes to the model as raw titles/text rather than a
  card. ~105 runs per 48 h window makes that cheap enough to leave alone;
  revisit only if `llm_usage` says otherwise.
- **A separate last-resort floor for container minting (§5.3)** — the gate
  reuses `minNewTaskMs` (5 min of declined time). At 30 min,
  `google.com` / `github.com` / `mail` / `linkedin` would drop off the
  dogfood roster too, leaving ~5 rows — a one-constant change if the
  residue still annoys after dogfooding.
- **A "known source" guard for neighbour inheritance (§5.3)** — only
  inherit when the glance's domain/app is already one of the task's
  sources. Cuts 128 dogfood adoptions to 84, but it is a ratchet — the
  first block from a new app can never inherit, so the app never becomes a
  known source — and it re-imports the container logic the last-resort
  gate removes: intent tasks span apps by construction.

- **Cross-platform core**: extract sessionization/classification/SRS/mining into a Rust core with platform-specific capture shims (Windows: `Windows.Graphics.Capture` + UIA; Linux: wayland portals) — this is where Rust earns its place.
- Browser extension for exact URL + selection-level capture where AX falls short.
- Calendar/task integration to label blocks with intended work ("was I doing what I planned?").
- Audio-free meeting awareness (detect meeting apps, log attendance time, never record content).
- Vault embeddings for semantic search ("what did I read about SQLite WAL?").
- **Deck refresh / regeneration (§5.2)** — a deck is built once and reaches
  `ready` for good. A task that keeps going accrues material the deck never
  sees, and there is no "add to this deck" or "rebuild it". Wants a decision
  about what happens to the cards already reviewed (keep their FSRS state,
  obviously) and what stops a refresh from re-proposing what the user pruned.
- **Re-suggesting declined or dismissed tasks (§5.2)** — both verdicts are
  permanent by design, which is what stops the weekly probe re-billing the
  same answer. The task page's Create button is the escape hatch, so this is
  only worth revisiting if the suggester's judgment visibly improves.
- **Theme-scoped decks** — a deck is one per task. A theme spans tasks and is
  often the more natural subject ("YC Startup School"), but its card set moves
  as the clusterer refiles blocks, which a persisted deck doesn't.
- **A "high priority" tier for day notes (§5.3)** — the tier is the day's
  dominant category. A day flagged as important by the user would earn the
  long form regardless, but there is no such flag yet.
- **Migrating pre-deck cards into decks** — kept cards from before §5.2 carry
  no `deck:` and only ever appear in the All queue. Grouping them by task key
  would be mechanical; whether it is *wanted* is the open part.
- **Per-deck review stats** — the review-activity heatmap is vault-wide. The
  *forecast* is not: the shelf rows carry a per-deck week (above). What is still
  missing is the deck page's own version — a full four-week band scoped to one
  deck, which `ReviewForecast.build` would already produce.
- **Deck follows a task merge (§5.3)** — `decks.task_key` is not repointed
  when a task is absorbed, and prune/merge leave the deck row behind for the
  `decks()` JOIN to hide. The cards keep serving the All queue either way, so
  this is a tidiness fix plus a re-attach for the orphaned rows.
- **Overview-file cleanup on task prune/merge** — `vault/tasks/<slug>.md`
  files for dead tasks are left in place. The vault is user-owned Markdown and
  the eligibility query simply stops touching them, but nothing reaps them.
- **A vault snapshot for `mergeIfDuplicate`** — it is O(vault) per candidate,
  re-walking every note per reference-note write. Fine at current scale
  (thousands of notes, eight candidates a run). Deck writes already avoid it
  by deduping through `vault_index.deck_key`, which is O(deck).
- **Radar handoff beyond the clipboard (§6.2)** — an "Open in Claude" button
  and a `shifu radar draft <id>` CLI verb that pipes the brief straight into a
  Claude Code session. Declined 2026-07-28 when the tab was rewritten:
  clipboard-only, with a *rich* brief, does the same job with no launch-path
  guessing, no second window, and nothing to keep working across Claude Code
  releases. Revisit if the brief turns out to be routinely pasted unchanged.
- **A Shifu MCP server** — expose the ledger (tasks, day logs, sources,
  themes) to the user's *own* Claude, so an agent asked to build the
  automation can query the evidence itself instead of being handed a
  paragraph. The natural successor to the clipboard brief; also the first
  thing in Shifu that would serve data to a process it doesn't control, so it
  needs a privacy story first (§8).
- **Adoption detection for radar suggestions** — a suggestion is "done" when
  the pattern it described stops recurring. The miner already recomputes
  recurrence weekly, so this is a comparison, not a new signal; what it needs
  is a decision about what the tab does with it (quietly retire the row, or
  say "this dropped from 11×/day to 2 — nice"). Would also give M4 a
  measurable outcome instead of a self-reported one.
- **An "automation review" section in the daily digest** — the digest lists
  the top three radar titles today; the richer version would carry the teach
  line and setup sizing so the digest can be read away from the app.
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
  cloud quality at ledger-scale batch sizes. **Measured 2026-07-31 (base
  M4/24 GB, llama.cpp, 16k window, thinking off): that condition is now
  arguably met.** Qwen3.5-9B (Q4, 5.7 GB weights, 6.1 GB server RSS) ran the
  full pipeline end to end — 48h catch-up in 18.8 min, 89% (32/36) card
  category agreement with a same-state DeepSeek run, grouping spread over
  sensible tasks, minted titles at the intent-level bar. Qwen3.5-4B is
  feasibility-fine (31.8 min, ~3.5 GB — inside an 8 GB Mac) but its grouping
  verdicts destabilize on 60-block batches; capping batches at 24 blocks
  (§5.3, measured) brings its replay stability to parity with the 9B. The
  reopening path: the §4.2 local profile ships the power-user shape today
  (llama-server); a native MLX backend in shifu-analyzer is the release
  shape, gated on the user's blind dogfood week (title quality — the one
  axis agreement numbers don't settle) and on re-measuring prefill under
  MLX before any code.
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
- **Human-observer priors for task grouping — the deferred half.** A human
  watching someone work groups it better than the pipeline does, and the
  mechanisms are nameable: a *weighted* prior over known tasks (with reserved
  mass for "this is new"), *stickiness* (whatever was happening a minute ago
  probably still is), *retrospective revision* (re-reading ambiguous evidence
  once later evidence lands), *intent-proximal evidence* (dynamics, not
  snapshots), and *the ability to ask*. Shipped 2026-07-28 in §5.3: the
  weighted roster, fenced stickiness, spread evidence sampling, and page
  identities. Still deferred, roughly in value order:
  - **Dormant-task recall** — candidate-driven retrieval past the 14-day
    roster cliff: match a batch's domains/topics against all-time task sources
    (SQL join, or generalize `TaskMerges.activeTaskData`) and inject the top-k
    as "Dormant tasks (resume if continued)". Monthly recurrences currently
    re-mint duplicates instead of resuming.
  - **Interruption annotation (no LLM)** — sandwich detection over the tiled
    timeline: middle block short (≈≤5 min, threshold tuned on the dogfood DB),
    category social/communication/entertainment or task-less, same task on
    both sides, contiguous tiling (an idle hole is a *break*, not a
    distraction) → link it to the task it interrupted (`interrupted_task_id`,
    or compute-on-read in the Time tab first, no migration). Gives
    interruption counts and focus fragmentation per task, and a natural Work
    Mode metric later. The grouper's fence keeps these blocks *out* of the
    task; this is what would record that they happened *during* it.
  - **End-of-day revision sweep** — one extra batch re-offering omitted /
    low-confidence blocks (`sem_attempts > 0 AND sem_key IS NULL`) with the
    day's final task list as hindsight. Inference today is forward-only
    filtering; humans smooth.
  - **Unified roster** — offer recent *mechanical* tasks (`topic:`/`domain:`/
    `app:`) in the semantic roster, marked as such, so the semantic layer
    absorbs them instead of duplicating them (cleanup falls to weekly merge
    suggestions today).
  - **Corrections as memory** — store rename/merge/assign events as
    (evidence → task) exemplars and inject the top-k relevant into prompts;
    needs the missing per-block "belongs to task…" correction path (no
    `source='user'` write path exists, and the `rules` table has no writer).
    Highest long-term value, and product-level rather than analyzer-level.
  - **Ask-when-uncertain** — at most one menu-bar question a day about the
    biggest unresolved cluster; answers feed the correction memory above.
    (`shifu log` is the proactive twin that already exists.)
  - **Hierarchy context** — one line per active theme (the 30-day theme roster
    already exists) at the top of the grouping prompt.
  - **Engagement flag** (first capture-side change, needs a migration) — a
    boolean per observation from the `CGEventSource.secondsSinceLastInput()`
    the idle gate already reads. No event tap, no counts, no content;
    separates producing/reading from passive playback and gives "omit idle
    browsing" real signal.
  - **Document identity** — read `AXDocument` for document-based apps into a
    `document` column (basename + parent dir, path exclusions extended), so
    tasks anchor to artifacts ("thesis.tex" across weeks).
  - **Changed-text sampling** — prefer observations whose SimHash differs from
    their predecessor (the screen actually changed); a sampling-time filter on
    top of the spread sampling that shipped.
  - **Deliberately not**: keystroke/clipboard/input-content capture (hard
    non-goal, §1), event counting beyond the engagement boolean, and meeting
    content. Calendar integration stays deferred above; ask-when-uncertain is
    its cheap cousin.
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
  - ~~The `pause_until` expiry parse exists three times…~~ **Done.** Both
    control files are single-sourced in `ShifuCore/ControlFiles.swift`
    (`PauseFile`, `FocusModeFile`), each entry point taking an optional `home`
    so the format is testable without moving `SHIFU_HOME`. Closing it turned up
    a live bug: a file holding `inf` or an overflowing literal parsed to a
    non-finite expiry and pinned capture off forever, which is exactly what the
    past-expiry rule exists to prevent.
  - `Retention` is declared at the bottom of `Analysis/LedgerBuilder.swift`,
    where nobody grepping for the concept will find it. Move to its own file
    under `Storage/` next to `DeletionTools`, which shares its concern.
  - `ShifuApp/LedgerStore.swift` is the app's single read model for pause,
    vault, tasks, themes, decks, radar, and search, with ~16 repetitions of
    `try? db()` swallowing errors into empty state. It has since been split
    across `LedgerStoreDecks/Vault/Controls.swift`, but only for SwiftLint's
    length limits — it is still one type. Feature-scoped stores would help,
    but the UI layer has no test coverage, so this waits for a reason beyond
    tidiness.
  - `Tests/ShifuCoreTests/ShifuCoreTests.swift` is still the 6-line
    `swift package init` placeholder.
  - Do **not** "clean up" `shifu-cli/VaultBench.swift`: `scripts/perf-vault.sh`
    invokes `shifu vault bench` and parses its output, so deleting it breaks
    `make perf`.

---

## 13. Open Questions

1. Should the heartbeat interval adapt to category (e.g., 30 s during `work` for finer ledger resolution, 5 min during `entertainment`)?
2. ~~Local model choice: Apple Foundation Models framework (zero bundle cost, OS-version-gated) vs. bundled MLX model (~2 GB, works everywhere) — ship both with runtime selection?~~ Resolved 2026-07: neither. Foundation Models shipped first and lost on its 4k window, weak labels, and macOS 26+ gate; both on-device paths were dropped for DeepSeek (`deepseek-v4-flash` default) as the sole backend (§4.2). *Reopened 2026-07-31 with different candidates and a measured go (§12): Qwen3.5-9B at a 16k window matches DeepSeek on cards (89%) and groups plausibly on Apple Silicon ≥16 GB; the 4B serves 8 GB Macs under the 24-block grouping cap. Model choice by `hw.memsize`; Intel stays rules-only/BYO-key. Final ship gate is the user's blind week on task-title quality.*
3. Is glow-pulse enough for Focus Mode, or is an optional hard mode (block-list with confirm-to-continue) worth its complexity and adversarial feel?
4. Vault dedupe: how aggressively should near-duplicate knowledge candidates merge across days (same fact re-encountered is itself an SRS signal)?
5. Should `excluded` time still count toward the ledger as an opaque "private" category (better totals) or vanish entirely (better deniability)? Default proposal: opaque category, toggleable.
