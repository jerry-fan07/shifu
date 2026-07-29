# Vault Features — Shifu Second Brain

**Date:** 2026-07-18
**Status:** Draft v2 (replaces the v1 stub; extends design.md §5)
**Scope:** evolves the vault from a flashcard folder + task list into a queryable
second brain: everything the user worked on, distilled into Markdown, clustered
into tasks by meaning, rolled up into themes.

---

## 1. Vision

Raw observations are ephemeral (14-day retention, design.md §3.5). The vault is
what survives: a permanent, portable, plain-Markdown record of *what the user
did, learned, and worked toward*. Three properties define it:

1. **Complete** — every non-private working session leaves a distilled trace
   (a work note, and for substantial tasks an overview document).
2. **Queryable** — full-text (later semantic) search across everything, from the
   CLI and the Vault tab. "What did I read about SQLite WAL?" has an answer.
3. **Organized by meaning** — sessions cluster into tasks by what they're
   *about*, not just which app was frontmost; tasks roll up into themes.

Everything here runs in `shifu-analyzer` or the UI. `shifud` is untouched — no
new capture, no new daemon code paths (invariant 1).

### What already exists (baseline)

- Knowledge notes with FSRS review and decks (§5.1–5.2, shipped M3).
- `TaskGrouper`: lexical task keys (`topic:` → `domain:` → `app:`), renameable
  tasks, idempotent per-day `task_logs` with deterministic "where — what"
  summaries (§5.3).
- Task filing with time totals and per-theme review decks (originally
  user-created projects; §5.3 replaced them with themes).
- Vault tab: today's compiled log, recent tasks, themes.

This spec builds on that baseline; nothing shipped is thrown away.

---

## 2. Note Model

The vault becomes a small taxonomy of note kinds, all plain Markdown with YAML
frontmatter, all readable in Obsidian, all indexed for search (§4).

```
~/Shifu/vault/
  YYYY/MM/*.md              # knowledge notes: deck cards
  work/YYYY/MM/DD-<task-slug>.md   # work notes: one per task per local day
  tasks/<task-slug>.md      # overview documents: one living doc per task
```

Frontmatter carries a `kind: knowledge | work | task_overview` field. An
**absent** field means `knowledge` — pre-V1 notes never wrote one — but an
unrecognized *string* is deliberately not knowledge: `FrontMatter.Document.kind`
is `Kind?`, and nil fails the `== .knowledge` / `== .work` guards for free. That
is what keeps a note written by a newer binary out of an older one's inbox and
review queues while the two share a vault. The index stores the raw string
(`rawKind`), so an unparseable kind round-trips rather than being relabelled.

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

## Notes
### What was worked on
Tracked down why the AX observers survived a pause and kept writing.

### Learned / decided
- Pause has to tear observers down, not gate writes — a gated write still
  means the observer ran, which is the thing the user asked to stop.

### Problems → fixes
- RSS climbing past budget after the fix → the observer array was retaining
  its callbacks; clearing it on teardown brought it back to 62 MB.

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
- **`## Notes` is the detailed tier**, and the tier rule is the day's
  *dominant* category: work or learning earns the document, everything else
  keeps the short form. Dominance rather than presence, so an afternoon of
  admin with twenty minutes of reading in it stays light. Detailed days get
  more evidence per activity (2 000 chars vs 800) and a bigger response budget
  (1 200 tokens vs 400). The model is told to emit the literal `## Notes` line;
  the response is split on it, and a model that ignores the instruction has
  written session bullets and nothing else — which is exactly the light shape,
  so it degrades rather than fails.
- **`## Captured`** wiki-links the day's knowledge notes for that task, tying
  the two note kinds together in Obsidian's graph. Deck cards are excluded
  (`deck_key IS NULL`): they carry the task key and are captured on the day
  their deck was *built*, so without that filter one deck build would file
  twenty cards under a single day's work as if that day had produced them.
- Rebuild semantics mirror `TaskGrouper.rebuildLogs`: recompiled from scratch
  for every (task, day) an analyzer window touches, written via `VaultStore`
  (stable path from ULID prefix, same as knowledge notes). Narrative sections
  are regenerated only when the day's underlying activities changed (hash of
  activity ids + text sample), so re-analysis doesn't burn tokens rewriting
  identical prose. **Both prose sections carry across an unchanged day** —
  carrying only the bullets would silently delete `## Notes`, and the hash gate
  would then never regenerate it, the day being unchanged by definition.

