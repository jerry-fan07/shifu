# Shifu — Architecture

Orientation for anyone (human or LLM) landing in this repo cold.
[design.md](design.md) is the *spec* — what Shifu should do and why.
This file is the *map* — where that lives in code, and how to change it safely.

---

## 1. Orientation

Shifu is five binaries over one SQLite database and one Markdown folder.

| Target | Kind | Role | Network? |
|---|---|---|---|
| `ShifuCore` | library | Models, storage, and every pure/testable rule. All 5 targets link it. | never |
| `shifud` | executable | Capture daemon. LaunchAgent, headless, runs for weeks. | **forbidden** |
| `shifu-analyzer` | executable | Batch analysis worker. Spawned hourly by `shifud`, or on demand. | only binary allowed |
| `shifu-cli` (product `shifu`) | executable | `log`, `status`, `pause`, `review`, `forget`, `vault`, `encrypt`. | never |
| `ShifuApp` | executable | SwiftUI desktop app + menu bar item. | never |

**The one architectural fact to internalize: there is no IPC.** No sockets, no
XPC, no message bus. The processes coordinate through shared state on disk:

- `~/Shifu/shifu.db` — one SQLite file, WAL mode, `synchronous = NORMAL`.
- `~/Shifu/pause_until` and `~/Shifu/work_mode` — two control files the daemon
  watches with a `DispatchSource` on the directory.

That is why `shifu pause` works with the daemon running as a separate process
under launchd, and why the menu bar app can show today's totals without asking
anyone. Every process opens the same database and reads.

Anything testable is pushed down into `ShifuCore`, which is why `ShifuCore` is
~60% of the Swift in the repo and holds most of the test coverage. `shifud` and
`ShifuApp` are deliberately thin: event wiring and views over `ShifuCore`
logic. Each still has a test target (`ShifudTests`, `ShifuAppTests`,
`ShifuCLITests`) — SwiftPM can test an executable target on macOS — because the
thin layer is where the capture ladder's *ordering* and the app's calendar
arithmetic live, and both are load-bearing. New pure logic still belongs in
`ShifuCore`; the executable test targets are for the wiring that cannot move.

```
Sources/ShifuCore/
  Models/      Observation, Activity, WorkTask/TaskLog  — GRDB records
  Storage/     ShifuDatabase (+ migrations), DatabaseKey, EncryptionMigrator, DeletionTools
  Capture/     ObservationRecorder (the write path), SimHash, DHash, BoundedLRUCache
  Privacy/     Redactor, Exclusions
  Analysis/    Sessionizer, RulesClassifier, CardBuilder, LedgerBuilder,
               SemanticTaskGrouper (+SemanticTaskEvidence), ThemeClusterer, TaskGrouper,
               TaskMerges (+TaskAutoMerge), PatternMiner (+PatternMinerEvidence),
               Radar (+RadarDescriber), DigestGenerator, Embedder
  LLM/         LLMBackend protocol + LLMTokens
               (DeepSeekBackend, the only implementation, lives in shifu-analyzer — invariant 1)
  Vault/       Note, WorkNote, TaskOverview, FrontMatter, FSRS, VaultStore,
               VaultIndexer, VaultSearch, TaskStore (+TaskMerging, TaskPrune),
               ThemeStore, DeckStore, CardCandidates,
               WorkNoteCompiler, TaskOverviewCompiler,
               DeckSuggester, DeckBuilder
```

---

## 2. The pipeline, end to end

Two processes, two halves. `shifud` only ever does the left half; everything
right of `observations` happens in `shifu-analyzer`.

```
        ┌──────────────────────── shifud (continuous) ────────────────────────┐

  screen ──▶ Daemon ──▶ CaptureEngine ──▶ ObservationRecorder ──▶ [observations]
             events      capture ladder    redact · cap · dedupe
                         + exclusions

        └─────────────────────────────────────────────────────────────────────┘

        ┌────────────────── shifu-analyzer (hourly, batch) ───────────────────┐

  [observations] ──▶ Sessionizer ──▶ RulesClassifier ──▶ [activities]
                     (LedgerBuilder orchestrates all three)
                            │
                            ├──▶ CardBuilder ──▶ LLM ──▶ [activities].card (+relabels)
                            │
                            ├──▶ SemanticTaskGrouper ──▶ LLM ──▶ [activities].sem_key
                            │                                    [tasks] created w/ gist
                            │
                            ├──▶ TaskGrouper ──▶ [tasks] [task_logs]
                            │
                            ├──▶ ThemeClusterer ──▶ LLM ──▶ [activities].theme_key
                            │                               [themes] + narratives
                            │
                            ├──▶ DeckBuilder.drainPending ──▶ vault/**.md (deck cards)
                            ├──▶ WorkNoteCompiler   ──▶ vault/work/**.md (per task-day,
                            │                                             two tiers)
                            ├──▶ TaskOverviewCompiler ──▶ vault/tasks/*.md (per task)
                            │
                            ├──▶ VaultIndexer ──▶ [vault_index] [vault_fts] [vault_vectors]
                            │
                            ├──▶ PatternMiner ──▶ Radar ──▶ [suggestions]
                            └──▶ DeckSuggester ──▶ LLM ──▶ [deck_suggestions]   (weekly)

        └─────────────────────────────────────────────────────────────────────┘

        ┌────── shifu-analyzer --build-deck <key> (on request from the app) ──────┐

  [decks] claim (CAS) ──▶ DeckBuilder ──▶ LLM ──▶ vault/**.md (kept, FSRS-seeded,
                                                  `deck:`-stamped) ──▶ [decks] ready

        └─────────────────────────────────────────────────────────────────────┘

  reads: shifu-cli · ShifuApp (LedgerStore) · VaultSearch
```

