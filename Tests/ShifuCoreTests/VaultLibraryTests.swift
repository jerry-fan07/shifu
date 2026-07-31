import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The Notes place's read model (vault-features.md §4, §6). The thing under
/// test throughout is the one that made the old page unusable: the vault is
/// mostly one-line work-note traces, and everything here exists to keep them
/// from standing in for the notes that were actually written.
@Suite struct VaultLibraryTests {
    private func tempVault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A vault holding one of each shape the compiler produces, filed under
    /// one task so provenance has something to resolve.
    private struct Fixture {
        var database: ShifuDatabase
        var vault: VaultStore
        var trace: WorkNote
        var document: WorkNote
        var card: Note
    }

    private func fixture() throws -> Fixture {
        let database = try ShifuDatabase.inMemory()
        let vault = VaultStore(root: try tempVault(), database: database)
        let dayMs = Int64(Date(timeIntervalSince1970: 1_784_000_000).timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (7, 'sem:capture-daemon', 'Capture daemon', ?, ?)
                """, arguments: [dayMs, dayMs])
            try db.execute(sql: """
                INSERT INTO themes (id, key, name, created_at, last_active_at)
                VALUES (3, 'theme:shifu', 'Shifu', ?, ?)
                """, arguments: [dayMs, dayMs])
            try db.execute(sql: """
                INSERT INTO activities
                    (started_at, ended_at, app_bundle, category, source, task_id, theme_key)
                VALUES (?, ?, 'com.apple.dt.Xcode', 'work', 'rules', 7, 'theme:shifu')
                """, arguments: [dayMs, dayMs + 3_600_000])
        }

        // The majority shape: the deterministic line and nothing else.
        let trace = WorkNote(
            taskKey: "sem:capture-daemon", taskName: "Capture daemon", day: "2026-07-20",
            durationMs: 9_000, sources: ["arxiv.org"], summary: "arxiv.org")
        // The shape the page exists to surface.
        let document = WorkNote(
            taskKey: "sem:capture-daemon", taskName: "Capture daemon", day: "2026-07-21",
            durationMs: 5_400_000, sources: ["Xcode", "github.com"],
            sessions: [WorkNote.Session(start: "09:12", end: "10:41")],
            summary: "Xcode, github.com — debugging capture daemon",
            sessionsProse: "**09:12–10:41** — Chased the AX observer leak.",
            detailProse: "### Learned\nPause tears observers down.",
            capturedLinks: [])
        let card = Note(
            topic: "AX observer teardown", taskKey: "sem:capture-daemon",
            body: "Pausing has to tear observers down rather than gate writes, "
                + "because a gated write still means the observer ran and the user "
                + "asked for it to stop.\n\nQ: Why?\nA: Because the observer ran.")

        try vault.saveWork(trace)
        try vault.saveWork(document)
        try vault.save(card)
        return Fixture(database: database, vault: vault,
                       trace: trace, document: document, card: card)
    }

    // MARK: - Depth

    /// The grading rule, pinned at each boundary. `Filter`'s SQL writes the
    /// same rule a second time (it has to stay an indexable predicate), so
    /// these thresholds are the contract between the two.
    @Test func depthGradesBodiesByWhatTheyAreMadeOf() {
        func depth(_ sections: Int, _ words: Int) -> VaultLibrary.Depth {
            VaultLibrary.Depth.of(kind: .work, sections: sections, words: words)
        }
        #expect(depth(0, 1) == .trace)
        #expect(depth(0, 44) == .trace)
        #expect(depth(0, 45) == .note)
        #expect(depth(1, 3) == .note)
        #expect(depth(2, 3) == .document)
        #expect(depth(0, 220) == .document)
        #expect(VaultLibrary.Depth.trace < VaultLibrary.Depth.document)
    }

    /// Only the compiler's per-task-day note can be a trace. A terse card is
    /// still one the user asked for.
    @Test func onlyWorkNotesCanBeTraces() {
        #expect(VaultLibrary.Depth.of(kind: .work, sections: 0, words: 3) == .trace)
        #expect(VaultLibrary.Depth.of(kind: .knowledge, sections: 0, words: 3) == .note)
        #expect(VaultLibrary.Depth.of(kind: .taskOverview, sections: 0, words: 3) == .note)
        // A kind this binary doesn't know is not something it may hide either.
        #expect(VaultLibrary.Depth.of(kind: nil, sections: 0, words: 3) == .note)
    }

    @Test func depthFilterAndDepthPropertyAgree() throws {
        let fixture = try fixture()
        for scope in [VaultLibrary.Depth.trace, .note, .document] {
            let admitted = try VaultLibrary.shelf(
                filter: VaultLibrary.Filter(minimumDepth: scope),
                database: fixture.database)
            #expect(admitted.allSatisfy { $0.depth >= scope })
            let all = try VaultLibrary.shelf(
                filter: VaultLibrary.Filter(), database: fixture.database)
            #expect(admitted.count == all.count { $0.depth >= scope })
        }
    }

    /// The default shelf hides the trace and keeps the two written notes —
    /// the whole reason the place looked empty over a vault of hundreds.
    @Test func theDefaultShelfHidesTracesWithoutDeletingThem() throws {
        let fixture = try fixture()
        let written = try VaultLibrary.shelf(
            filter: VaultLibrary.Filter(minimumDepth: .note), database: fixture.database)
        #expect(written.count == 2)
        #expect(!written.contains { $0.noteID == fixture.trace.id })

        // Still there, still findable — a trace is the receipt that the time
        // was real (vault-features.md §7), it just isn't an answer.
        let everything = try VaultLibrary.shelf(
            filter: VaultLibrary.Filter(), database: fixture.database)
        #expect(everything.count == 3)
        #expect(everything.contains { $0.noteID == fixture.trace.id })
    }

    // MARK: - Census

    @Test func censusCountsEveryKindNotJustCards() throws {
        let fixture = try fixture()
        let census = try VaultLibrary.census(database: fixture.database)
        #expect(census.total == 3)
        #expect(census.work == 2)
        #expect(census.knowledge == 1)
        #expect(census.substantial == 2)
        #expect(census.traces == 1)
    }

    // MARK: - Provenance

    @Test func entriesCarryTheirTaskAndTheme() throws {
        let fixture = try fixture()
        let entry = try #require(
            try VaultLibrary.entry(noteID: fixture.document.id, database: fixture.database))
        #expect(entry.taskID == 7)
        #expect(entry.taskName == "Capture daemon")
        #expect(entry.taskKey == "sem:capture-daemon")
        #expect(entry.themeName == "Shifu")
        #expect(entry.durationMs == 5_400_000)
        #expect(entry.depth == .document)
    }

    /// A work note is titled by its task, not by its body's first line — the
    /// deterministic source list makes an unreadable heading, and it left all
    /// of the dogfood vault's overviews called "Status".
    @Test func compiledNotesAreTitledByTheirTask() throws {
        let fixture = try fixture()
        let entry = try #require(
            try VaultLibrary.entry(noteID: fixture.document.id, database: fixture.database))
        #expect(entry.title == "Capture daemon")
        #expect(entry.summary == "Xcode, github.com — debugging capture daemon")
    }

    @Test func overviewSummarySkipsItsOwnHeading() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = VaultStore(root: try tempVault(), database: database)
        try vault.saveOverview(TaskOverview(
            taskKey: "sem:capture-daemon", taskName: "Capture daemon",
            updated: Date(timeIntervalSince1970: 1_784_000_000), inputHash: 1,
            body: "## Status\nThe daemon is stable.\n\n## Open threads\n- dHash leak."))
        let entries = try VaultLibrary.shelf(
            filter: VaultLibrary.Filter(kind: .taskOverview), database: database)
        #expect(entries.first?.title == "Capture daemon")
        #expect(entries.first?.summary == "The daemon is stable.")
    }

    @Test func themeScopeNarrowsTheShelf() throws {
        let fixture = try fixture()
        let inTheme = try VaultLibrary.shelf(
            filter: VaultLibrary.Filter(themeScope: .theme(key: "theme:shifu")),
            database: fixture.database)
        #expect(inTheme.count == 3)
        let unassigned = try VaultLibrary.shelf(
            filter: VaultLibrary.Filter(themeScope: .unassigned), database: fixture.database)
        #expect(unassigned.isEmpty)
    }

    // MARK: - Ranking

    /// bm25 rewards a short document for containing the term, and the vault's
    /// shortest documents are its emptiest. On the dogfood vault a search for
    /// "arxiv" returned six one-word traces before the paper it was actually
    /// about; the depth weight is what reorders that.
    @Test func searchRanksWrittenNotesAboveOneLineTraces() throws {
        let fixture = try fixture()
        try fixture.vault.saveWork(WorkNote(
            taskKey: "domain:arxiv.org", taskName: "arxiv.org", day: "2026-07-22",
            durationMs: 9_000, sources: ["arxiv.org"], summary: "arxiv.org"))
        try fixture.vault.saveWork(WorkNote(
            taskKey: "sem:capture-daemon", taskName: "Capture daemon", day: "2026-07-23",
            durationMs: 3_600_000, sources: ["arxiv.org"],
            summary: "arxiv.org — reading the NMF survey",
            sessionsProse: "**14:00–15:00** — Read the arxiv survey on NMF.",
            detailProse: "### Learned\nThe separability assumption is the crux."))

        // Raw bm25 puts the one-word trace first; the ranked search must not.
        let rawFirst = try fixture.database.queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT vi.title FROM vault_fts JOIN vault_index vi ON vi.id = vault_fts.rowid
                WHERE vault_fts MATCH ? ORDER BY bm25(vault_fts) LIMIT 1
                """, arguments: ["\"arxiv\"*"])
        }
        #expect(rawFirst == "arxiv.org")