### 2.1b Task overview documents

One living document per task, `vault/tasks/<task-slug>.md`, `kind:
task_overview`. The day notes are the diary; this is the documentation — a
three-week task has twenty day notes and nowhere that says what it *is*.

```yaml
# ~/Shifu/vault/tasks/shifu-capture-daemon.md
---
id: 01J3B…
kind: task_overview
task_key: topic:shifu-capture-daemon
task: Shifu capture daemon
updated: 2026-07-29T04:30:50Z
input_hash: -8731917865741463329
---
## Status
…2-4 sentences on where the task stands right now.

## Timeline
- **Phase 1 (2026-07-18 → 07-21)** — …

## Key knowledge
- …what was learned that outlives the task, with the why.

## Open threads
- …what is unfinished, unanswered, or waiting.
```

- **Complete replacement, not an append.** "Where does this stand" changes as
  the task goes on, so the document is rewritten in full each time.
- Eligibility mirrors the day-note tier: dominant category work or learning,
  ≥30 min logged. The tasks with documented days are exactly the ones with
  documentation worth compiling.
- **`input_hash` covers *completed* days only.** Today's note is still growing;
  including it would regenerate the document on every hourly run. Gating on
  finished days caps it at one generation per task per day — the same
  discipline as `ThemeClusterer.refreshNarratives`.
- The kind is load-bearing: `Note.parse` and `WorkNote.parse` both reject it,
  so a compiled document can never reach the inbox or the review queue.

### 2.1c Deck cards

A card is an ordinary knowledge note carrying `deck: deck:<slug>` (design.md
§5.2). That stamp is all a deck is on disk; `vault_index.deck_key` mirrors it
so membership and counts are one indexed query, and the count is *always*
derived — the user prunes during review, so a stored count would drift.

Deck writes dedupe **only within their own deck**. The vault-wide
`mergeIfDuplicate` could match a requested card against an unrelated inbox
note, bump *that* note's `seen_count`, and leave the deck quietly short a card
with no `deck:` stamp to show where it went. Same-deck dedupe is also O(deck)
rather than O(vault).

### 2.2 Project notes — **superseded (v14)**

Shipped, then removed with the project layer. One note per project, recompiled
weekly with an LLM status paragraph. Themes replaced projects (§5.3) and have
no note of their own: a theme's running narrative lives in `themes.summary`
and renders on the theme page, so there is no file to recompile and no weekly
token spend. Reinstate this as a *theme* note only if the vault needs it on
disk; the DB already holds the prose.

### 2.3 Knowledge notes

Every knowledge note is a **card**: a Q/A pair, born `kept` with FSRS seeded,
written by a deck the user asked for (§2.1c). Automatic extraction and the
triage inbox it fed are gone (design.md §5.1).

Cards carry `task_key`, stamped from the deck's task, which is what lets a
task- or theme-scoped review deck find them without slug matching.

---

## 3. Ingestion Pipeline