### Left half — capture (`Sources/shifud/`)

1. **[Daemon.swift](Sources/shifud/Daemon.swift)** wires four event sources:
   `NSWorkspace` app-activation, AX observers for focused-window/title changes
   (debounced 500 ms), a 60 s heartbeat, and an idle check that suspends the
   heartbeat after 5 minutes without HID input.
2. **[CaptureEngine.swift](Sources/shifud/CaptureEngine.swift)** walks the
   *capture ladder* (design.md §3.2), cheapest rung first, and stops at the
   first that yields signal:
   - **Rung 0 — excluded.** Bundle on the exclusion list, private browser
     window, or excluded domain → record duration only, no content, return.
   - **Rung 1 — metadata.** No AX access → app bundle + timestamps only.
   - **Rung 2 — AX text.** Accessibility-tree extraction. Accepted when it
     yields ≥ `axTextFloor` (80) characters.
   - **Rung 3 — OCR.** Screenshot → dHash gate → Vision OCR. Only reached when
     rung 2 came up short. The dHash gate means a fullscreen video records
     *one* observation, not one per heartbeat.
3. **[ObservationRecorder.swift](Sources/ShifuCore/Capture/ObservationRecorder.swift)**
   is the single write path, and applies in order: drop text for excluded
   kinds → truncate to 8 KB → **`Redactor.redact`** → SimHash near-duplicate
   check → insert, or bump `last_seen` on the previous row.

   Its per-window dedupe state expires after `dedupeTTLMs`, which is **pinned
   to `Sessionizer.gapThresholdMs`** — deliberately the same constant, not
   merely the same number. A gap that long already splits an activity block
   downstream, so letting dedupe state outlive it would bump one row's
   `last_seen` across a gap the sessionizer has already judged discontinuous,
   and that row would read as unbroken work through time nobody worked. If you
   change the sessionizer's gap threshold, you are also changing capture
   dedupe. The shared constant also bounds the map to recently-active windows,
   which is what keeps it inside the §3.4 memory budget without a size cap.

### Right half — analysis (`Sources/shifu-analyzer/main.swift`)

The analyzer is a straight-line script; its statement order *is* the pipeline
order, and some of that ordering is load-bearing:

1. **`LedgerBuilder.rebuild`** — sessionize + classify + write, over a 48 h
   window (or everything with `--rebuild`). Idempotent: it deletes and
   re-inserts the window every run. Blocks whose *span identity*
   (`started_at`, `ended_at`, `app_bundle`) is reproduced unchanged keep their
   LLM verdicts, block cards, and retry counters — this "carry" is
   what stops re-runs from re-billing the LLM tiers.
2. **`Retention.scrubExpiredText`** — nulls `text` older than 14 days. The
   derived ledger survives; the raw text does not.
3. **`CardBuilder.run`** — tier 2. One fast-model pass distills each closed,
   substantial block into `activities.card` (category, topic, entities, gist);
   the same card relabels blocks the rules layer marked `ambiguous` (applied
   only above `confidenceFloor` 0.6, never over `source='user'`). Later stages
   render the card instead of re-sampling raw text, so this is the one hourly
   stage that reads OCR. One shot per closed block; `card_attempts` (3) only
   guards failure paths.
4. **`SemanticTaskGrouper.run`** — the LLM assigns evidence-bearing blocks to
   intent-level tasks (design.md §5.3): each batch carries a roster of recent
   `sem:` tasks to join — with the history that makes it a weighted prior
   (minutes, days active, days since, top sources) — the already-grouped
   blocks around the batch as stickiness context, and the blocks' own
   titles/pages/topics/text sampled across their whole span. Confident
   verdicts write `activities.sem_key` and upsert `tasks` rows (LLM title +
   `gist`, never overwriting a user rename); unplaced blocks burn one of 3
   `sem_attempts`. Fail-soft: no backend or a failed call leaves blocks
   mechanically grouped. What the model is *shown* lives in
   `SemanticTaskEvidence.swift`; the pipeline around it in
   `SemanticTaskGrouper.swift`.
5. **`TaskGrouper.run`** — groups activities into tasks by a stable key
   (`sem_key` when the semantic pass set one, else `topic:` → `domain:` →
   `app:`; system shell bundles — lock screen, Dock, Shifu's own UI —
   never mint or join a task at all, `isSystemBundle`) and rebuilds
   per-day `task_logs`.
   **Runs before extraction on purpose** so `activities.task_id` exists when
   notes are born and can be stamped into their frontmatter.
6. **`ThemeClusterer.run` + `refreshNarratives`** — the second, independent
   clustering (design.md §5.3): blocks into 3–8 broad initiatives
   (`activities.theme_key`). Runs *after* TaskGrouper so task names serve as
   evidence. Narratives are hash-gated over *completed* days — at most one LLM
   generation per active theme per day. Reuses SemanticTaskGrouper's
   parse/resolve engine (`"thm:"` prefix, `"new_themes"` wire key).
   **It files, it doesn't found (v17):** a key with no `themes` row becomes a
   `theme_proposals` row for the user instead, and those blocks burn an
   attempt like any unplaced one — the model *has* answered, so re-asking
   every hour would buy the same verdict twice. The proposal remembers the
   block ids, so accepting it a week later still files them.
7. **`TaskMerges.writeSignatures`** — re-derives durable per-block signatures
   while the source window titles still exist (they die with the 14-day
   retention).
