# Vault Features — Shifu Second Brain

**Date:** 2026-07-18
**Status:** Draft v2 (replaces the v1 stub; extends design.md §5)
**Scope:** evolves the vault from a flashcard folder + task list into a queryable
second brain: everything the user worked on, distilled into Markdown, clustered
into tasks by meaning, rolled up into projects.

---

## 1. Vision

Raw observations are ephemeral (14-day retention, design.md §3.5). The vault is
what survives: a permanent, portable, plain-Markdown record of *what the user
did, learned, and worked toward*. Three properties define it:

1. **Complete** — every non-private working session leaves a distilled trace,
   not just sessions that produced a flashcard.
2. **Queryable** — full-text (later semantic) search across everything, from the
   CLI and the Vault tab. "What did I read about SQLite WAL?" has an answer.
3. **Organized by meaning** — sessions cluster into tasks by what they're
   *about*, not just which app was frontmost; tasks roll up into user-defined
   projects.

Everything here runs in `shifu-analyzer` or the UI. `shifud` is untouched — no
new capture, no new daemon code paths (invariant 1).

### What already exists (baseline)

- Knowledge notes with FSRS review, inbox triage, decks (§5.1–5.2, shipped M3).
- `TaskGrouper`: lexical task keys (`topic:` → `domain:` → `app:`), renameable
  tasks, idempotent per-day `task_logs` with deterministic "where — what"
  summaries (§5.3).
- User-created projects with task assignment, time totals, project review decks.
- Vault tab: today's compiled log, recent tasks, projects.

This spec builds on that baseline; nothing shipped is thrown away.

---

## 2. Note Model

The vault becomes a small taxonomy of note kinds, all plain Markdown with YAML
frontmatter, all readable in Obsidian, all indexed for search (§4).

```
~/Shifu/vault/
  YYYY/MM/*.md              # knowledge notes (existing layout, unchanged)
  work/YYYY/MM/DD-<task-slug>.md   # work notes: one per task per local day
  projects/<project-slug>.md       # project notes: one per project, recompiled
```

Frontmatter gains a `kind: knowledge | work | project` field (absent = 
`knowledge`, so existing notes need no migration).

### 2.1 Work notes

The Markdown twin of a `task_logs` row — same (task, day) granularity, same
idempotent rebuild, but with room for substance:

```yaml
# ~/Shifu/vault/work/2026/07/18-shifu-capture-daemon.md
---
id: 01J3A…                  # ULID
kind: work
task_key: topic:shifu-capture-daemon
day: 2026-07-18
duration_ms: 9840000
sources: [Xcode, github.com, developer.apple.com]
sessions:
  - {start: "09:12", end: "10:41"}
  - {start: "14:03", end: "15:20"}
project: shifu              # slug, if the task is assigned
---
Xcode, github.com — debugging capture daemon; reading SCK docs

## Sessions
- **09:12–10:41** — Chased the AX observer leak; landed on tearing down
  observers in `pause()` rather than gating writes. Read GRDB WAL docs.
- **14:03–15:20** — Perf harness run; RSS at 62 MB after fix.

## Captured
- [[17-scrncapturekit-single-frame]]
```

- **Line 1 of the body is always the deterministic "where — what" summary** the
  ledger already computes. If the LLM is unavailable, the note is still valid
  and useful — narrative sections are additive, never required.
- **`## Sessions`** is LLM-written from the day's activity text samples for that
  task: what happened, what was accomplished. Skipped for tasks below a
  substance threshold (default: < 10 min or no text content) — a 45-second
  glance at a dashboard does not earn a paragraph.
- **`## Captured`** wiki-links any knowledge notes extracted from the same
  activities, tying the two note kinds together in Obsidian's graph.
- Rebuild semantics mirror `TaskGrouper.rebuildLogs`: recompiled from scratch
  for every (task, day) an analyzer window touches, written via `VaultStore`
  (stable path from ULID prefix, same as knowledge notes). Narrative sections
  are regenerated only when the day's underlying activities changed (hash of
  activity ids + text sample), so re-analysis doesn't burn tokens rewriting
  identical prose.

### 2.2 Project notes

One per project, recompiled by the analyzer (weekly by default, and on demand
from the UI): total and recent time, active tasks with their latest work-note
links, and a short LLM status paragraph ("where this effort stands"). This is
the project's "separate vault" from the v1 stub — not a second folder tree, but
a compiled index note that makes the project navigable from any editor.