```
activities (per analyzer window)
  ├─► TaskGrouper ──────────► task assignment + task_logs
  ├─► WorkNoteCompiler ─────► work notes, two tiers (§2.1)
  ├─► TaskOverviewCompiler ─► task overview docs (§2.1b)
  └─► DeckBuilder.drainPending ──► deck cards (§2.1c)

weekly:
  └─► DeckSuggester ────────► deck_suggestions → Cards home

on request (app launches `shifu-analyzer --build-deck <key>`):
  └─► DeckBuilder ──────────► deck cards, kept + FSRS-seeded
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

- `vault_index` table: path, note id, kind, task_id, `deck_key`, captured,
  content hash. Plus an FTS5 table over (title, body) with bm25 ranking.
  `deck_key` mirrors the note's `deck:` frontmatter and is rebuildable from it
  like every other column here — it is what makes deck membership, deck card
  counts, and deck-scoped dedupe one indexed query each.
- Incrementally maintained by `VaultStore.save` and a reconcile pass in each
  analyzer run (mtime + hash catches external edits from Obsidian et al.).
  `shifu vault reindex` rebuilds from zero; deleting the index loses nothing.
- **CLI:** `shifu vault search <query> [--task] [--kind] [--since]`
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

> **Status (2026-07):** §5.1 auto-assignment stays deferred — the NLEmbedding
> spike showed separation too weak (design.md §12); §5.2–5.3 shipped. The
> fragmentation itself was fixed at the lexical layer instead: the classifier
> prompt anchors topic wording to recent topics, new keys must clear a 5-min
> substance gate before minting a task, and stale sub-threshold tasks are
> pruned (design.md §5.3).

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

### 5.2 Merge suggestions and auto-merge

Two tasks whose centroids reach cosine ≥ 0.9 with overlapping sources generate
a **merge suggestion**: "These look like one task — merge?" User confirms →
activities re-point, work notes re-key on next rebuild, the survivor keeps the
user-chosen name. Dismissals are remembered (same policy as Radar §6.2).

**Auto-merge.** The original rule here was "never auto-merge — merging silently
would destroy user naming and history". Dogfooding falsified the premise rather
than the concern: on 1,183 tasks the weekly pass had opened **679** suggestions,
and 582 of them had a side with under five minutes on it. A queue that long is
not a queue — it buries the task list and nobody drains it. So `TaskMerges.autoMerge`
now folds the unambiguous end of it, keeping the *guarantee* the rule was
protecting rather than the rule:

| Pair | Bar to fold automatically |
|---|---|
| Smaller side under `TaskGrouper.minNewTaskMs` (5 min) — a **fragment** | the ordinary 0.9 suggestion threshold |
| Both sides substantial | `tasks.auto_merge_threshold`, default **0.97** |

and never, at any score:

- either task carries a name the **user typed** (`TaskGrouper.isDefaultName` —
  which now answers the question for `sem:` keys too, since a semantic task's
  key is the slug of the LLM title that named it);
- the two sit in **different projects** — filing them apart by hand is a
  judgement that they are different work;
- the pair was **dismissed**.

Folding a fragment is the conservative option, not the risky one: `TaskStore.prune`
already *deletes* a default-named sub-five-minute task once it goes quiet, and a
merge keeps its time in the ledger instead of orphaning it. Chains collapse to one
survivor (the longest-running member), but only fragments ride a chain — a
substantial task must have scored ≥ 0.97 against that survivor directly, so two
real tasks are never joined through a chain of scraps. The pass repeats until it
folds nothing, and the whole batch shares one log rebuild and one work-note
recompile. Measured on the dogfood DB: 679 open pairs → 92, 161 tasks folded
(159 of them fragments), 0.07 s.

### 5.3 Task → theme suggestions

The same vectors give theme suggestions for free: an unthemed task whose
centroid sits near a theme's task centroids gets a one-tap "Add to *Shifu
development*?" row. Manual assignment remains the primary path; suggestions
are a shortcut, not an autopilot.

Themes replaced projects outright (v14: the `projects` table, project notes
and their compiler, and the `--project` search filter are all gone). Projects
were user-created folders a task was filed into by hand, and v17 brings themes
back to that: the user makes them, the clusterer only *files into* them and
*suggests* the ones it thinks are missing (design.md §5.3). A task's theme
is derived, not stored: filing is per block (`activities.theme_key`), and a
task's theme is the one its time mostly sits in. Picking one from the Task
log's row menu writes *all* of that task's blocks, so the label always matches
the choice; clearing one burns `theme_attempts` so the next clusterer run
can't quietly undo it.

Hand filing also sets `activities.theme_user_set`, and that — not theme
membership — is what prune and auto-merge treat as "the user judged this".
Membership can't do the job: the clusterer themes nearly every block, so
gating on it would switch both mechanisms off. Measured on the dogfood DB at
15% clustered, prune reaps 167 tasks with the marker vs 172 with no gate at
all; gating on plain membership would have decayed toward 0 as clustering
caught up.

---

## 6. UI (Vault tab)

Stays one screen (design principle 2). Top to bottom:

1. **Search field** (§4) — the tab's headline feature once this ships.
2. **Today** — compiled log, as today, but each row now opens its work note.
3. **Tasks** — recent tasks with latest log line; the strongest few merge
   suggestions appear inline here (accept / dismiss), capped at
   `LedgerStore.suggestionLimit`. Everything past the cap is a
   "Review N more suggestions" row into **Merge review** (`MergeReviewView`) —
   the one screen this tab is allowed to grow, because a queue that outnumbers
   the task list can't be triaged inline and needs a bulk *Dismiss all*.
4. **Projects** — time totals; each opens its project note; pending
   task-assignment suggestions inline (also capped, same review screen).

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
