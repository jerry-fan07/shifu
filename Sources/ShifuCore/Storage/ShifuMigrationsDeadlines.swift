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
}
