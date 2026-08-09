import Foundation
import GRDB

/// The Rewind schema (design.md §3.6), split from ShifuMigrations.swift for
/// length only. Registration order is what GRDB runs, so the one caller
/// invokes this at the end of the sequence.
extension ShifuDatabase {
    static func registerRewindMigrations(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v28-rewind") { db in
            // Two tables for the one feature that writes pixels.
            //
            // `rewind_frames` is both halves of it: a row with `rewind_id`
            // NULL is in the *rolling buffer* and will be deleted within the
            // buffer window, while a row with one belongs to a rewind the user
            // asked to keep. Same table because they are the same thing at two
            // ages, and because the player draws from one query either way.
            //
            // Numbered v28 because v27 was claimed twice already
            // (`v27-merge-source`, `v27-llm-usage-stage` — both have run on
            // real machines). The name suffix is the guard: GRDB keys
            // `grdb_migrations` on the whole identifier, so a bare "v28" that
            // another workspace also picks is a *silent skip*, not a conflict.
            //
            // `rewinds` is created first because `rewind_frames` references it
            // and GRDB opens connections with `foreign_keys = ON` — a forward
            // reference is accepted by `CREATE TABLE` and then fails at the
            // first insert, which is the worst place to find out.
            try db.create(table: "rewinds") { table in
                table.autoIncrementedPrimaryKey("id")
                // 'rewind' — a span of frames; 'snip' — one frame kept by hand.
                table.column("kind", .text).notNull()
                table.column("title", .text).notNull()
                // Why it was saved, in the user's words or the daemon's.
                table.column("note", .text)
                table.column("created_at", .integer).notNull()
                table.column("started_at", .integer).notNull()
                table.column("ended_at", .integer).notNull()
                // Relative to `ShifuPaths.rewind`, so moving ~/Shifu doesn't
                // strand every row.
                table.column("directory", .text).notNull()
                table.column("bytes", .integer).notNull().defaults(to: 0)
                table.column("frame_count", .integer).notNull().defaults(to: 0)
                // Where it belongs. Resolved at save time from the newest
                // block that has one — best effort, because the block the user
                // is *in* has usually not been sessionized yet.
                table.column("task_id", .integer)
                table.column("theme_key", .text)
                // NULL is "keep forever": the row is out of the retention
                // schedule entirely, which is the only thing that takes it out.
                table.column("expires_at", .integer)
                // The vault note a snip wrote, so opening one from the shelf
                // can reach the words filed beside it.
                table.column("note_path", .text)
            }
            try db.create(index: "idx_rewinds_created", on: "rewinds", columns: ["created_at"])

            try db.create(table: "rewind_frames") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("captured_at", .integer).notNull()
                // NULL while the frame is in the rolling buffer. Cascade so
                // deleting a rewind takes its frame rows with it — the files
                // are removed by `RewindStore`, which owns both sides.
                table.column("rewind_id", .integer)
                    .references("rewinds", onDelete: .cascade)
                // Relative to `ShifuPaths.rewind`. NULL for an excluded
                // moment: the row still exists to say "time passed here and
                // nothing was taken", which is what draws the hatched band on
                // the rail.
                table.column("path", .text)
                table.column("app_bundle", .text)
                table.column("window_title", .text)
                table.column("url", .text)
                table.column("excluded", .integer).notNull().defaults(to: 0)
                table.column("width", .integer).notNull().defaults(to: 0)
                table.column("height", .integer).notNull().defaults(to: 0)
                table.column("bytes", .integer).notNull().defaults(to: 0)
                // What asked for this frame: 'tick', 'window', or 'snip'.
                table.column("trigger", .text).notNull().defaults(to: "tick")
            }
            // The buffer trim and the player both scan by time.
            try db.create(
                index: "idx_rewind_frames_buffer", on: "rewind_frames",
                columns: ["captured_at"])
            try db.create(
                index: "idx_rewind_frames_rewind", on: "rewind_frames",
                columns: ["rewind_id", "captured_at"])
        }
    }
}