8. **`DeckBuilder.drainPending`** (decks whose requested build never ran),
   **`WorkNoteCompiler.run`** (day notes, detailed tier for work/learning-
   dominant days) then **`TaskOverviewCompiler.run`** (per-task overview docs)
   — write Markdown into `~/Shifu/vault/`.
9. **`VaultIndexer.reconcile`** — the Markdown tree is the source of truth;
   this syncs the disposable index. Runs *after* task grouping so
   `task_key` → task/project resolution is current.
10. **Weekly block** (`PatternMiner` → `Radar` → merge/theme/deck suggestions),
    then the **daily digest**. Note `TaskMerges.autoMerge`
    is *not* in it: it drains the stored suggestion queue rather than minting
    it, so it runs beside `TaskStore.prune` every pass, and needs no embedder.

Every stage after the ledger is wrapped in its own `do/catch` that prints and
continues. A failing LLM never blocks the ledger (design.md §10).

---

## 3. Concept → file map

> "I want to change X." Start here.

| To change… | Edit |
|---|---|
| Which apps/domains map to which category | [`Analysis/RulesClassifier.swift`](Sources/ShifuCore/Analysis/RulesClassifier.swift) — `seedBundles` / `seedDomains` |
| The set of categories itself | [`Models/Activity.swift`](Sources/ShifuCore/Models/Activity.swift) — `Category` |
| When the LLM gets asked, and the block card's prompt | [`Analysis/CardBuilder.swift`](Sources/ShifuCore/Analysis/CardBuilder.swift) |
| What counts as one continuous block | [`Analysis/Sessionizer.swift`](Sources/ShifuCore/Analysis/Sessionizer.swift) — `gapThresholdMs` |
| How blocks become the ledger | [`Analysis/LedgerBuilder.swift`](Sources/ShifuCore/Analysis/LedgerBuilder.swift) |
| How activities group into tasks | [`Analysis/TaskGrouper.swift`](Sources/ShifuCore/Analysis/TaskGrouper.swift) — `key(topic:domain:appBundle:)` |
| Intent-level (LLM) task grouping, its gates and batching | [`Analysis/SemanticTaskGrouper.swift`](Sources/ShifuCore/Analysis/SemanticTaskGrouper.swift) |
| What that model is shown — roster prior, stickiness context, block evidence, the prompt | [`Analysis/SemanticTaskEvidence.swift`](Sources/ShifuCore/Analysis/SemanticTaskEvidence.swift) |
| Theme clustering (the high-level mode) + running narratives | [`Analysis/ThemeClusterer.swift`](Sources/ShifuCore/Analysis/ThemeClusterer.swift) |
| The task detail page's data | [`Vault/TaskStore.swift`](Sources/ShifuCore/Vault/TaskStore.swift) — `detail(taskID:)`; view is [`ShifuApp/TaskDetailView.swift`](Sources/ShifuApp/TaskDetailView.swift) |
| The theme list/detail data, and create / edit / delete | [`Vault/ThemeStore.swift`](Sources/ShifuCore/Vault/ThemeStore.swift); views are [`ShifuApp/ThemeViews.swift`](Sources/ShifuApp/ThemeViews.swift), actions [`ShifuApp/LedgerStoreThemes.swift`](Sources/ShifuApp/LedgerStoreThemes.swift) |
| Suggested themes — the queue, and what accepting one does | [`Vault/ThemeProposals.swift`](Sources/ShifuCore/Vault/ThemeProposals.swift) |
| The Time page's modes, span and lens | [`ShifuApp/TimeView.swift`](Sources/ShifuApp/TimeView.swift) — `TimeView` |
| How time is grouped, ranked and colored for the Time tab | [`ShifuApp/TimeSlices.swift`](Sources/ShifuApp/TimeSlices.swift) — `TimeBreakdown.slices`, `TimePalette` |
| What the Time page counts at all | [`Analysis/LedgerBuilder.swift`](Sources/ShifuCore/Analysis/LedgerBuilder.swift) — `labeledActivities` and `totals`, both filtered by `TaskGrouper.notSystemBundleSQL` so the lock screen and Shifu's own UI are charted nowhere (design.md §7) |
| The Summary breakdown and the timeline's legend | [`ShifuApp/TimeBreakdownView.swift`](Sources/ShifuApp/TimeBreakdownView.swift) |
| The LLM endpoint (DeepSeek / OpenAI-compatible) | [`shifu-analyzer/DeepSeekBackend.swift`](Sources/shifu-analyzer/DeepSeekBackend.swift) |
| What the LLM calls cost — token accounting and its rollups | [`Storage/LLMUsage.swift`](Sources/ShifuCore/Storage/LLMUsage.swift); recorded in `DeepSeekBackend.send`, read by `shifu status` |
| What gets redacted before disk | [`Privacy/Redactor.swift`](Sources/ShifuCore/Privacy/Redactor.swift) |
| What is never captured at all | [`Privacy/Exclusions.swift`](Sources/ShifuCore/Privacy/Exclusions.swift) |
| The capture ladder / rung thresholds | [`shifud/CaptureEngine.swift`](Sources/shifud/CaptureEngine.swift) |
| Capture triggers, idle, debounce | [`shifud/Daemon.swift`](Sources/shifud/Daemon.swift) |
| Screenshot + OCR mechanics | [`shifud/OCRCapture.swift`](Sources/shifud/OCRCapture.swift) |
| Review scheduling / intervals | [`Vault/FSRS.swift`](Sources/ShifuCore/Vault/FSRS.swift) |
| Note file format on disk | [`Vault/Note.swift`](Sources/ShifuCore/Vault/Note.swift), [`Vault/FrontMatter.swift`](Sources/ShifuCore/Vault/FrontMatter.swift) |
| The card JSON shape + LaTeX repairs | [`Vault/CardCandidates.swift`](Sources/ShifuCore/Vault/CardCandidates.swift) — shared by all three card prompts |
| Decks: rows, statuses, build claims | [`Vault/DeckStore.swift`](Sources/ShifuCore/Vault/DeckStore.swift) |
| Whether a task is offered a deck | [`Vault/DeckSuggester.swift`](Sources/ShifuCore/Vault/DeckSuggester.swift) |
| What a deck's cards are made of | [`Vault/DeckBuilder.swift`](Sources/ShifuCore/Vault/DeckBuilder.swift) |
| Per-task-day work notes + tiering | [`Vault/WorkNoteCompiler.swift`](Sources/ShifuCore/Vault/WorkNoteCompiler.swift) |
| Per-task overview documents | [`Vault/TaskOverviewCompiler.swift`](Sources/ShifuCore/Vault/TaskOverviewCompiler.swift) |
| Search ranking / hybrid retrieval | [`Vault/VaultSearch.swift`](Sources/ShifuCore/Vault/VaultSearch.swift) |
| Which tasks become automation candidates, and the dossier each carries | [`Analysis/PatternMiner.swift`](Sources/ShifuCore/Analysis/PatternMiner.swift) (thresholds + pure stats), [`Analysis/PatternMinerEvidence.swift`](Sources/ShifuCore/Analysis/PatternMinerEvidence.swift) (the SQL) |
| The automation tool catalog, the describer prompt and its honesty gates | [`Analysis/RadarDescriber.swift`](Sources/ShifuCore/Analysis/RadarDescriber.swift); the row/queue half is [`Analysis/Radar.swift`](Sources/ShifuCore/Analysis/Radar.swift) |
| Work Mode nudge behavior | [`shifud/WorkModeController.swift`](Sources/shifud/WorkModeController.swift), [`shifud/GlowOverlay.swift`](Sources/shifud/GlowOverlay.swift) |
| A user-tunable setting (key, default, bounds, UI copy) | [`Storage/SettingsCatalog.swift`](Sources/ShifuCore/Storage/SettingsCatalog.swift) — see §7 |
| The Settings window itself | [`ShifuApp/SettingsView.swift`](Sources/ShifuApp/SettingsView.swift), [`ShifuApp/SettingsStore.swift`](Sources/ShifuApp/SettingsStore.swift) — usually you do **not** need to touch these |
| The database schema | [`Storage/ShifuDatabase.swift`](Sources/ShifuCore/Storage/ShifuDatabase.swift) — `migrator` |
| Encryption at rest | [`Storage/DatabaseKey.swift`](Sources/ShifuCore/Storage/DatabaseKey.swift), [`Storage/EncryptionMigrator.swift`](Sources/ShifuCore/Storage/EncryptionMigrator.swift) |
| Deletion / "forget" semantics | [`Storage/DeletionTools.swift`](Sources/ShifuCore/Storage/DeletionTools.swift) |
| The main window's layout, camera flights, pages and routes | [`ShifuApp/MainWindow.swift`](Sources/ShifuApp/MainWindow.swift) — read model is `LedgerStore.swift` |
| The trail — where places live and how you pick one | [`ShifuApp/TrailRail.swift`](Sources/ShifuApp/TrailRail.swift); a place's spot on the mountain is `Destination.stationIndex` / `.landmark` in [`ShifuApp/World.swift`](Sources/ShifuApp/World.swift) |
| The mountain: terrain, camera math, ridgelines | [`ShifuApp/World.swift`](Sources/ShifuApp/World.swift) — `WorldMap.runs` is the one source of truth for the stair |
| Painting the mountain, and the temples on it | [`ShifuApp/WorldStage.swift`](Sources/ShifuApp/WorldStage.swift), [`ShifuApp/WorldLandmarks.swift`](Sources/ShifuApp/WorldLandmarks.swift) |
| The app's look — colors, cards, wisdom, the sensei | [`ShifuApp/Dojo.swift`](Sources/ShifuApp/Dojo.swift), [`ShifuApp/SenseiView.swift`](Sources/ShifuApp/SenseiView.swift) |
| CLI commands | [`shifu-cli/main.swift`](Sources/shifu-cli/main.swift) |
| The analyzer's stage order | [`shifu-analyzer/main.swift`](Sources/shifu-analyzer/main.swift) |

