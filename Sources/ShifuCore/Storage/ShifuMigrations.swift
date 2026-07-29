import Foundation
import GRDB

/// The schema, one registered migration per version. Split from
/// ShifuDatabase.swift for length only — migrations are append-only, so
/// this file grows every schema change while the connection logic does not.
extension ShifuDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "observations") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("started_at", .integer).notNull()
                table.column("last_seen", .integer).notNull()
                table.column("app_bundle", .text).notNull()
                table.column("window_title", .text)
                table.column("url", .text)
                table.column("capture_kind", .text).notNull()
                table.column("text", .text)
                table.column("text_simhash", .integer)
                table.column("session_id", .integer)
            }
            try db.create(index: "idx_observations_started_at", on: "observations", columns: ["started_at"])
            try db.create(index: "idx_observations_session", on: "observations", columns: ["session_id"])

            // User-added exclusions, merged with the hardcoded defaults (§8).
            try db.create(table: "exclusions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()   // "bundle" | "domain"
                table.column("value", .text).notNull()
                table.uniqueKey(["kind", "value"])
            }
        }

        migrator.registerMigration("v2") { db in
            // Classified activity blocks — the ledger (design.md §4.1, §9).
            try db.create(table: "activities") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("started_at", .integer).notNull()
                table.column("ended_at", .integer).notNull()
                table.column("app_bundle", .text).notNull()
                table.column("domain", .text)
                table.column("category", .text).notNull()
                table.column("topic", .text)
                table.column("confidence", .double)
                table.column("source", .text).notNull().defaults(to: "rules")
                table.column("ambiguous", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_activities_started_at", on: "activities", columns: ["started_at"])

            // User classification overrides (design.md §4.2 tier 1, §9).
            try db.create(table: "rules") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()      // "bundle" | "domain"
                table.column("value", .text).notNull()
                table.column("category", .text).notNull()
                table.column("ambiguous", .boolean).notNull().defaults(to: false)
                table.uniqueKey(["kind", "value"])
            }
        }

        migrator.registerMigration("v3") { db in
            // Key/value settings (design.md §9): analysis backend, digest hour…
            try db.create(table: "settings") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            // Work Mode sessions, for adherence stats (design.md §4.4).
            try db.create(table: "work_mode_sessions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("started_at", .integer).notNull()
                table.column("ended_at", .integer)
            }
        }

        migrator.registerMigration("v4") { db in
            // Review log for later FSRS parameter fitting (design.md §5.2, §9).
            try db.create(table: "srs_reviews") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("note_id", .text).notNull()
                table.column("reviewed_at", .integer).notNull()
                table.column("grade", .integer).notNull()
                table.column("interval_days", .double)
            }
            // High-water mark for knowledge extraction (Phase 4).
            try db.alter(table: "activities") { table in
                table.add(column: "extracted", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5") { db in
            // Automation suggestions from the pattern miner (design.md §6, §9).
            try db.create(table: "suggestions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("created_at", .integer).notNull()
                table.column("pattern_key", .text).notNull().unique()
                table.column("kind", .text).notNull()          // ngram | frequent_visit | alternation
                table.column("evidence", .text).notNull()
                table.column("occurrences", .integer).notNull()
                table.column("avg_minutes", .double).notNull()
                table.column("est_minutes_saved_weekly", .double).notNull()
                table.column("title", .text)
                table.column("suggestion", .text)              // LLM description; nil until described
                table.column("confidence", .double)
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("dismissed_at_occurrences", .integer)
                table.column("snoozed_until", .integer)
            }
        }

        migrator.registerMigration("v6") { db in
            // Tasks & projects (design.md §5.3): activities group into tasks,
            // tasks group into user-created projects, per-day work logs.
            try db.create(table: "projects") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull().unique()
                table.column("created_at", .integer).notNull()
            }
            try db.create(table: "tasks") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("key", .text).notNull().unique()   // TaskGrouper.key
                table.column("name", .text).notNull()           // user-renameable
                table.column("project_id", .integer).references("projects", onDelete: .setNull)
                table.column("created_at", .integer).notNull()
                table.column("last_active_at", .integer).notNull()
            }
            try db.create(index: "idx_tasks_last_active", on: "tasks", columns: ["last_active_at"])
            try db.create(table: "task_logs") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("task_id", .integer).notNull().references("tasks", onDelete: .cascade)
                table.column("day_start", .integer).notNull()   // local-midnight unix ms
                table.column("duration_ms", .integer).notNull()
                table.column("summary", .text).notNull()
                table.uniqueKey(["task_id", "day_start"])
            }
            try db.alter(table: "activities") { table in
                table.add(column: "task_id", .integer)
            }
            try db.create(index: "idx_activities_task", on: "activities", columns: ["task_id"])
        }

        migrator.registerMigration("v7") { db in
            // Vault search index (vault-features.md §4). The Markdown tree is
            // the source of truth; these tables are disposable and fully
            // rebuildable from the files (`shifu vault reindex`).
            try db.create(table: "vault_index") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("note_id", .text).notNull().unique()
                table.column("path", .text).notNull()       // relative to vault root
                table.column("kind", .text).notNull()       // FrontMatter.Kind
                table.column("task_id", .integer)
                table.column("project_id", .integer)
                table.column("captured", .integer)          // unix ms
                table.column("content_hash", .integer).notNull()
                table.column("mtime", .integer).notNull()   // unix ms, for reconcile
            }
            try db.create(index: "idx_vault_index_kind", on: "vault_index", columns: ["kind"])
            try db.create(index: "idx_vault_index_task", on: "vault_index", columns: ["task_id"])
            try db.create(index: "idx_vault_index_project", on: "vault_index", columns: ["project_id"])
            // Full-text side, rowid tied to vault_index.id. Plain FTS5 (not
            // external-content): the duplicated text is disposable by design.
            try db.execute(sql: "CREATE VIRTUAL TABLE vault_fts USING fts5(title, body)")
        }

        migrator.registerMigration("v8") { db in
            // Durable one-line block signature (topic + title sample + domain,
            // vault-features.md §5.1). Window titles die with the 14-day
            // observation retention; the signature is the redacted, durable
            // input that lets task centroids be recomputed forever after.
            try db.alter(table: "activities") { table in
                table.add(column: "signature", .text)
            }
            // User-confirmed task merge suggestions (§5.2). No FK cascade:
            // rows outlive their tasks as an audit trail; the unique ordered
            // pair is what keeps dismissed pairs dismissed.
            try db.create(table: "task_merge_suggestions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("task_a", .integer).notNull()
                table.column("task_b", .integer).notNull()
                table.column("cosine", .double).notNull()
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("created_at", .integer).notNull()
                table.uniqueKey(["task_a", "task_b"])
            }
        }

        migrator.registerMigration("v9") { db in
            // Task → project suggestions (vault-features.md §5.3). task_id is
            // unique: at most one open/remembered suggestion per task.
            try db.create(table: "project_suggestions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("task_id", .integer).notNull().unique()
                table.column("project_id", .integer).notNull()
                table.column("cosine", .double).notNull()
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("created_at", .integer).notNull()
            }
            // Per-note sentence embeddings for hybrid search (§4). Disposable
            // like the rest of the index: rebuilt from the files on reindex.
            try db.create(table: "vault_vectors") { table in
                table.primaryKey("note_id", .text)
                table.column("embedding", .blob).notNull()
            }
        }

        migrator.registerMigration("v10") { db in
            // Bounds LLM re-billing on blocks that never clear the confidence
            // floor (design.md §4.2, §12): AmbiguousClassifier skips a block
            // once it has been attempted this many times, until the block's
            // text changes (a changed span resets the count via the rebuild
            // carry). Without this, an unchanged window re-bills the same
            // low-confidence blocks every run.
            try db.alter(table: "activities") { table in
                table.add(column: "llm_attempts", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v11") { db in
            // Semantic task grouping (design.md §5.3): the LLM assigns blocks
            // to intent-level tasks ("booking flights for the trip") instead
            // of the mechanical topic/domain/app key. `sem_key` holds the
            // assigned task key ("sem:<slug>"); NULL falls back to the
            // mechanical key. `sem_attempts` caps re-billing of blocks the
            // model declines to place, mirroring `llm_attempts`. Both are
            // carried across LedgerBuilder rebuilds by span identity.
            try db.alter(table: "activities") { table in
                table.add(column: "sem_key", .text)
                table.add(column: "sem_attempts", .integer).notNull().defaults(to: 0)
            }
            // One-sentence LLM gist of what a semantic task is about; shown on
            // the task detail page. NULL for mechanically keyed tasks.
            try db.alter(table: "tasks") { table in
                table.add(column: "gist", .text)
            }
        }

        migrator.registerMigration("v12") { db in
            // Theme layer (design.md §5.3): a second, *independent* LLM
            // clustering of blocks into 3–8 broad initiatives ("YC Startup
            // School", "travel"), coarser than semantic tasks and assigned
            // per block — a task's blocks may straddle themes. Same carry and
            // attempt-cap discipline as `sem_key`/`sem_attempts`.
            try db.alter(table: "activities") { table in
                table.add(column: "theme_key", .text)
                table.add(column: "theme_attempts", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "themes") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("key", .text).notNull().unique()   // "thm:<slug>"
                table.column("name", .text).notNull()           // user-renameable
                table.column("gist", .text)                     // LLM one-liner
                // Running narrative, regenerated only when the hash of the
                // theme's *completed* days changes — ~one generation per
                // active theme per day, never per hourly run.
                table.column("summary", .text)
                table.column("summary_hash", .integer).notNull().defaults(to: 0)
                table.column("created_at", .integer).notNull()
                table.column("last_active_at", .integer).notNull()
            }
            try db.create(index: "idx_themes_last_active", on: "themes", columns: ["last_active_at"])
        }

        migrator.registerMigration("v13") { db in
            // Task → theme suggestions, the theme-layer replacement for
            // `project_suggestions` (vault-features.md §5.3). Same shape and
            // same rule: task_id is unique, so a task has at most one
            // open/remembered suggestion and a dismissal is permanent.
            // `theme_key` rather than an id, because that is what
            // `activities.theme_key` files a block under.
            try db.create(table: "theme_suggestions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("task_id", .integer).notNull().unique()
                table.column("theme_key", .text).notNull()
                table.column("cosine", .double).notNull()
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("created_at", .integer).notNull()
            }
            // The task list, its filter, and the Themes rollups all read
            // "which blocks of this task sit in which theme".
            try db.create(index: "idx_activities_theme", on: "activities",
                          columns: ["theme_key"])
        }

        migrator.registerMigration("v14") { db in
            // Projects are gone; themes replaced them (vault-features.md §5.3).
            //
            // Two gates used `project_id` to mean "the user filed this by
            // hand, don't touch it silently": prune skipped filed tasks, and
            // auto-merge refused to fold two tasks filed apart. Theme
            // membership can't stand in for that — the clusterer assigns
            // themes to nearly every block, so gating on "has a theme" would
            // switch both off. So the *hand*-filed bit gets its own column,
            // written only by `TaskStore.assignTheme` (menus and accepted
            // suggestions), never by `ThemeClusterer`.
            try db.alter(table: "activities") { table in
                table.add(column: "theme_user_set", .integer).notNull().defaults(to: 0)
            }
            // Carry the old guarantee forward: blocks of a task that was
            // filed under a project are hand-filed, whatever put them in
            // their current theme.
            try db.execute(sql: """
                UPDATE activities SET theme_user_set = 1
                WHERE theme_key IS NOT NULL AND task_id IN
                      (SELECT id FROM tasks WHERE project_id IS NOT NULL)
                """)

            try db.drop(table: "project_suggestions")
            try db.drop(index: "idx_vault_index_project")
            try db.alter(table: "vault_index") { $0.drop(column: "project_id") }
            try db.alter(table: "tasks") { $0.drop(column: "project_id") }
            try db.drop(table: "projects")
        }

        migrator.registerMigration("v15") { db in
            // DeepSeek is the only LLM backend now (design.md §4.2): the
            // on-device Foundation Models tier was dropped (4k window,
            // macOS 26+ only, weak labels) and the Claude tier with it.
            // Collapse every legacy backend choice to the two that remain —
            // the API key stays the opt-in, so a machine without one keeps
            // running rules-only exactly as before.
            try db.execute(sql: """
                UPDATE settings SET value = 'deepseek'
                WHERE key = 'analysis.backend' AND value != 'off'
                """)
            // Carry the connection settings over to their deepseek.* names;
            // the Claude key has no equivalent and is deleted, not orphaned.
            // A legacy model choice lands in the *reasoning* slot: the single
            // legacy model handled the judgment-heavy grouping stages, so
            // that is the slot whose behavior it should keep. The fast slot
            // picks up the deepseek-v4-flash default.
            try db.execute(sql: """
                UPDATE settings SET key = replace(key, 'openai.', 'deepseek.')
                WHERE key IN ('openai.api_key', 'openai.base_url')
                """)
            try db.execute(sql: """
                UPDATE settings SET key = 'deepseek.reasoning_model'
                WHERE key = 'openai.model'
                """)
            try db.execute(sql:
                "DELETE FROM settings WHERE key IN ('claude.api_key', 'claude.model')")
        }

        migrator.registerMigration("v16") { db in
            // Radar now judges *tasks*, not domains (design.md §6.1): a
            // suggestion carries the model's own sizing of the work, so the
            // honest "setup ≈30 min" the UI shows is a stored fact rather
            // than a mechanical guess, and `teach` carries the one capability
            // the user may not know exists — the point of the tab.
            try db.alter(table: "suggestions") { table in
                table.add(column: "setup_minutes", .double)
                table.add(column: "teach", .text)
            }
            // Every existing *description* is domain-altitude debris
            // ("google.com visited 255× → set up Google Analytics 4"), and
            // suggestions are derived state, re-mined weekly — so the text
            // goes and the queue starts clean.
            //
            // Dismissal memory is the one thing worth carrying, and it only
            // carries where a key still means the same thing: `freq:<domain>`
            // survives the rewrite unchanged (same prefix, same detector, same
            // 10-visits-a-day threshold), so a user who dismissed one keeps
            // having dismissed it. `ngram:`, `alt:` and the old `freq:<app>`
            // keys the miner can no longer mint go, along with every open row.
            try db.execute(sql: """
                DELETE FROM suggestions
                WHERE status = 'new' OR pattern_key NOT LIKE 'freq:%.%'
                """)
            // What survives is a dismissal, not advice: clear the old text so
            // a resurfaced row is judged fresh by the new describer.
            try db.execute(sql: """
                UPDATE suggestions SET title = NULL, suggestion = NULL, confidence = NULL
                """)
        }

        migrator.registerMigration("v17") { db in
            // Themes belong to the user (design.md §5.3). The clusterer still
            // files blocks into themes that *exist*, but a theme it invents no
            // longer appears in the Themes grid on its own — it lands here as a
            // proposal to accept or dismiss.
            //
            // `key` is unique, so a re-proposal of the same initiative updates
            // one row rather than piling up, and a dismissal is permanent —
            // the same rule the merge and task→theme queues already follow.
            // Deleting a theme records a dismissed row under its key too, so
            // the next run can't quietly propose back what the user just threw
            // away.
            try db.create(table: "theme_proposals") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("key", .text).notNull().unique()   // "thm:<slug>"
                table.column("name", .text).notNull()
                table.column("gist", .text)
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("created_at", .integer).notNull()
            }
            // The blocks the model put behind a proposal. Without them,
            // accepting would mint a named, empty theme and the user would
            // wait an hour for the next run to fill it — and the blocks that
            // burned `theme_attempts` getting proposed would never arrive.
            try db.create(table: "theme_proposal_blocks") { table in
                table.column("proposal_id", .integer).notNull()
                    .references("theme_proposals", onDelete: .cascade)
                table.column("activity_id", .integer).notNull()
            }
            try db.create(index: "idx_theme_proposal_blocks",
                          on: "theme_proposal_blocks",
                          columns: ["proposal_id", "activity_id"], unique: true)
            // Existing themes are grandfathered, not demoted: they carry the
            // user's renames, their narratives, and the blocks already filed
            // under them. Deleting is now a first-class action, so the ones
            // the clusterer minted and the user never wanted can just go.
        }

        return migrator
    }
}