### 2.3 Knowledge notes

Unchanged (§5.1). One addition to frontmatter: `task_key`, stamped at
extraction time from the source activity, replacing the current slug-matching
heuristic for deck membership with an explicit link.

---

## 3. Ingestion Pipeline

```
activities (per analyzer window)
  ├─► TaskGrouper ──► task assignment + task_logs        (existing)
  ├─► KnowledgeExtractor ──► knowledge notes → inbox     (existing)
  └─► WorkNoteCompiler ──► work notes (§2.1)             (new)
            └─► weekly ──► ProjectNoteCompiler (§2.2)    (new)
```

`WorkNoteCompiler` runs after `TaskGrouper` in the same analyzer pass, reading
the freshly assigned `activities.task_id` rows. Constraints:

- **Redaction is upstream** (invariant 2): activity text was redacted before it
  ever reached SQLite, so notes inherit that. No new choke point needed, but
  the compiler must never reach back to raw observations — activities only.
- **`private` activities never reach any note** (same filter TaskGrouper uses).
- **Token budgets** (invariant 7): session narratives are batched per task-day
  with `LLMTokens.estimate` against the backend's `contextWindowTokens`. On the
  4k on-device window this means one task-day per prompt with truncated text
  samples; that is fine — quality over coverage, and the deterministic line 1
  always exists.

---

## 4. Query Layer

The Markdown tree stays the source of truth; SQLite gets a **disposable index**
so the vault is queryable without ever locking users into the DB.

- `vault_index` table: path, note id, kind, task_id, project_id, captured,
  content hash. Plus an FTS5 table over (title, body) with bm25 ranking.
- Incrementally maintained by `VaultStore.save` and a reconcile pass in each
  analyzer run (mtime + hash catches external edits from Obsidian et al.).
  `shifu vault reindex` rebuilds from zero; deleting the index loses nothing.
- **CLI:** `shifu vault search <query> [--task] [--project] [--kind] [--since]`
  → ranked snippets with file paths.
- **UI:** a search field on the Vault tab; results open the note in-place, with
  "Reveal in Finder" for editing elsewhere.

**Semantic search is a later phase** (§7): store an on-device sentence
embedding (`NLEmbedding`, NaturalLanguage framework — no model download, no
network) per note in a `vault_vectors` table; hybrid rank = bm25 ∪ cosine
top-k. It reuses the embedding machinery clustering already needs (§5), which
is why clustering ships first.

---

## 5. Semantic Task Clustering

The lexical key works but fragments meaning: "debugging capture daemon" and
"fixing shifud AX observer" are one effort with two topic slugs, so today they
become two tasks. Fix with embeddings, incrementally and reversibly:

### 5.1 Assignment (analyzer, per new activity block)

1. Build a **block signature**: topic + window titles sample + domain, one
   line of text.
2. Embed it with `NLEmbedding.sentenceEmbedding` (on-device, milliseconds,
   zero network — keeps the no-cloud default intact).
3. Compare against each active task's **centroid** (running mean of its
   blocks' vectors, stored as a BLOB on `tasks`; "active" = worked in the last
   30 days, so the comparison set stays small).
4. Cosine ≥ threshold (default 0.75, tunable in settings) → assign to that
   task and update its centroid. Below threshold → fall back to the existing
   lexical key, creating a task (and centroid) if the key is new.

Properties this preserves:

- **Idempotence**: assignment is recorded on `activities.task_id` exactly as
  today; re-analysis of a window re-derives it, but historical windows outside
  the analyzer's range are never reshuffled by a drifting centroid.
- **Renames survive**: clustering picks *which* task, never touches `name`.
- **Graceful degradation**: if `NLEmbedding` returns nil (rare languages,
  headless test envs), the lexical key path is the code path, not an error
  path — it's the same fallback line. All `TaskGrouper` tests keep passing
  with embeddings stubbed out.

### 5.2 Merge suggestions (never auto-merge)

Two tasks whose centroids reach cosine ≥ 0.9 with overlapping sources generate
a **merge suggestion** in the Vault tab: "These look like one task — merge?"
User confirms → activities re-point, work notes re-key on next rebuild, the
survivor keeps the user-chosen name. Dismissals are remembered (same policy as
Radar §6.2). Merging silently would destroy user naming and history — it stays
manual, permanently.

### 5.3 Task → project suggestions

