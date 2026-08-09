import Foundation
import GRDB
@testable import ShifuCore
import Testing

/// The note a snip files in the vault (design.md §3.6) — the half of "keep this
/// frame" that makes it findable later.
///
/// The frame itself lives under `~/Shifu/rewind/`; this is the record beside it,
/// and what has to hold is that the vault treats it like any other note *except*
/// for the one thing it must never be — a review card.
@Suite struct SnipNoteTests {
    private func note() -> SnipNote {
        SnipNote(
            id: "01HQ", title: "Frame — DeepSeek pricing table",
            captured: "2026-08-07T10:15:00Z",
            framePath: "/Users/x/Shifu/rewind/saved/12/1754561700000.jpg",
            source: "Safari", taskKey: "sem:llm-costs", taskName: "LLM costs",
            themeKey: "thm:shifu-development")
    }

    @Test func aSnipNoteRoundTrips() throws {
        let parsed = try #require(SnipNote.parse(note().serialize()))

        #expect(parsed.id == "01HQ")
        #expect(parsed.title == "Frame — DeepSeek pricing table")
        #expect(parsed.captured == "2026-08-07T10:15:00Z")
        #expect(parsed.taskKey == "sem:llm-costs")
        #expect(parsed.themeKey == "thm:shifu-development")
        #expect(parsed.framePath.hasSuffix(".jpg"))
    }

    /// **The vault stays text.** The note names the frame; it never carries it.
    /// A body that embedded image bytes would move pixels into the folder the
    /// user syncs, which is the one place §3.6 promises they never go.
    @Test func theNoteNamesTheFrameRatherThanCarryingIt() {
        let serialized = note().serialize()

        #expect(serialized.contains("/Shifu/rewind/saved/12/"))
        #expect(!serialized.contains("data:image"))
        #expect(!serialized.contains("base64"))
    }

    /// Dated folders under `snips/`, so a tree full of them never crowds the
    /// year folders the deck cards live in.
    @Test func snipsGetTheirOwnDatedCorner() {
        #expect(note().relativePath == "snips/2026/08/01HQ.md")
    }

    /// A snip is not a knowledge note, and `Note.parse` is what keeps the review
    /// queue from ever seeing one. This is the guard behind that: the kind is
    /// its own, so every `kind == .knowledge` gate rejects it.
    @Test func aSnipIsNotAKnowledgeNoteAndCannotEnterReview() {
        let text = note().serialize()

        #expect(FrontMatter.parse(text)?.kind == .snip)
        #expect(Note.parse(text) == nil)
        #expect(WorkNote.parse(text) == nil)
    }

    @Test func anotherKindIsNotASnip() {
        let work = WorkNote(
            taskKey: "app:xcode", taskName: "Xcode", day: "2026-08-07",
            durationMs: 60_000, summary: "Xcode — one hour")
        #expect(SnipNote.parse(work.serialize()) == nil)
    }

    /// The half the user actually asked for: a snip has to end up *filed under
    /// the current task*. That resolution happens at index time against the
    /// `tasks` table, so it is only real if `VaultIndexer` sees it.
    @Test func theIndexerFilesASnipUnderItsTask() throws {
        let database = try ShifuDatabase.inMemory()
        let taskID = try database.queue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO tasks (key, name, created_at, last_active_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: ["sem:llm-costs", "LLM costs", 1_754_561_700_000,
                            1_754_561_700_000])
            return db.lastInsertedRowID
        }

        let snip = note()
        _ = try database.queue.write { db in
            try VaultIndexer.upsert(
                text: snip.serialize(), relativePath: snip.relativePath,
                mtime: 0, db: db)
        }

        let row = try #require(try database.queue.read { db in
            try Row.fetchOne(
                db, sql: "SELECT kind, task_id, captured, title FROM vault_index WHERE note_id = ?",
                arguments: [snip.id])
        })
        #expect(row["kind"] as String == "snip")
        #expect(row["task_id"] as Int64? == taskID)
        // Dated by `captured:`, so it sorts into the shelf where it happened
        // rather than showing as undated.
        #expect((row["captured"] as Int64?) != nil)
    }

    /// And it counts as a snip in the census rather than silently inflating the
    /// knowledge total the Notes head prints.
    @Test func theCensusCountsSnipsSeparately() throws {
        let database = try ShifuDatabase.inMemory()
        let snip = note()
        _ = try database.queue.write { db in
            try VaultIndexer.upsert(
                text: snip.serialize(), relativePath: snip.relativePath, mtime: 0, db: db)
        }

        let census = try VaultLibrary.census(database: database)
        #expect(census.snips == 1)
        #expect(census.knowledge == 0)
        #expect(census.total == 1)
    }
}