        let hits = try VaultSearch.search("arxiv", database: fixture.database)
        #expect(hits.first?.entry.depth == .document)
        #expect(hits.first?.title == "Capture daemon")
        // Reordered, not removed: the trace is still an answer, just not the
        // first one.
        #expect(hits.contains { $0.entry.depth == .trace })
    }

    /// Re-ranking can only reorder what it was given, so the lexical pool has
    /// to be deeper than the display limit. A term the vault repeats in fifty
    /// one-line traces pushes the one day that wrote it up past rank 20 on
    /// bm25 alone — and a pool the size of the limit would have dropped it
    /// before the depth weight ever ran.
    @Test func aBuriedDocumentSurvivesAPoolFullOfTraces() throws {
        let fixture = try fixture()
        for day in 1...45 {
            try fixture.vault.saveWork(WorkNote(
                taskKey: "domain:widget.io", taskName: "widget.io",
                day: String(format: "2026-06-%02d", day),
                durationMs: 9_000, sources: ["widget.io"], summary: "widget.io"))
        }
        let buried = WorkNote(
            taskKey: "sem:capture-daemon", taskName: "Capture daemon", day: "2026-06-46",
            durationMs: 3_600_000, sources: ["Xcode"],
            summary: "Xcode — widget.io integration",
            sessionsProse: "**09:00–10:00** — Read the widget.io API docs end to end.",
            detailProse: "### Learned\nTheir pagination cursor is opaque and unordered.")
        try fixture.vault.saveWork(buried)

        let hits = try VaultSearch.search("widget", limit: 20, database: fixture.database)
        #expect(hits.first?.noteID == buried.id)
    }

    @Test func searchHonoursTheLibraryFilter() throws {
        let fixture = try fixture()
        let cardsOnly = try VaultSearch.search(
            "observer", filter: VaultLibrary.Filter(kind: .knowledge),
            database: fixture.database)
        #expect(cardsOnly.allSatisfy { $0.kind == .knowledge })
        #expect(cardsOnly.contains { $0.noteID == fixture.card.id })

        let workOnly = try VaultSearch.search(
            "observer", filter: VaultLibrary.Filter(kind: .work), database: fixture.database)
        #expect(!workOnly.contains { $0.noteID == fixture.card.id })
    }

    // MARK: - Dossier

    /// The point of the whole page: a half-remembered note leads back to the
    /// stretch of time that made it.
    @Test func aDossierPlacesANoteInItsCollections() throws {
        let fixture = try fixture()
        let dossier = try #require(try VaultLibrary.dossier(
            noteID: fixture.document.id, database: fixture.database, vault: fixture.vault))

        #expect(dossier.entry.taskName == "Capture daemon")
        #expect(dossier.stretches.map(\.start) == ["09:12"])
        #expect(dossier.sources == ["Xcode", "github.com"])
        #expect(dossier.body?.contains("Chased the AX observer leak") == true)
        // The same effort's other notes, this one excluded.
        #expect(dossier.timeline.map(\.noteID) == [fixture.trace.id])
    }

    /// A card carries no back-link of its own, so the day that captured it is
    /// found the way the compiler filed it — by (task, day).
    @Test func aCardFindsTheDayThatCapturedIt() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = VaultStore(root: try tempVault(), database: database)
        let day = Date(timeIntervalSince1970: 1_784_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (7, 'sem:capture-daemon', 'Capture daemon', 0, 0)
                """)
        }
        let workNote = WorkNote(
            taskKey: "sem:capture-daemon", taskName: "Capture daemon",
            day: formatter.string(from: day), durationMs: 3_600_000,
            summary: "Xcode — debugging", sessionsProse: "Chased a leak.")
        try vault.saveWork(workNote)
        let card = Note(captured: day, topic: "AX teardown",
                        taskKey: "sem:capture-daemon",
                        body: "Tear down, don't gate.\n\nQ: q\nA: a")
        try vault.save(card)

        let dossier = try #require(try VaultLibrary.dossier(
            noteID: card.id, database: database, vault: vault))
        #expect(dossier.related.map { $0.noteID } == [workNote.id])
    }

    @Test func aDossierIsNilForAnUnknownNote() throws {
        let fixture = try fixture()
        #expect(try VaultLibrary.dossier(
            noteID: "01NOSUCHNOTE00000000000000",
            database: fixture.database, vault: fixture.vault) == nil)
    }
}
