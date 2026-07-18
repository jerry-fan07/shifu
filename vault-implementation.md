# Vault Second Brain — Implementation Plan

**Date:** 2026-07-18
**Companion to:** [vault-features.md](vault-features.md) — section references (§V) point there;
plain § points to [design.md](design.md). Extends [implementation.md](implementation.md)
(phases 0–6 shipped through M3+); same guiding constraint: minimalism, every phase
ends dogfoodable, `make check` + `make perf` green before every commit.

**Ground rules for all four phases:**

- `shifud` is never touched. Everything lands in `ShifuCore`, `shifu-analyzer`,
  `shifu-cli`, `ShifuApp` (invariant 1 stays trivially auditable).
- Notes are built only from `activities` rows (already redacted, invariant 2)
  with `category != 'private'`. No code path reaches back to `observations`.
- Every LLM prompt is sized with `LLMTokens.estimate` against
  `contextWindowTokens` (invariant 7); every LLM feature degrades to a working
  non-LLM behavior when no backend is available, matching the analyzer's
  existing pattern.
- The Markdown tree is the source of truth; everything in SQLite added by these
  phases (index, FTS, vectors) must be rebuildable from the files.

---

## Phase V1 — Index & Search

**Goal:** any note is findable in one query from CLI and UI (§V4).

Order of work:

1. **Frontmatter groundwork.** Add `kind: knowledge | work | project` and
   `task_key` to `Note` frontmatter (serialize + parse; absent `kind` parses as
   `knowledge` so no vault migration). Extract the frontmatter scan in
   `Note.parse` into a small shared helper (`FrontMatter.parse`) that V2's
   `WorkNote` will reuse — do it now so V2 doesn't churn `Note`.
2. **Migration v7** in `ShifuDatabase`:
   - `vault_index`: `id` PK, `note_id` TEXT unique, `path` TEXT, `kind` TEXT,
     `task_id` INTEGER null, `project_id` INTEGER null, `captured` INTEGER,
     `content_hash` TEXT, `mtime` INTEGER. Indexes on `kind`, `task_id`,
     `project_id`.
   - `vault_fts`: FTS5 virtual table (`title`, `body`), rowid tied to
     `vault_index.id`, bm25 ranking, `snippet()` for results. Plain FTS5 (not
     external-content): the duplicated text is disposable index data by design.
3. **`VaultIndexer`** (new, `ShifuCore/Vault/VaultIndexer.swift`):
   - `reconcile(root:database:)` — enumerate `*.md`, stat mtime; for
     changed/new files hash content, parse, upsert `vault_index` + `vault_fts`;
     delete rows whose files vanished. O(files) stat, O(changed) parse — cheap
     enough to run every analyzer pass.
   - Write-through hooks: `VaultStore.save` indexes after write;
     `VaultStore.discard` deletes the row. Reconcile remains the safety net for
     external edits (Obsidian).
   - `task_key` in frontmatter resolves to `task_id`/`project_id` at index time
     via the `tasks` table (so a later project assignment is picked up by the
     next reconcile without rewriting files).
4. **`VaultSearch`** (new): `search(query:kind:taskID:projectID:since:limit:)`
   → ranked `[Hit]` (path, note id, kind, snippet, captured). bm25 order,
   filters via join to `vault_index`. Sanitize the user query into FTS5 match
   syntax (quote tokens; a malformed query must return empty, never throw).
5. **CLI**: `shifu vault search <query> [--task] [--project] [--kind] [--since]`
   and `shifu vault reindex` in `shifu-cli/main.swift`. Output: rank, snippet,
   relative path — one hit per line block, pipeable.
6. **Analyzer wiring**: call `VaultIndexer.reconcile` once per run, after the
   extraction step (new notes from this run get indexed by the write-through
   hook anyway; reconcile catches everything else).
7. **UI**: search field at the top of the Vault tab (`VaultViews.swift`).
   Results list → in-app read-only note view (title, body, metadata) with
   "Reveal in Finder". No editing in-app (Obsidian/editor is the edit surface —
   minimalism).
8. **Perf**: `make perf` gains a vault case — synthetic vault generator (10k
   notes), assert reconcile-no-changes and single-query latency budgets (§V8:
   search < 50 ms end-to-end).

**Tests:** indexer reconcile add/modify/delete/external-edit; write-through on
save/discard; hash short-circuit (unchanged file not reparsed); FTS query
sanitization (quotes, `AND`, unbalanced `"`); filter joins; kind default on
legacy notes.

