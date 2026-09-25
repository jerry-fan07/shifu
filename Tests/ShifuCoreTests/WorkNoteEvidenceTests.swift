import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// What a day note is written *from* (`WorkNoteEvidence.swift`): the day's
/// block cards, then a tally of the card-less windows, and raw screen text
/// only for an activity with neither — never the 2,000 characters of OCR per
/// activity that made this stage 46% of the bill.
///
/// Fixtures come from `WorkNoteCompilerTests`; these live in their own file
/// only because that one is at the lint's file-length cap.

/// Records every prompt, answers with one bullet.
private final class PromptLog: LLMBackend, @unchecked Sendable {
    let name = "prompt-log"
    private let lock = NSLock()
    private var prompts: [String] = []

    var calls: Int { lock.withLock { prompts.count } }
    var lastPrompt: String { lock.withLock { prompts.last ?? "" } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        return "- **09:00–10:30** — stepped through the observer teardown"
    }
}

extension WorkNoteCompilerTests {
    private var evidenceTaskKey: String { "topic:debugging-capture-daemon" }

    private func card(_ gist: String, topic: String = "debugging capture daemon") -> String {
        BlockCard(category: .work, topic: topic, entities: ["repo:shifu"], gist: gist).json!
    }

    private func setCard(_ database: ShifuDatabase, activity: Int64, _ json: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE activities SET card = ? WHERE id = ?",
                           arguments: [json, activity])
        }
    }

    private func addTitle(_ database: ShifuDatabase, activity: Int64, at: Date,
                          app: String, title: String) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO observations
                    (started_at, last_seen, app_bundle, window_title, capture_kind, session_id)
                VALUES (?, ?, ?, ?, 'ax', ?)
                """, arguments: [ms(at), ms(at), app, title, activity])
        }
    }

    @Test func aCardedDayIsWrittenFromItsCardsNotItsScreenText() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = PromptLog()
        let start = day1.addingTimeInterval(9 * 3_600)
        let block = try insertActivity(
            database, start: start, minutes: 90,
            sampleText: "RAW-OCR-TEXT " + String(repeating: "terminal scrollback ", count: 80))
        try setCard(database, activity: block, card("stepping through AX observer teardown"))

        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)
        let prompt = backend.lastPrompt
        #expect(prompt.contains("stepping through AX observer teardown"))
        #expect(prompt.contains("topic=debugging capture daemon"))
        #expect(prompt.contains("90m Xcode:"))
        #expect(!prompt.contains("RAW-OCR-TEXT"))
    }

    /// Sub-minute glances carry no card; what they add to the story is where
    /// the time went, told once per window rather than once per glance.
    @Test func cardlessTimeIsToldAsATallyOfWindows() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = PromptLog()
        let start = day1.addingTimeInterval(9 * 3_600)
        let long = try insertActivity(database, start: start, minutes: 30)
        try setCard(database, activity: long, card("wiring the pause teardown"))
        for index in 0..<6 {
            let glanceStart = start.addingTimeInterval(Double(40 + index) * 60)
            let glance = try insertActivity(
                database, start: glanceStart, minutes: 0.5, app: "com.google.Chrome")
            try addTitle(database, activity: glance, at: glanceStart,
                         app: "com.google.Chrome", title: "Pull request #12 · org/shifu")
        }

        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        let prompt = backend.lastPrompt
        #expect(prompt.contains("Other windows, by time:"))
        // Six half-minute glances, one line: 3 minutes in the one window.
        #expect(prompt.contains("- Chrome · Pull request #12 · org/shifu (3m)"))
        #expect(prompt.components(separatedBy: "Pull request #12").count == 2)
    }

    /// Raw text is the last resort for a day with nothing else. Beside cards
    /// it is OCR'd browser chrome the cards already say better, so it goes.
    @Test func screenTextOnlySpeaksForADayWithNothingElse() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = PromptLog()
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 40,
                           sampleText: "TEXT-ONLY-ACTIVITY")
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.lastPrompt.contains("Screen text:\n- Xcode: TEXT-ONLY-ACTIVITY"))

        let carded = try insertActivity(
            database, start: day1.addingTimeInterval(11 * 3_600), minutes: 30)
        try setCard(database, activity: carded, card("wiring the pause teardown"))
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 2)
        #expect(!backend.lastPrompt.contains("TEXT-ONLY-ACTIVITY"))
        #expect(backend.lastPrompt.contains("wiring the pause teardown"))
    }

    @Test func aRepeatedCardFoldsIntoOneLine() {
        let times = WorkNoteCompiler.timeFormatter(calendar)
        let evidence = WorkNoteCompiler.ActivityEvidence(card: BlockCard(
            category: .work, topic: "thesis", entities: [], gist: "drafting chapter 3"))
        let start = ms(day1.addingTimeInterval(9 * 3_600))
        let items = [0, 1, 2].map { index in
            WorkNoteCompiler.EvidenceItem(
                startedAt: start + Int64(index) * 600_000, durationMs: 600_000,
                appBundle: "com.apple.Pages", evidence: evidence)
        }
        let rendered = WorkNoteCompiler.renderEvidence(items, times: times)
        #expect(rendered == "09:00 30m Pages: drafting chapter 3 | topic=thesis")
    }

    /// Cards outlive the 14-day text scrub, and the gate hashes what the
    /// prompt sees — so scrubbing a described day's screen text is not a
    /// change, where under the old raw-text hash it re-billed (or, past the
    /// narrative floor, blanked) the note.
    @Test func scrubbingScreenTextIsNotAChange() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = PromptLog()
        let block = try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600),
                                       minutes: 90, sampleText: "AX observer teardown")
        try setCard(database, activity: block, card("stepping through AX observer teardown"))
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)

        try await database.queue.write { db in
            try db.execute(sql: "UPDATE observations SET text = NULL")
        }
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)
    }

    /// Past the narration horizon a day is history: its prose is carried
    /// whatever its hash says, so a recompile of old days (`--rebuild`)
    /// re-bills nothing.
    @Test func aDayPastTheHorizonIsNeverBilledAgain() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = PromptLog()
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown")
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)

        // The day changes, but a week later: carried, not re-described.
        try insertActivity(database, start: day1.addingTimeInterval(16 * 3_600), minutes: 30,
                           sampleText: "perf harness output")
        let weekLater = calendar.date(byAdding: .day, value: 7, to: day1)!
        _ = try await compile(database, vault, backend: backend, from: day1, to: weekLater)
        #expect(backend.calls == 1)
        let note = try #require(vault.workNote(
            day: WorkNoteCompiler.dayString(ms(day1), calendar: calendar),
            taskKey: evidenceTaskKey))
        #expect(note.sessionsProse?.contains("observer teardown") == true)
        #expect(note.durationMs == 120 * 60_000)
    }
}