---

## 4. Data model

The schema is defined *only* as migrations v1–v18 in
[`Storage/ShifuDatabase.swift`](Sources/ShifuCore/Storage/ShifuDatabase.swift).
This is the consolidated current shape. **Never edit a shipped migration** —
add a new one (see §7).

### Authoritative tables

**`observations`** — raw capture trace. Written only by `ObservationRecorder`.
| Column | Notes |
|---|---|
| `id` | |
| `started_at`, `last_seen` | unix ms. `last_seen` is bumped by dedupe/touch |
| `app_bundle` | `unknown.<pid>` when the app has no bundle id |
| `window_title`, `url` | nullable; `url` only for browsers |
| `capture_kind` | `meta` \| `ax` \| `ocr` \| `excluded` — which ladder rung produced it |
| `text` | redacted, ≤8 KB, **NULL for `excluded`**, nulled after 14 days |
| `text_simhash` | near-duplicate detection |
| `session_id` | → `activities.id`, set by `LedgerBuilder` |

**`activities`** — the ledger. Rewritten idempotently by `LedgerBuilder`.
| Column | Notes |
|---|---|
| `started_at`, `ended_at`, `app_bundle` | together form the **span identity** used by the rebuild carry |
| `domain` | normalized: lowercase host, `www.` stripped |
| `category` | a `Category` raw value |
| `topic` | free text, LLM-produced; NULL from the rules tier |
| `confidence` | LLM only |
| `source` | `rules` \| `llm` \| `user` — free string, not an enum |
| `ambiguous` | rules tier wants the LLM to revisit this |
| `extracted` | v4 — knowledge extraction high-water mark |
| `task_id` | v6 — → `tasks.id`, set by `TaskGrouper` |
| `signature` | v8 — durable "topic; titles; domain", outlives observation retention |
| `llm_attempts` | v10 — the old tier-2 classifier's re-billing cap; inert since `CardBuilder` (v20) replaced that stage, kept because migrations are append-only |
| `sem_key` | v11 — LLM task assignment (`"sem:<slug>"`), outranks the mechanical key; carried across rebuilds |
| `sem_attempts` | v11 — caps re-billing of blocks the model declines to place, like `llm_attempts` |
| `theme_key` | v12 — independent LLM theme assignment (`"thm:<slug>"`); carried like `sem_key` |
| `theme_attempts` | v12 — the theme pass's re-billing cap |
| `theme_user_set` | v14 — 1 when a *human* filed this block's task (`TaskStore.assignTheme`), 0 when `ThemeClusterer` did. Prune and auto-merge read it |
| `card` | v20 — `BlockCard` JSON (category, topic, entities, gist), the block's distilled evidence; built once by `CardBuilder`, rendered by every later LLM stage instead of raw text, carried across rebuilds |
| `card_attempts` | v20 — the card pass's failure-path cap (3); a *usable* card is one shot, its closed block can't grow better evidence |