**Verification (exit, §V9):** a week-old fact from the dogfood vault is found
in one query from both CLI and UI.

**Risk to retire early:** FTS5 availability in the SQLCipher-linked build —
verify the bundled SQLCipher compiles with `SQLITE_ENABLE_FTS5` on day one,
before writing the indexer. If it doesn't, that's a build-flag fix now or a
LIKE-based fallback decision, not a surprise in week two.

---

## Phase V2 — Work Notes

**Goal:** every non-private working day leaves a distilled Markdown trace;
yesterday is answerable without opening the DB (§V2.1).

Order of work:

1. **`WorkNote` model** (new, `ShifuCore/Vault/WorkNote.swift`): fields per
   §V2.1 frontmatter (id ULID, task key, day, duration, sources, sessions,
   project slug, content hash) + body. Serialize/parse on the shared
   `FrontMatter` helper. Body contract, enforced by the type: line 1 is the
   deterministic summary; `## Sessions` and `## Captured` are optional
   sections the compiler can replace independently.
2. **Analyzer reordering** (small but load-bearing): today the pipeline runs
   …LLM classify → KnowledgeExtractor → TaskGrouper. Move `TaskGrouper` to run
   directly after the LLM pass, before extraction, so `activities.task_id`
   exists when notes are born:
   `LedgerBuilder → AmbiguousClassifier → TaskGrouper → KnowledgeExtractor →
   WorkNoteCompiler → VaultIndexer.reconcile`. TaskGrouper is already
   idempotent; this is a pure ordering change plus a test that the analyzer
   main path still produces identical task/log rows.