The same vectors give project suggestions for free: an unassigned task whose
centroid sits near a project's task centroids gets a one-tap "Add to *Shifu*?"
row. Manual assignment remains the primary path; suggestions are a shortcut,
not an autopilot.

---

## 6. UI (Vault tab)

Stays one screen (design principle 2). Top to bottom:

1. **Search field** (§4) — the tab's headline feature once this ships.
2. **Today** — compiled log, as today, but each row now opens its work note.
3. **Tasks** — recent tasks with latest log line; pending merge suggestions
   appear inline here (accept / dismiss).
4. **Projects** — time totals; each opens its project note; pending
   task-assignment suggestions inline.

Spaced repetition stays on the *Cards* tab (§5.2) — decks now select by
explicit `task_key`/project instead of slug matching.

---

## 7. Privacy & Retention

Work notes change the exposure calculus and the spec must say so plainly:

- Today, detailed text dies with the 14-day observation window. Work-note
  narratives make a *distilled* form of it permanent. That is the feature —
  but it means: narratives are built from already-redacted activity text
  (invariant 2), `private`/excluded time never reaches a note, and the
  onboarding copy for the vault states that work notes persist.
- **Date-range delete ("forget this afternoon") must delete/recompile work
  notes covering the range**, not just DB rows. `DeletionTools` grows a vault
  pass; the note's `sessions` frontmatter makes affected files findable
  without parsing bodies.
- Vault encryption tradeoff unchanged (§8): off by default for editor interop,
  stated plainly in settings.
- Embeddings and the FTS index are derived, local, and disposable; they carry
  no data the notes don't.

---

## 8. Performance

| Metric | Target |
|---|---|
| shifud | zero change — no new daemon code |
| Embedding per block | < 5 ms on-device (NLEmbedding), analyzer-only |
| FTS index update per note | < 1 ms; reconcile pass O(changed files) |
| Vault search (10k notes) | < 50 ms end-to-end |
| Narrative tokens | budgeted via `LLMTokens.estimate`; skipped below substance threshold; regenerated only on content-hash change |

`make perf` gains a vault-search case once the index exists.

---

## 9. Phasing

Ordered so each phase is independently shippable and dogfoodable
(implementation.md style; Minimalism rule applies — cut anything a phase's
exit criteria don't need).

| Phase | Scope | Exit criteria |
|---|---|---|
| **V1 — Index & search** | `vault_index` + FTS5, reconcile pass, `shifu vault search`, Vault tab search field | A week-old fact is findable in one query from CLI and UI |
| **V2 — Work notes** | `WorkNoteCompiler`: deterministic line + LLM sessions, `## Captured` links, `task_key` frontmatter on knowledge notes, date-range delete covers notes | 1 week dogfooding: yesterday's work note answers "what did I do?" without opening the DB |
| **V3 — Clustering** | Embedding assignment + centroids, merge suggestions, threshold setting | Two-slug-one-effort fragmentation visibly drops on dogfood data; zero unwanted merges (they're all manual) |
| **V4 — Projects & semantic** | Project notes, project/task suggestions, `vault_vectors` + hybrid search | Project note is the honest one-page status of a real effort; a paraphrased query finds a note bm25 misses |

---

## 10. Deferred (log here, don't build — Minimalism rule)

- Cross-note LLM synthesis ("weekly review" essays spanning projects).
- Embedding model upgrades beyond NLEmbedding (bundled model — see design.md
  §12 MLX note; same economics).
- Full clustering re-runs over historical activities (retro-clustering old
  tasks). Suggest-merge covers the visible cases without rewriting history.
- Vault sync/multi-device (design.md non-goal).
- Chat-with-your-vault (RAG). The query layer is the prerequisite; the chat UI
  is not earned until search proves insufficient.

## 11. Open Questions

1. Work-note granularity: is one note per (task, day) right, or do long-lived
   tasks want a single rolling note per task with day sections? (Per-day keeps
   rebuilds local and files small; per-task reads better in Obsidian.)
2. Clustering threshold: fixed default vs. adaptive (per-user calibration from
   confirmed/dismissed merge suggestions)?
3. Should knowledge-note *deck* membership follow a task through a merge
   automatically, or is that a review-history mutation worth confirming?
4. Does the substance threshold for narratives (< 10 min → skip) need a
   per-category override (a 5-minute `learning` burst may be worth a line)?
