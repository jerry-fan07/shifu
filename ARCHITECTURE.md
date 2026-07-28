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
| `ShifuApp` | executable | SwiftUI menu bar app + dashboard. | never |

**The one architectural fact to internalize: there is no IPC.** No sockets, no
XPC, no message bus. The processes coordinate through shared state on disk:

- `~/Shifu/shifu.db` — one SQLite file, WAL mode, `synchronous = NORMAL`.
- `~/Shifu/pause_until` and `~/Shifu/work_mode` — two control files the daemon
  watches with a `DispatchSource` on the directory.

That is why `shifu pause` works with the daemon running as a separate process
under launchd, and why the menu bar app can show today's totals without asking
anyone. Every process opens the same database and reads.

Anything testable is pushed down into `ShifuCore`, which is why `ShifuCore` is
~60% of the Swift in the repo and holds essentially all of the test coverage.
`shifud` and `ShifuApp` are deliberately thin: event wiring and views over
`ShifuCore` logic. They have no test targets.

```
Sources/ShifuCore/
  Models/      Observation, Activity, WorkTask/TaskLog  — GRDB records
  Storage/     ShifuDatabase (+ migrations), DatabaseKey, EncryptionMigrator, DeletionTools
  Capture/     ObservationRecorder (the write path), SimHash, DHash, BoundedLRUCache
  Privacy/     Redactor, Exclusions
  Analysis/    Sessionizer, RulesClassifier, AmbiguousClassifier, LedgerBuilder,
               SemanticTaskGrouper, ThemeClusterer, TaskGrouper, TaskMerges (+TaskAutoMerge),
               PatternMiner, Radar, DigestGenerator, Embedder
  LLM/         LLMBackend protocol + LLMTokens
               (DeepSeekBackend, the only implementation, lives in shifu-analyzer — invariant 1)
  Vault/       Note, WorkNote, FrontMatter, FSRS, VaultStore, VaultIndexer,
               VaultSearch, TaskStore (+TaskMerging, TaskPrune), ThemeStore,
               KnowledgeExtractor, WorkNoteCompiler
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
                            ├──▶ AmbiguousClassifier ──▶ LLM ──▶ [activities] relabeled
                            │
                            ├──▶ SemanticTaskGrouper ──▶ LLM ──▶ [activities].sem_key
                            │                                    [tasks] created w/ gist
                            │
                            ├──▶ TaskGrouper ──▶ [tasks] [task_logs]
                            │
                            ├──▶ ThemeClusterer ──▶ LLM ──▶ [activities].theme_key
                            │                               [themes] + narratives
                            │
                            ├──▶ KnowledgeExtractor ──▶ vault/**.md  (inbox notes)
                            ├──▶ WorkNoteCompiler   ──▶ vault/**.md  (per task-day)
                            │
                            ├──▶ VaultIndexer ──▶ [vault_index] [vault_fts] [vault_vectors]
                            │
                            └──▶ PatternMiner ──▶ Radar ──▶ [suggestions]

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
   LLM verdicts, `extracted` flag, and `llm_attempts` counter — this "carry" is
   what stops re-runs from re-billing the LLM tiers.
2. **`Retention.scrubExpiredText`** — nulls `text` older than 14 days. The
   derived ledger survives; the raw text does not.
3. **`AmbiguousClassifier.run`** — tier 2. Only blocks the rules layer marked
   `ambiguous` and that are under `maxAttempts` (3). Batch-prompted, JSON out,
   applied only above `confidenceFloor` (0.6).
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
   (`activities.theme_key`, `themes` rows). Runs *after* TaskGrouper so task
   names serve as evidence. Narratives are hash-gated over *completed* days —
   at most one LLM generation per active theme per day. Reuses
   SemanticTaskGrouper's parse/resolve engine (`"thm:"` prefix,
   `"new_themes"` wire key).
7. **`TaskMerges.writeSignatures`** — re-derives durable per-block signatures
   while the source window titles still exist (they die with the 14-day
   retention).
8. **`KnowledgeExtractor.run`** then **`WorkNoteCompiler.run`** — write
   Markdown into `~/Shifu/vault/`.
9. **`VaultIndexer.reconcile`** — the Markdown tree is the source of truth;
   this syncs the disposable index. Runs *after* task grouping so
   `task_key` → task/project resolution is current.
10. **Weekly block** (`PatternMiner` → `Radar` → merge/theme suggestions),
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
| When the LLM gets asked, and the prompt | [`Analysis/AmbiguousClassifier.swift`](Sources/ShifuCore/Analysis/AmbiguousClassifier.swift) |
| What counts as one continuous block | [`Analysis/Sessionizer.swift`](Sources/ShifuCore/Analysis/Sessionizer.swift) — `gapThresholdMs` |
| How blocks become the ledger | [`Analysis/LedgerBuilder.swift`](Sources/ShifuCore/Analysis/LedgerBuilder.swift) |
| How activities group into tasks | [`Analysis/TaskGrouper.swift`](Sources/ShifuCore/Analysis/TaskGrouper.swift) — `key(topic:domain:appBundle:)` |
| Intent-level (LLM) task grouping, its gates and batching | [`Analysis/SemanticTaskGrouper.swift`](Sources/ShifuCore/Analysis/SemanticTaskGrouper.swift) |
| What that model is shown — roster prior, stickiness context, block evidence, the prompt | [`Analysis/SemanticTaskEvidence.swift`](Sources/ShifuCore/Analysis/SemanticTaskEvidence.swift) |
| Theme clustering (the high-level mode) + running narratives | [`Analysis/ThemeClusterer.swift`](Sources/ShifuCore/Analysis/ThemeClusterer.swift) |
| The task detail page's data | [`Vault/TaskStore.swift`](Sources/ShifuCore/Vault/TaskStore.swift) — `detail(taskID:)`; view is [`ShifuApp/TaskDetailView.swift`](Sources/ShifuApp/TaskDetailView.swift) |
| The theme list/detail data | [`Vault/ThemeStore.swift`](Sources/ShifuCore/Vault/ThemeStore.swift); views are [`ShifuApp/ThemeViews.swift`](Sources/ShifuApp/ThemeViews.swift) |
| The Time tab's modes, span and lens | [`ShifuApp/DashboardView.swift`](Sources/ShifuApp/DashboardView.swift) — `TimeTabView` |
| How time is grouped, ranked and colored for the Time tab | [`ShifuApp/TimeSlices.swift`](Sources/ShifuApp/TimeSlices.swift) — `TimeBreakdown.slices`, `TimePalette` |
| The Summary breakdown and the timeline's legend | [`ShifuApp/TimeBreakdownView.swift`](Sources/ShifuApp/TimeBreakdownView.swift) |
| The LLM endpoint (DeepSeek / OpenAI-compatible) | [`shifu-analyzer/DeepSeekBackend.swift`](Sources/shifu-analyzer/DeepSeekBackend.swift) |
| What gets redacted before disk | [`Privacy/Redactor.swift`](Sources/ShifuCore/Privacy/Redactor.swift) |
| What is never captured at all | [`Privacy/Exclusions.swift`](Sources/ShifuCore/Privacy/Exclusions.swift) |
| The capture ladder / rung thresholds | [`shifud/CaptureEngine.swift`](Sources/shifud/CaptureEngine.swift) |
| Capture triggers, idle, debounce | [`shifud/Daemon.swift`](Sources/shifud/Daemon.swift) |
| Screenshot + OCR mechanics | [`shifud/OCRCapture.swift`](Sources/shifud/OCRCapture.swift) |
| Review scheduling / intervals | [`Vault/FSRS.swift`](Sources/ShifuCore/Vault/FSRS.swift) |
| Note file format on disk | [`Vault/Note.swift`](Sources/ShifuCore/Vault/Note.swift), [`Vault/FrontMatter.swift`](Sources/ShifuCore/Vault/FrontMatter.swift) |
| What gets extracted into notes | [`Vault/KnowledgeExtractor.swift`](Sources/ShifuCore/Vault/KnowledgeExtractor.swift) |
| Per-task-day work notes | [`Vault/WorkNoteCompiler.swift`](Sources/ShifuCore/Vault/WorkNoteCompiler.swift) |
| Search ranking / hybrid retrieval | [`Vault/VaultSearch.swift`](Sources/ShifuCore/Vault/VaultSearch.swift) |
| Automation suggestions | [`Analysis/PatternMiner.swift`](Sources/ShifuCore/Analysis/PatternMiner.swift), [`Analysis/Radar.swift`](Sources/ShifuCore/Analysis/Radar.swift) |
| Work Mode nudge behavior | [`shifud/WorkModeController.swift`](Sources/shifud/WorkModeController.swift), [`shifud/GlowOverlay.swift`](Sources/shifud/GlowOverlay.swift) |
| A user-tunable setting (key, default, bounds, UI copy) | [`Storage/SettingsCatalog.swift`](Sources/ShifuCore/Storage/SettingsCatalog.swift) — see §7 |
| The Settings window itself | [`ShifuApp/SettingsView.swift`](Sources/ShifuApp/SettingsView.swift), [`ShifuApp/SettingsStore.swift`](Sources/ShifuApp/SettingsStore.swift) — usually you do **not** need to touch these |
| The database schema | [`Storage/ShifuDatabase.swift`](Sources/ShifuCore/Storage/ShifuDatabase.swift) — `migrator` |
| Encryption at rest | [`Storage/DatabaseKey.swift`](Sources/ShifuCore/Storage/DatabaseKey.swift), [`Storage/EncryptionMigrator.swift`](Sources/ShifuCore/Storage/EncryptionMigrator.swift) |
| Deletion / "forget" semantics | [`Storage/DeletionTools.swift`](Sources/ShifuCore/Storage/DeletionTools.swift) |
| Menu bar + dashboard | [`ShifuApp/`](Sources/ShifuApp/) — read model is `LedgerStore.swift` |
| CLI commands | [`shifu-cli/main.swift`](Sources/shifu-cli/main.swift) |
| The analyzer's stage order | [`shifu-analyzer/main.swift`](Sources/shifu-analyzer/main.swift) |

---

## 4. Data model

The schema is defined *only* as migrations v1–v12 in
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
| `llm_attempts` | v10 — caps re-billing of stubborn low-confidence blocks at 3 |
| `sem_key` | v11 — LLM task assignment (`"sem:<slug>"`), outranks the mechanical key; carried across rebuilds |
| `sem_attempts` | v11 — caps re-billing of blocks the model declines to place, like `llm_attempts` |
| `theme_key` | v12 — independent LLM theme assignment (`"thm:<slug>"`); carried like `sem_key` |
| `theme_attempts` | v12 — the theme pass's re-billing cap |
| `theme_user_set` | v14 — 1 when a *human* filed this block's task (`TaskStore.assignTheme`), 0 when `ThemeClusterer` did. Prune and auto-merge read it |

**`tasks`** (`key` unique — `sem:` from `SemanticTaskGrouper`, else
`TaskGrouper.key`; `name` is user-renameable; `gist` v11 — LLM one-liner for
the detail page), **`task_logs`** (unique on `task_id, day_start`) —
design.md §5.3.

Projects are gone as of v14 — `projects`, `tasks.project_id`,
`project_suggestions`, `vault_index.project_id`, `ProjectNoteCompiler` and the
`shifu vault projects` verb all went with them. Themes replaced the concept
whole; see `theme_user_set` below for the one bit that had to survive.

**`themes`** (v12, `key` unique `"thm:<slug>"`) — the high-level clustering
mode, and since v13 also what the Task log files tasks under. `name`
user-renameable, `gist` the LLM one-liner, `summary` the running narrative
with `summary_hash` as its regeneration gate (hashed over completed days
only). Theme *day entries* have no table — they are computed on read from
`activities.theme_key` (`ThemeStore.detail`), and so is a *task's* theme: the
one its blocks spend the most time in (`TaskStore.dominantThemeSQL`), since
filing is per block and a task's blocks may straddle themes.

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

**`suggestions`** (radar, unique `pattern_key`), **`srs_reviews`** (review log
for later FSRS fitting), **`work_mode_sessions`**, **`task_merge_suggestions`**
(unique ordered pair — keeps dismissals dismissed),
**`theme_suggestions`** (v13, unique `task_id`; replaced the v9
`project_suggestions`, dropped in v14).

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
| 3 | Exclusions enforced *before* capture | `CaptureEngine.capture` rung 0 returns before any content read; `ObservationRecorder` also drops text for `.excluded` | ⚠️ Predicate: `ExclusionsTests`. Recorder backstop: `ObservationRecorderTests.excludedNeverStoresText`. **The ordering inside `CaptureEngine` itself is structural — no test** |
| 4 | Pixels are never persisted | `OCRCapture` returns `(text, dhash)`; the `CGImage` never escapes the function | ⚠️ **Structural only — no automated guard** |
| 5 | Pause tears down observers | `Daemon.stopCapture` removes the workspace observer, invalidates the heartbeat, cancels debounce, detaches the AX observer | ⚠️ **Structural only — no automated guard** |
| 6 | Perf budgets (<0.5% avg CPU, <80 MB RSS) | — | ✅ `make perf` → `scripts/perf-harness.sh`, `scripts/perf-vault.sh` |
| 7 | LLM prompts are token-budgeted | `AmbiguousClassifier.batches` and `SemanticTaskGrouper.run`'s batch loop size by `LLMTokens.estimate`, never item count; under `fullRosterMinContextTokens` the roster drops to the compact tier so a 4k window still gets a useful prior | ✅ `AmbiguousClassifierTests.runSplitsAcrossSmallContextWindow`, `SemanticTaskGrouperTests.runSplitsBatchesAndGrowsRosterAcrossThem`, `SemanticTaskEvidenceTests.compactRosterKeepsSmallContextBackendsInBudget` |
| 8 | Variable names > 1 character | — | ✅ `.swiftlint.yml` → `identifier_name.min_length: 2` |

**Invariants 4 and 5 have no automated guard** because both live in `shifud`,
which has no test target (it is AppKit/AX event wiring). Changes to
`OCRCapture` or `Daemon.stopCapture` deserve a manual read against design.md
§3.2 / §8 — that review *is* the guard today.

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

**Add a database migration.** Append `migrator.registerMigration("v13")` in
`ShifuDatabase.migrator`. Never edit v1–v12 — they have run on real machines.
Additive column changes want `.notNull().defaults(to:)` so existing rows stay
valid.

**Add a category.** Add the case to `Category` in `Models/Activity.swift`
(raw value = the string stored in SQLite), add seeds to `RulesClassifier`, and
add a color in `TimeTabView.categoryColors`. `AmbiguousClassifier.prompt`
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
and project notes can never enter the inbox or review queue.

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
  verdicts, `extracted`, `llm_attempts`) is explicitly *carried* across the
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

Nearly all coverage lives in `Tests/ShifuCoreTests/`; `shifud`, `ShifuApp`, and
`shifu-cli` have no test targets, so logic that needs testing belongs in
`ShifuCore`. SwiftLint caps files at 500 lines (warning) and lines at 120/160
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