3. **`task_key` stamping**: `KnowledgeExtractor` writes `task_key` (from the
   source activity's task) into new notes' frontmatter. Deck selection
   (`VaultStore` / Cards tab) switches from slug-matching to explicit
   `task_key`, keeping the slug fallback only for pre-existing notes.
4. **`WorkNoteCompiler`** (new, `ShifuCore/Vault/WorkNoteCompiler.swift`),
   run per analyzer window after TaskGrouper:
   - For every (task, day) the window touches (reuse TaskGrouper's
     affected-days logic): aggregate that day's task activities — duration,
     sources, session spans (contiguous activity runs, gap-split like the
     sessionizer), the `task_logs` summary line — and the day's knowledge
     notes with matching `task_key` for `## Captured` wiki-links.
   - Compute `content_hash` = hash of (sorted activity ids + per-activity
     text-sample hashes). Deterministic parts are always rewritten
     (idempotent, like `rebuildLogs`); if the stored hash matches, the
     existing `## Sessions` prose is carried over verbatim — zero tokens spent
     on unchanged days.
   - File path `vault/work/YYYY/MM/DD-<task-slug>.md` via `VaultStore` (ULID
     prefix lookup for stability across task renames; renames change the
     display name in frontmatter on next rebuild, not the file identity).
5. **Narrative generation** (LLM, optional): for task-days over the substance
   threshold (default ≥ 10 min and non-empty text samples, `settings` key),
   one prompt per task-day producing 1–3 bullet sessions ("what happened,
   what was accomplished"). Batch sized with `LLMTokens.estimate`; on the 4k
   on-device window, truncate samples rather than splitting the day. No
   backend / failure ⇒ note ships with line 1 only (still valid, per the
   body contract).
6. **`DeletionTools` vault pass**: date-range forget deletes work notes whose
   `day` falls in range and recompiles boundary days from surviving
   activities; also removes affected `vault_index`/`vault_fts` rows (reconcile
   would catch it, but delete should be immediate). Delete-everything already
   removes the vault tree — verify it includes `work/`.
7. **UI**: Vault tab "Today" rows and task rows open the task's latest work
   note in the V1 note view.
8. **Onboarding/settings copy**: one sentence stating that distilled work
   notes persist beyond the raw-text retention window (§V7).

**Tests:** compiler idempotence (run twice ⇒ identical files); hash gating
(counting stub backend: second run with unchanged activities makes zero LLM
calls); substance threshold; private activities never appear; task rename
survives rebuild; `## Captured` links match `task_key`; date-range delete
removes and recompiles correctly; analyzer reorder produces unchanged
task/log output.

**Verification (exit, §V9):** one week of dogfooding — yesterday's work note
answers "what did I do?" without opening the DB; digest still reads well.

**Risk to retire early:** narrative quality on the 4k on-device window. Spend
half a day prompting over 5 real task-days before building the full compiler
plumbing; if quality is thin, ship V2 with deterministic notes only (the
structure is the feature; prose stays behind the existing design.md §12
deferral) and revisit after V3.

---

## Phase V3 — Semantic Task Clustering

**Goal:** one effort = one task, even when topic slugs differ; merges are
always user-confirmed (§V5).

Order of work:

1. **`Embedder` abstraction** (new, `ShifuCore/Analysis/Embedder.swift`):
   `protocol Embedder { func embed(_ text: String) -> [Float]? }` with two
   impls — `NLEmbedding.sentenceEmbedding` (on-device, nil when unavailable)
   and a deterministic test stub. Cosine + centroid helpers as pure functions.
2. **Migration v8**:
   - `activities.signature` TEXT — the durable one-line block signature
     (topic + title sample + domain), written at sessionization/classification
     time. This exists because window titles die with the 14-day observation
     retention; the signature is the redacted, durable input that lets
     centroids be recomputed forever after.
   - `task_merge_suggestions`: `task_a`, `task_b` (ordered pair, unique),
     `cosine`, `status` (`new | dismissed | merged`), `created_at`.
   - Settings key `tasks.cluster_threshold` (default 0.75).
3. **Assignment in `TaskGrouper`** (§V5.1): before the lexical-key grouping,
   embed each block's signature and compare against active-task centroids
   (last 30 days). Cosine ≥ threshold ⇒ that task; else the existing lexical
   path verbatim. **Centroids are recomputed per run** from the active
   window's assigned signatures (re-embedding is milliseconds) rather than
   incrementally accumulated — this keeps `run` idempotent: re-analyzing the
   same window cannot drift a centroid by double-counting. Store the result
   (`tasks.centroid` BLOB Float32 + `centroid_count`) only as a cache for the
   next run's comparisons. Historical activities outside the analyzer window
   are never reassigned.
4. **Nil-embedder degradation**: `embed` returning nil (or the stub returning
   nil in tests) must make V3 a no-op — the lexical path is the same code
   line, not an error branch. All existing `TaskGrouper` tests run unmodified
   against a nil embedder.
5. **Merge suggestions** (§V5.2): weekly pass alongside the radar miner —
   pairwise cosine over active-task centroids ≥ 0.9 *and* overlapping
   sources ⇒ upsert suggestion. Never auto-merge.
6. **`TaskStore.merge(survivor:absorbed:)`**: repoint `activities.task_id`,
   delete absorbed task, mark suggestion `merged`, rebuild `task_logs` and
   work notes for affected days (absorbed task's work-note files are removed;
   content re-lands under the survivor on rebuild). Survivor keeps its
   user-chosen name. Dismissed suggestions stay dismissed (unique pair key).
7. **UI**: merge suggestion rows inline in the Vault tab task list —
   "These look like one task — Merge / Dismiss". Threshold slider does **not**
   ship (settings key only; minimalism — revisit if dogfooding demands it).

**Tests:** stub-embedder assignment above/below threshold; fallback parity
(nil embedder ⇒ byte-identical grouping to today); idempotence (same window
twice ⇒ same assignments and centroids); merge repoints activities, rebuilds
logs/notes, preserves survivor name; dismissed pair never re-suggested;
signature written once and stable across re-analysis.

**Verification (exit, §V9):** on dogfood data, previously fragmented efforts
(two slugs, one effort) visibly consolidate for *new* activity; zero unwanted
merges (all merges were clicked).

**Risk to retire early:** NLEmbedding sentence-embedding quality on terse
signatures ("debugging capture daemon; ShifuCore.swift; github.com"). Day-one
spike: embed 50 real signatures from the dogfood DB, eyeball nearest-neighbor
pairs, pick the threshold default from that data. If separation is poor, stop
— V3 waits for a better on-device embedder rather than shipping bad clusters
(log it in design.md §12).

---

## Phase V4 — Projects & Semantic Search

**Goal:** a project is a one-page honest status; search understands
paraphrase (§V2.2, §V4).

Order of work:

1. **`ProjectNoteCompiler`** (new): weekly (settings-gated like the radar
   pass) + on-demand from UI/CLI. Compiles `vault/projects/<slug>.md`: time
   totals (all-time / last 7 days from `task_logs`), active tasks with
   wiki-links to their latest work notes, then an optional LLM status
   paragraph built from the last week's work-note summary lines (token-
   budgeted; skipped without a backend — the deterministic sections are the
   note). Idempotent full rewrite each compile; `content_hash` gates the LLM
   paragraph exactly like V2.
2. **Migration v9**: `project_suggestions` (`task_id` unique, `project_id`,
   `cosine`, `status`, `created_at`).
3. **Task → project suggestions** (§V5.3): in the weekly pass, an unassigned
   active task whose centroid's cosine to a project centroid (mean of member
   task centroids) clears the threshold ⇒ suggestion. UI: one-tap "Add to
   *X*?" row under Projects; accept assigns (existing path) and recompiles
   the project note; dismiss is remembered per (task, project).
