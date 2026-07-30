import Foundation
import GRDB

/// The deck-era migrations (v18+), split from ShifuMigrations.swift for
/// length only — that file is append-only, so the split happens at the era
/// boundary. Registration order is what GRDB runs, so the one caller invokes
/// this exactly where v18 sat in the sequence.
extension ShifuDatabase {
    static func registerDeckMigrations(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18") { db in
            // User-requested flashcard decks (design.md §5.2).
            //
            // Numbered v18 while v17 (above) was still on another branch:
            // GRDB keys `grdb_migrations` on the identifier string, so two
            // branches claiming one number is not a conflict it can detect —
            // it is a *silent skip*, surfacing later as "no such table: decks"
            // at query time rather than at open. Pick the next number from
            // what has actually run, not from what is in this file. Automatic
            // extraction no longer writes cards at all — a deck is the only
            // way one is born, and the request *is* the confirmation, so deck
            // cards skip the inbox and land kept.
            //
            // `key` is derived from the task key, never the title: the task
            // key is already unique, whereas two tasks can easily earn the
            // same title slug, and ON CONFLICT DO NOTHING would then swallow
            // the second create silently. No `card_count` column either — the
            // user prunes cards during review, so a stored count starts
            // drifting the moment the feature is used as designed; the count
            // is always derived from `vault_index`.
            try db.create(table: "decks") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("key", .text).notNull().unique()       // "deck:<slug>"
                table.column("task_key", .text).notNull().unique()  // one deck per task
                table.column("title", .text).notNull()
                table.column("status", .text).notNull().defaults(to: "pending")
                table.column("status_at", .integer).notNull()
                table.column("created_at", .integer).notNull()
                table.column("built_at", .integer)
            }
            // Deck proposals from the weekly suggester. Keyed on `task_key`,
            // not `task_id`, because a dismissal here is *permanent*:
            // TaskPrune and TaskMerging both `DELETE FROM tasks` and SQLite
            // reuses rowids, so an id-keyed forever-row would eventually
            // suppress an unrelated future task. Keys are the codebase's
            // stable identity (it is why `vault_index` resolves key → id at
            // index time), and per-key suppression is semantically right: a
            // re-minted key is the same intent.
            try db.create(table: "deck_suggestions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("task_key", .text).notNull().unique()
                table.column("title", .text)                 // nil on 'declined'
                table.column("sample_cards", .text)          // JSON; nil on 'declined'
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("created_at", .integer).notNull()
            }
            // Which deck a card belongs to — rebuildable from the note's
            // `deck:` frontmatter like every other column here.
            try db.alter(table: "vault_index") { table in
                table.add(column: "deck_key", .text)
            }
            try db.create(index: "idx_vault_index_deck", on: "vault_index",
                          columns: ["deck_key"])
        }

        migrator.registerMigration("v19") { db in
            // Decks grew review settings (design.md §5.2). `paused` takes a
            // deck's cards out of every queue and count; `new_per_day` caps
            // how many never-reviewed cards a deck may introduce per local
            // day — the setting a hundred-card deck needs, since deck cards
            // are born due-now and would otherwise land in the queue all at
            // once. NULL is uncapped; existing decks get the same default new
            // ones are minted with, because a cap only bites when a deck is
            // bigger than a day's appetite anyway.
            //
            // (Numbered v19 against what has actually *run* — see the v18
            // note on silent skips.)
            try db.alter(table: "decks") { table in
                table.add(column: "paused", .boolean).notNull().defaults(to: false)
                table.add(column: "new_per_day", .integer)
            }
            try db.execute(sql: "UPDATE decks SET new_per_day = ?",
                           arguments: [DeckStore.defaultNewPerDay])
        }

        migrator.registerMigration("v20") { db in
            // The New deck page's brief (design.md §5.2), folded into every
            // build prompt. On the row, not passed in flight, because the
            // hourly drain retries builds long after the page is gone. NULL
            // means the deck was requested without instructions. (Numbered
            // v20 against what has actually *run* — see the v18 note.)
            try db.alter(table: "decks") { table in
                table.add(column: "instructions", .text)
            }
        }

        migrator.registerMigration("v21") { db in
            // The New deck page's card-count range (design.md §5.2). Both
            // NULL is automatic — the builder judges, no hard limit. Set,
            // the pair goes into the build prompt and `cards_max` is also
            // enforced in code: the build stops writing at the ceiling,
            // which a prompt alone cannot promise. (Numbered v21 against
            // what has actually *run* — see the v18 note.)
            try db.alter(table: "decks") { table in
                table.add(column: "cards_min", .integer)
                table.add(column: "cards_max", .integer)
            }
        }
    }
}
