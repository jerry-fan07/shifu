import Foundation
import GRDB

/// The deadline schema (design.md §4.5), split from ShifuMigrations.swift for
/// length only. Registration order is what GRDB runs, so the one caller
/// invokes this at the end of the sequence.
extension ShifuDatabase {
    static func registerDeadlineMigrations(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v29-deadlines") { db in
            // One table, and deliberately **not** a `tasks.due_at` column.
            //
            // Tasks are derived objects: `TaskGrouper` mints them, the semantic
            // pass renames them, `TaskPrune.prune` and `TaskStore.merge` *hard
            // delete* them (`DELETE FROM tasks`). A date the user typed by hand
            // is the one piece of task-shaped state in Shifu that no pipeline
            // may throw away, so it cannot live on a row a pipeline deletes.
            // A separate row with a nullable link survives both: the FK sets
            // itself to NULL and the deadline keeps its date, having lost only
            // the thing it was measuring progress against.
            //
            // The nullable link earns its keep twice more: a commitment can
            // exist before any task does (nothing has been worked on yet), and
            // one task can carry several — which is what "critical timeline"
            // means as opposed to "due date".
            //
            // Numbered v29 with a name suffix because the number alone is not
            // safe: this repo has run two v25s, two v27s and three v28s from
            // parallel workspaces, and GRDB keys `grdb_migrations` on the whole
            // identifier — a bare "v29" another workspace also picked is a
            // *silent skip*, not a conflict, and the missing table surfaces at
            // query time.
            try db.create(table: "deadlines") { table in
                table.autoIncrementedPrimaryKey("id")
                // The user's words. Never LLM-written — see design.md §4.5 on
                // why nothing infers a deadline from the screen.
                table.column("title", .text).notNull()
                table.column("due_at", .integer).notNull()
                // 1 when only the *day* was given, which is how a deadline is
                // usually held in the head ("Friday", not "Friday 17:00").
                // Changes the copy ("due today" vs "due at 5pm") and keeps a
                // day-shaped deadline from announcing itself at midnight.
                table.column("all_day", .integer).notNull().defaults(to: 1)
                // Set NULL rather than cascade: prune and merge delete tasks
                // routinely, and a vanished deadline is a broken promise.
                table.column("task_id", .integer)
                    .references("tasks", onDelete: .setNull)
                // The effort the user intends to put in, in ms. NULL means the
                // deadline is a date only; with it, logged time against
                // `task_id` becomes a fraction and progress can be reported.
                table.column("target_ms", .integer)
                table.column("created_at", .integer).notNull()
                // Progress counts from `created_at`, never from the task's
                // birth: the promise is about the work left when it was made.
                //
                // Non-NULL takes the row out of every queue and every
                // notification. This is also the only "done" state anywhere
                // near a task — `tasks` has none, by design.
                table.column("done_at", .integer)
                // The announcement ledger, and the reason a reminder cannot
                // repeat. `announced_lead` is the *smallest* lead bucket (in
                // days) already delivered, so it only ever falls; NULL is
                // "nothing said yet". `progress_notch` is the highest quarter
                // of `target_ms` already reported. Both live here rather than
                // in the notification centre's delivered list because a user
                // clearing Notification Center must not re-arm every reminder
                // they already read.
                table.column("announced_lead", .integer)
                table.column("progress_notch", .integer).notNull().defaults(to: 0)
            }
            // Every read is "what is open, soonest first".
            try db.create(
                index: "idx_deadlines_due", on: "deadlines",
                columns: ["done_at", "due_at"])
            try db.create(index: "idx_deadlines_task", on: "deadlines", columns: ["task_id"])
        }
    }

    /// Spotted dates (design.md §4.7): the queue the scout proposes into.
    /// Its own function so it registers *after* `v29-deck-topics` — the
    /// migrator runs in registration order and `MigrationTests` holds the
    /// numbers to it.
    static func registerDeadlineProposalMigrations(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v30-deadline-proposals") { db in
            // One row per (due day, words around the date). `key` is unique
            // for the same reason `theme_proposals.key` is: a repeat sighting
            // updates the row, and a dismissal is remembered against every
            // future sighting of the same thing. Nothing here is a deadline —
            // accepting mints a `deadlines` row and records its id.
            try db.create(table: "deadline_proposals") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("key", .text).notNull().unique()
                table.column("title", .text).notNull()
                table.column("context", .text)
                table.column("due_at", .integer).notNull()
                table.column("all_day", .integer).notNull().defaults(to: 1)
                table.column("category", .text).notNull()
                // The best single sighting's score, the score with repetition
                // added, and the tier that score lands in — stored rather
                // than derived so a threshold change re-tiers on the next
                // sighting, not retroactively under a dismissal.
                table.column("base_score", .integer).notNull()
                table.column("score", .integer).notNull()
                table.column("tier", .integer).notNull()
                table.column("evidence", .text).notNull()
                table.column("source_app", .text).notNull()
                table.column("source_domain", .text)
                // SET NULL like `deadlines.task_id`: tasks are pruned and
                // merged, and a proposal should not vanish with one.
                table.column("task_id", .integer).references("tasks", onDelete: .setNull)
                table.column("sightings", .integer).notNull().defaults(to: 1)
                table.column("seen_days", .integer).notNull().defaults(to: 1)
                table.column("first_seen", .integer).notNull()
                table.column("last_seen", .integer).notNull()
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("deadline_id", .integer).references("deadlines", onDelete: .setNull)
                // The notification ledger: a proposal is named in a banner at
                // most once, ever, and this is what says it was.
                table.column("notified_at", .integer)
                table.column("judged", .integer).notNull().defaults(to: 0)
                table.column("created_at", .integer).notNull()
            }
            // Every read is "what is open, most pressing first".
            try db.create(
                index: "idx_deadline_proposals_open", on: "deadline_proposals",
                columns: ["status", "tier", "due_at"])
        }
    }
}