4. **`vault_vectors`** (same migration): `note_id` TEXT PK, `embedding` BLOB.
   Populated in `VaultIndexer.reconcile` for new/changed notes (embed title +
   first ~500 chars of body); deleted with the index row.
5. **Hybrid search**: `VaultSearch` gains reciprocal-rank fusion of bm25
   top-k and cosine top-k (brute-force scan of `vault_vectors` — at 10k notes
   × 512 dims this is a few ms; no ANN index until measured otherwise).
   Nil embedder ⇒ bm25-only, silently. CLI and UI use hybrid by default;
   `--exact` forces bm25-only.
6. **Perf**: extend the `make perf` vault case with hybrid search at 10k
   notes; budget stays < 50 ms.
7. **Docs sweep**: design.md §5.3 gets a one-line pointer to
   vault-features.md phases as shipped; deferred items (RAG chat, retro-
   clustering, weekly synthesis) confirmed logged in vault-features.md §10 /
   design.md §12, not built.

**Tests:** project note compile determinism + hash-gated LLM paragraph;
suggestion accept/dismiss persistence; vector upsert/delete follows index
lifecycle; RRF ranking (seeded stub embedder: paraphrase query ranks target
note first); `--exact` and nil-embedder parity with V1 behavior.

**Verification (exit, §V9):** the project note for a real ongoing effort
reads as an honest one-page status (subjective gate, like the glow); a
paraphrased query ("that thing about single screenshots without a stream")
finds a note bm25 misses.

---

## Cross-Cutting

- **Dogfooding is the gate.** Each phase runs on the author's real vault/day
  for its verification window before the next phase starts. V1→V2→V3→V4 is
  strictly ordered (V2 needs V1's indexer hooks; V3 needs V2's work-note
  rebuild for merges; V4 needs V3's centroids).
- **Privacy invariants as tests**, extended: work/project notes contain no
  text from `private` activities (test seeds a private block and greps the
  vault tree); date-range forget leaves no note content in range; `shifud`
  network-symbol check unchanged and still passing (nothing here should even
  link differently).
- **Subagent delegation** per implementation.md: good fits are the FTS
  indexer + sanitizer, the synthetic-vault perf generator, `FrontMatter`
  extraction, and the RRF/cosine helpers. The analyzer reordering (V2.2),
  `TaskStore.merge`, and `DeletionTools` vault pass are privacy/data-integrity
  adjacent — main session or dedicated review pass against §V7.
- **Minimalism check per phase**: re-read the §V section, cut anything the
  exit criteria don't need (already pre-cut: in-app note editing, threshold
  UI, ANN index, retro-clustering).

## Sequencing & Effort (rough)

| Phase | Depends on | Rough size | Ships |
|---|---|---|---|
| V1 Index & search | M3 vault | 3–4 days | migration v7, VaultIndexer, VaultSearch, CLI, tab search, perf case |
| V2 Work notes | V1 | 1 week | WorkNote, compiler, analyzer reorder, task_key stamping, deletion pass |
| V3 Clustering | V2 | 1 week (incl. embedding spike) | migration v8, Embedder, TaskGrouper assignment, merges |
| V4 Projects & semantic | V3 | 3–4 days | migration v9, project notes, suggestions, vault_vectors, hybrid search |

Two natural stopping points: after V2 the vault is already a complete,
searchable second brain (clustering and semantics are quality multipliers,
not prerequisites); after V3 if the V4 LLM status paragraphs don't earn
their tokens, project notes ship deterministic-only.