**`tasks`** (`key` unique — `sem:` from `SemanticTaskGrouper`, else
`TaskGrouper.key`; `name` is user-renameable; `gist` v11 — LLM one-liner for
the detail page), **`task_logs`** (unique on `task_id, day_start`) —
design.md §5.3.

Projects are gone as of v14 — `projects`, `tasks.project_id`,
`project_suggestions`, `vault_index.project_id`, `ProjectNoteCompiler` and the
`shifu vault projects` verb all went with them. Themes replaced the concept
whole; see `theme_user_set` below for the one bit that had to survive.

**`themes`** (v12, `key` unique `"thm:<slug>"`) — the high-level clustering
mode, and since v13 also what the Task log files tasks under. `name` and
`gist` are the user's (editable in place; the key never moves, so a rename
keeps the history), `summary` the running narrative with `summary_hash` as its
regeneration gate (hashed over completed days only). Theme *day entries* have
no table — they are computed on read from `activities.theme_key`
(`ThemeStore.detail`), and so is a *task's* theme: the one its blocks spend the
most time in (`TaskStore.dominantThemeSQL`), since filing is per block and a
task's blocks may straddle themes. **Rows are only ever written by the user**
as of v17 (`ThemeStore.create`, or accepting a proposal); `ThemeClusterer` may
only touch `last_active_at`.

**`theme_proposals`** + **`theme_proposal_blocks`** (v17, `key` unique) — the
initiatives the clusterer wants to found, with the blocks behind each, shown
under *Suggested themes*. Accepting mints the theme and files those blocks
(`ThemeProposals.accept`, unfiled ones only — a hand-filed block keeps its
home). `key` unique makes a dismissal permanent, and `ThemeStore.delete`
writes a dismissed row so a deleted theme can't be proposed back.

**`rules`** and **`exclusions`** — user overrides, merged over the hardcoded
seeds in `RulesClassifier` / `Exclusions`. Unique on `(kind, value)` where
`kind` is `bundle` \| `domain`.

