---
name: dogfood
description: Query or replay the real ~/Shifu data — a consistent copy, SHIFU_HOME at the copy, and the standing dirt checks. Use when picking thresholds, verifying ShifuCore/analyzer changes against real data shapes, doing LLM cost/usage work, or adding a migration.
---

# The dogfood database

Unit fixtures are too clean to mean anything: a real day is ~200 activity
blocks of 20–60 seconds at ~147 captures/hour (measured 2026-07-28), names
run to 60 characters, and sessions straddle midnight. Thresholds and claims
come from `~/Shifu` — but never point anything at `~/Shifu` itself: the
daemon is writing it, and most Shifu binaries open the DB read-write.

## Take a copy

```bash
DOG=$(mktemp -d)
sqlite3 ~/Shifu/shifu.db ".backup $DOG/shifu.db"   # consistent even mid-write
cp -R ~/Shifu/vault "$DOG/vault"                   # only if the change reads the vault
```

`.backup` beats `cp shifu.db*`: it folds the WAL in and cannot tear on a
checkpoint landing mid-copy. Open the copy plainly — `sqlite3 -readonly`
fails on a fresh WAL copy with "unable to open database file" (no `-shm`
yet), and the copy is yours to write anyway. Ignore `~/Shifu/shifu.sqlite`;
nothing reads it.

Every binary honors `SHIFU_HOME` (`ShifuPaths.swift`):

```bash
SHIFU_HOME="$DOG" swift run shifu status           # or log / vault search / review
SHIFU_HOME="$DOG" swift run shifu-analyzer --force
```

## A replay spends real money unless you cut the cord

The copy carries the live LLM opt-in (`analysis.backend`,
`deepseek.api_key`, `shifu_cloud.token`), so an analyzer replay makes real,
billed calls. For an offline replay, blank the opt-in in the copy first — no
backend is ever preselected (§8), so with those rows gone the LLM stages
skip and the deterministic stages still run:

```bash
sqlite3 "$DOG/shifu.db" "DELETE FROM settings WHERE key IN
  ('analysis.backend','deepseek.api_key','shifu_cloud.token');"
```

`--force` overrides the on-battery skip; `--rebuild` widens the incremental
window from 48 h to all of history.

## Standing dirt checks

The consolidated schema lives in ARCHITECTURE.md. These checks exist because
each has already produced a wrong conclusion once:

**Duplicate ledger spans.** A rebuild bug once left 5 spans × 15 copies —
76% of the ledger, 103 hours in one day on the Time page. Clean as of
2026-08-01; re-earn the check whenever `LedgerBuilder` changes:

```sql
SELECT started_at, ended_at, COUNT(*) FROM activities
GROUP BY started_at, ended_at HAVING COUNT(*) > 1;
```

**task_logs cross-foot.** A timezone change once stranded duplicate day rows
(~2× totals). `UNIQUE(task_id, day_start)` now guards it and
`shifu-analyzer --rebuild` heals it, but per-day sums should still roughly
agree with the ledger:

```sql
SELECT date(day_start/1000,'unixepoch','localtime') AS day,
       ROUND(SUM(duration_ms)/3600000.0, 1) AS hours
FROM task_logs GROUP BY day ORDER BY day DESC LIMIT 7;
```

**Migrations: read the DB, not the source.** Parallel workspaces pick "the
next version" independently and GRDB skips a duplicate identifier silently
(ARCHITECTURE.md §7). This DB has run `v19` *and* `v19-llm-usage`, and two
different v25s. Before adding one: `SELECT identifier FROM grdb_migrations;`
on the copy, and name yours `vNN-slug`.

**llm_usage prices by prefix, two slots only.** `model` is whatever the
server put on the invoice, and anything that isn't the reasoning model
prices as *fast* (`LLMPriceBook`) — 66 rows are a local `.gguf` path (the
Qwen blind week) and poison any naive rollup at flash rates. Blank price
settings mean DeepSeek's published rates, never $0. Filter before claiming a
cost:

```sql
SELECT model, stage, COUNT(*), SUM(prompt_tokens), SUM(completion_tokens)
FROM llm_usage WHERE model LIKE 'deepseek%' GROUP BY model, stage;
```

## Cost work starts from the findings doc

`../LLM-COST-FINDINGS.md` sits above every worktree (deliberately outside
the repo, so all branches read one copy) with the measured baselines and
ranked levers — read it before re-deriving any number. `sh ../llm-profile.sh`
answers "which model is Shifu actually talking to" and can flip
local ↔ cloud; it honors `SHIFU_HOME` too.