**`settings`** — key/value. Keys live on `Settings` (`analysis.backend`,
`deepseek.api_key`/`base_url`/`model`/`reasoning_model`, `digest.hour`) plus
ad-hoc ones (`radar.last_mined`, `tasks.merge_threshold`,
`tasks.auto_merge_threshold` — set it above 1 to switch auto-merge off —
`themes.suggest_threshold`). Backend/key/model settings are
`ChoiceSetting`/`TextSetting` entries in `SettingsCatalog`, so the Settings
window renders them (connection fields only when the backend isn't "off").
Migration v15 folded the legacy `claude.*`/`openai.*` keys and backend
choices into these.

**`suggestions`** (radar, unique `pattern_key` — `task:<task_key>` or
`freq:<domain>`; v16 adds `setup_minutes` and `teach`, and `suggestion IS NULL`
means "mined but not yet judged", which `Radar.active` hides),
**`srs_reviews`** (review log
for later FSRS fitting), **`work_mode_sessions`**, **`task_merge_suggestions`**
(unique ordered pair — keeps dismissals dismissed),
**`theme_suggestions`** (v13, unique `task_id`; replaced the v9
`project_suggestions`, dropped in v14).

**`decks`** (v18, unique `key` *and* `task_key` — one deck per task; status
`pending → building → ready`, advanced only through `DeckStore`'s
compare-and-set, which is what keeps two analyzer processes from building the
same deck. No `card_count` column on purpose: review-time pruning would make a
stored count wrong within the session, so it is always derived from
`vault_index.deck_key`) and **`deck_suggestions`** (v18, unique **`task_key`**
— not `task_id`: the row is permanent, and prune/merge delete task rows while
SQLite reuses rowids, so an id-keyed row could one day suppress an unrelated
task).

**`llm_usage`** (v19, one row per billed response, written by
`DeepSeekBackend.send` through `LLMUsage.record`) — `prompt_tokens` /
`cached_prompt_tokens` / `completion_tokens` off the provider's own `usage`
object, the only record of what a day of analysis cost. Recorded before the
response is parsed, so a truncated call and its escalated retry both count:
those are the expensive ones. No prices stored — they change per model and
endpoint, so `shifu status` and any reader multiply for themselves. Rows are
per-call, not per-day, because a daily row would need a local-midnight key and
those strand duplicates across a time-zone change (the `task_logs` bug).

### Disposable tables — rebuildable, never authoritative

`vault_index`, `vault_fts` (FTS5 virtual, rowid tied to `vault_index.id`), and
`vault_vectors`. **The Markdown tree under `~/Shifu/vault/` is the source of
truth.** These three are a cache; `shifu vault reindex` rebuilds them from the
files. Losing them loses nothing, which is why `vault_fts` is plain FTS5 rather
than external-content.

### Where data lives on disk

```
~/Shifu/
  shifu.db      SQLite (WAL). Optionally SQLCipher-encrypted (`shifu encrypt`)
  vault/        Markdown notes — source of truth, opens in Obsidian
    YYYY/MM/    knowledge notes: deck cards (nothing else writes here)
    work/       per-(task, day) work notes
    tasks/      per-task living overview documents
  digests/      daily digest markdown
  logs/         daemon logs
  bin/          installed binaries (shifud, shifu-analyzer, shifu)
  pause_until   control file
  work_mode     control file
```

All paths resolve through [`ShifuPaths`](Sources/ShifuCore/ShifuPaths.swift),
which honors `SHIFU_HOME` — that override is how tests and both perf harnesses
avoid touching real data.

---

## 5. Invariants → choke point → guard

CLAUDE.md lists eight standing invariants. Violations are bugs, no exceptions.
This is where each is actually enforced, and what would catch a regression.

| # | Invariant | Choke point | Guard |
|---|---|---|---|
| 1 | No network code in `shifud` | `DeepSeekBackend` lives in the `shifu-analyzer` target — the SwiftPM target graph makes it unlinkable from `shifud` | ✅ `scripts/check-no-network.sh` — `nm -u` symbol scan, run by `make check` |
| 2 | Redaction is a single choke point before every DB write | `ObservationRecorder.record` calls `Redactor.redact` before insert; nothing else writes `observations` | ✅ `ObservationRecorderTests.textIsRedactedBeforeDisk`, `RedactorTests` |
| 3 | Exclusions enforced *before* capture | `CaptureEngine.capture` rung 0 returns before any content read; `ObservationRecorder` also drops text for `.excluded` | ✅ `CaptureLadderTests` drives the ladder over a fake `CaptureEngine.Probe` that records every read, so "an excluded window reaches no reader" is asserted, not reviewed. Predicate: `ExclusionsTests`. Recorder backstop: `ObservationRecorderTests.excludedNeverStoresText` |
| 4 | Pixels are never persisted | `OCRCapture` returns `(text, dhash)`; the `CGImage` never escapes the function | ✅ `PixelsNeverPersistedTests` — reflects over `OCRCapture.Result` and the recorder's `Candidate` for image-shaped fields, and asserts `observations` has no BLOB column |
| 5 | Pause tears down observers | `Daemon.stopCapture` removes the workspace observer, invalidates the heartbeat, cancels debounce, detaches the AX observer. `Daemon.syncCapture` is the only caller of the start/stop pair and every reason capture is down is *queried* there — pause, a locked screen, another session on the console (§3.1) — so no reason can clear another's teardown. A suspension must also be able to *end*: while the window server holds capture down, `syncRecheckTimer` re-asks every 5 s rather than trusting an unlock notification that a real machine never delivered | ✅ `DaemonTeardownTests` over `Daemon.observerState` — including that the analyzer timer *survives* pause; `DaemonSuspensionTests` over an injected `Daemon.SessionProbe`: a wake before the unlock stays down, and `theRecheckTimerFiresOnItsOwn` services a real run loop, so an unscheduled timer fails it (the direct-call test does not) |
| 6 | Perf budgets (<0.5% avg CPU, <80 MB RSS) | — | ✅ `make perf` → `scripts/perf-harness.sh`, `scripts/perf-vault.sh` |
| 7 | LLM prompts are token-budgeted | `LLMTokens.batches` (used by `CardBuilder.batches`, `Radar.batches` and `DeckBuilder.batches`) and `SemanticTaskGrouper.run`'s batch loop size by rendered-prompt tokens, never item count; the single-prompt stages (`WorkNoteCompiler.narrative`, `TaskOverviewCompiler.budgeted`, `DeckSuggester.budgeted`) shed evidence in a loop until the render fits; under `fullRosterMinContextTokens` the roster drops to the compact tier so a 4k window still gets a useful prior; and every one of those computations reserves `LLMBackend.responseReserve` so a thinking backend's chain-of-thought headroom is never squeezed out by a dense batch | ✅ `CardBuilderTests.runSplitsAcrossSmallContextWindowAndAnchorsCoinedTopics`, `SemanticTaskGrouperTests.runSplitsBatchesAndGrowsRosterAcrossThem`, `SemanticTaskGrouperTests.runReservesThinkingHeadroomWhenSizingBatches`, `SemanticTaskEvidenceTests.compactRosterKeepsSmallContextBackendsInBudget`, `RadarTests.describeSplitsBatchesUnderSmallContextWindow`, `DeckBuilderTests.batchesSplitUnderATinyWindow`, `TaskOverviewCompilerTests.budgetDropsOldestDaysRatherThanFailing` |
| 8 | Variable names > 1 character | — | ✅ `.swiftlint.yml` → `identifier_name.min_length: 2` |

All eight now have a guard. Invariants 3–5 got theirs by giving `shifud` a
test target and two small seams: `CaptureEngine.Probe` (the ladder's outside
world, injectable) and `Daemon.observerState` (what is currently wired up).
Both exist so the invariant can be *stated* — an ordering guarantee is a claim
about which calls never happen, and only a recording fake can assert that.

---

## 6. Control surface & process lifecycle

### The two control files

| File | Format | Written by | Watched by |
|---|---|---|---|
| `~/Shifu/pause_until` | unix **seconds** expiry, as ASCII digits | `shifu pause`, `LedgerStore.pause` | `PauseController` |
| `~/Shifu/work_mode` | presence alone; contents ignored | `shifu work on`, `LedgerStore.toggleWorkMode` | `WorkModeController` |

Both watchers are a `DispatchSource` on the **home directory** (not the file),
so creation and deletion both register. An expiry in the past reads as "not
paused", so a stale file can never wedge capture off.

> Note: the `pause_until` parse is currently implemented three times — in
> `shifu-cli/main.swift`, `shifud/PauseController.swift`, and
> `ShifuApp/LedgerStore.swift`. Change the format and two of them break
> silently. Logged in design.md §12.

### Who spawns whom

- **launchd** → `shifud` (`com.shifu.shifud`, installed by
  `scripts/install-daemon.sh`).
- **`shifud`** → `shifu-analyzer` hourly, resolved as a sibling of its own
  executable path. Self-gates on battery; skips if a previous run is alive.
  Runs even while paused — it only touches already-captured data.
- **`ShifuApp`** → `shifu-analyzer --force` on menu open, throttled to once per
  60 s, resolved from `~/Shifu/bin/`.

**Consequence worth knowing:** because both spawners resolve the analyzer from
the *installed* location, editing `shifu-analyzer` and running `swift build`
changes nothing at runtime. You must run `./scripts/install-daemon.sh`. See
[start.md](start.md).

### Degradation

Missing permissions never crash the daemon (design.md §10). No Accessibility →
metadata-only rung. No Screen Recording → OCR rung disabled. Both log a warning
at startup and keep going. A corrupt database is rotated aside to
`shifu.db.corrupt-<timestamp>` and capture restarts fresh — except on a
*Keychain error*, which rethrows, since the key may exist and rotating could
orphan good data.

---

## 7. Extension recipes

**Add a database migration.** Append `migrator.registerMigration("v17")` in
`ShifuDatabase.migrator`. Never edit v1–v18 — they have run on real machines.
Pick the next number by checking what has actually *run* (`select identifier
from grdb_migrations`), not just what is in this file: parallel branches pick
"the next version" independently, and a duplicate identifier is not a
conflict — GRDB skips it silently, and the missing table surfaces at query
time. v17 belongs to another branch for exactly this reason.
Additive column changes want `.notNull().defaults(to:)` so existing rows stay
valid.

**Add a category.** Add the case to `Category` in `Models/Activity.swift`
(raw value = the string stored in SQLite), add seeds to `RulesClassifier`, and
add a color in `TimePalette.categoryColors` (pick a `Dojo.chartSlots` hue).
`CardBuilder.prompt`
derives its category list from `Category.allCases`, so the LLM tier updates
itself — except `privateTime` and `unclassified`, which it filters out.

**Add a capture-ladder rung.** `CaptureEngine.capture`, ordered cheapest first,
and add a `CaptureKind` case. Keep exclusion checks above every content read.

**Add an LLM backend.** Usually unnecessary: any OpenAI-compatible
/chat/completions server needs no new code — point
`deepseek.base_url`/`deepseek.model` at it. Otherwise conform to `LLMBackend`
(`name`, `contextWindowTokens`, `complete`). If it touches the network it
**must** live in the `shifu-analyzer` target, not `ShifuCore` — see
invariant 1 (that is where `DeepSeekBackend` lives) — and wire selection into
`shifu-analyzer/main.swift`.

**Add a user setting.** Add one entry to `SettingsCatalog`
(`Storage/SettingsCatalog.swift`) and append it to `ints` / `domainLists` /
`choices` / `texts`. That
is the whole job for storage, defaulting, bounds and UI: the Settings window
renders from the catalog, and `Settings.value(_:database:)` clamps on read *and*
write, so no caller ever restates a bound. Read it where it matters with
`Settings.value(SettingsCatalog.yourSetting, database:)`.

Two caveats:

- **Live reload is not free.** A setting the *running daemon* consumes needs its
  own cached var and changed-guard in `Daemon.reloadIntervals()`. Without one it
  will persist and render correctly and be silently ignored until `shifud`
  restarts. Settings read once per analyzer run, or by the app/CLI, need nothing.
- **Never rebuild a timer unconditionally** in that method. Rebuilding the
  analyzer timer on every heartbeat resets its countdown each minute and it
  never fires. The `!=` comparison is load-bearing; `|| … == nil` is what makes
  the method idempotent enough to call from four places.

A genuinely new *shape* of setting (a Bool toggle, say) means one new descriptor
struct next to `IntSetting`/`ChoiceSetting`/`TextSetting` plus one row view in
`SettingsView`. A new section is one `SettingsSection` case. `TextSetting`
rows can gate on a choice value (`visibleWhen:`) — that is how each cloud
backend shows only its own key/model fields.

**Add a CLI command.** Add a `commandX` function and an entry in the `commands`
dictionary in `run()`, plus a line in `usage`.

**Add a vault note kind.** Add a `FrontMatter.Kind` case; `VaultIndexer` and
`VaultSearch` filter on it. Knowledge-note queries must keep excluding other
kinds — `Note.parse` returns nil for non-`.knowledge` files precisely so work
and project notes can never enter the review queue.

---

## 8. Conventions

- **Timestamps are unix milliseconds as `Int64`, end to end.** Database
  columns, model fields, and function parameters all use ms; conversion to
  `Date` happens only at UI and CLI boundaries. `TaskLog.dayStart` and
  `TaskGrouper.affectedDays` are the exception in *meaning*, not type: those
  are **local**-midnight ms, so they follow the user's calendar and DST.
- **Idempotent rebuilds over incremental state.** `LedgerBuilder`,
  `TaskGrouper.rebuildLogs`, and `WorkNoteCompiler` all delete-and-recompute
  their window. Derived state that costs money or tokens to recreate (LLM
  verdicts, block cards, retry counters) is explicitly *carried* across the
  rebuild by span identity. If you add expensive derived state, add it to
  `LedgerBuilder.CarriedState` or it will be silently recomputed every hour.
- **Content-hash gates before LLM calls.** `WorkNoteCompiler` and
  `ThemeClusterer.refreshNarratives` regenerate prose only when the underlying
  content hash changed. Unchanged days cost zero tokens.
- **`ShifuCore` holds the logic; targets hold the wiring.** If you find
  yourself writing a pure function in `shifud` or `ShifuApp`, it probably
  belongs in `ShifuCore` where it can be tested.
- **Comments cite the spec.** The `(design.md §4.2)` / `(vault-features.md §5.1)`
  references throughout are load-bearing for navigation — keep them accurate
  when you move code.
- **Tests use `swift-testing`** (`@Test`, `@Suite`, `#expect`), not XCTest, and
  `ShifuDatabase.inMemory()` for isolation.

### Do not "clean up" these

- **`Sources/shifu-cli/VaultBench.swift`** looks like stray benchmark code in a
  shipped binary. It is not: `scripts/perf-vault.sh` invokes
  `shifu vault bench <n>` and parses its output to assert the §V8 budgets.
  Deleting it breaks `make perf`.
- **`Retention`** is declared at the bottom of `Analysis/LedgerBuilder.swift`,
  not in a file of its own. Grep for it rather than assuming it is missing.

---

## 9. Build, test, and gates

```bash
make check
```

Build all targets → `swift test` → `swiftlint --strict` → privacy invariants.
**Must be green before every commit.**

```bash
make perf
```

Runs `shifud` against a synthetic feed and asserts design.md §3.4 budgets, plus
the vault index/search budgets. **A perf regression blocks like a test
failure.**

Most coverage lives in `Tests/ShifuCoreTests/`; `ShifudTests`, `ShifuAppTests`
and `ShifuCLITests` cover the wiring that cannot move down (the capture
ladder's ordering, pause teardown, the Time page's calendar arithmetic, the
CLI's argument parsing). New pure logic still belongs in `ShifuCore`.
SwiftLint caps files at 500 lines (warning) and lines at 120/160
(warning/error) — the most common way an otherwise-fine change fails
`make check`.

To see a change in the real app, `swift build` is not enough — see
[start.md](start.md) for which install script to run.

---

## 10. Which document is authoritative for what

| File | Status | Use it for |
|---|---|---|
| [design.md](design.md) | **authoritative spec** | What Shifu does and why. §-numbers are cited throughout the code. §12 is the deferred-ideas log. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | this file | Where things live, how to change them safely. |
| [CLAUDE.md](CLAUDE.md) | authoritative rules | Build commands, standing invariants, the minimalism rule. |
| [implementation.md](implementation.md) | phase plan | Original Phase 0–6 sequencing and per-phase exit criteria. **Its checkboxes were never ticked** — read it as the plan, not as status. |
| [vault-features.md](vault-features.md) | authoritative spec | The vault second-brain layer (V1–V4). Cited as `vault-features.md §N` in code. |
| [vault-implementation.md](vault-implementation.md) | phase plan | Vault phase sequencing. |
| [start.md](start.md) | practical | Rebuild/reinstall loop, and troubleshooting TCC permission breakage. |
| [README.md](README.md) | practical | Install, CLI surface, privacy model. |
| [instructions.md](instructions.md) | **historical** | The original one-page brief that design.md was written from. Superseded; kept for provenance. |

---

## 11. Known deviations from spec

Live discrepancies between the code and design.md. Keep this section short and
current — an entry here is a debt, not a decision.

### `Tests/ShifuCoreTests/ShifuCoreTests.swift` is a placeholder

Six lines asserting `Shifu.version` is non-empty — the `swift package init`
stub. Harmless, but it is not a real test.

### The Time page's hour bucketing is DST-correct only through `CalendarSlices`

`DayTrail.stones` and `TimeBuckets.buckets` both walk a span one calendar unit
at a time. The obvious implementation — `date(bySettingHour:minute:second:of:)`
— force-unwraps an optional that is nil on a spring-forward, and on a fall-back
resolves the repeated hour to the occurrence *behind* the cursor, so the loop
never terminates. Both were written that way and both hung. Any new
span-walking code must go through
[`Analysis/CalendarSlices.swift`](Sources/ShifuCore/Analysis/CalendarSlices.swift).
