import Foundation
import Testing
@testable import ShifuCore

@Suite struct FSRSTests {
    @Test func firstReviewSeedsState() {
        let state = FSRS.review(FSRS.State(), grade: .good, now: Date(timeIntervalSince1970: 0))
        #expect(state.reps == 1)
        #expect(state.stability > 0)
        #expect(state.difficulty >= 1 && state.difficulty <= 10)
        #expect(state.intervalDays >= 1)
    }

    @Test func easyOutschedulesGoodOutschedulesHard() {
        let start = FSRS.State()
        let now = Date(timeIntervalSince1970: 0)
        let hard = FSRS.review(start, grade: .hard, now: now)
        let good = FSRS.review(start, grade: .good, now: now)
        let easy = FSRS.review(start, grade: .easy, now: now)
        #expect(easy.intervalDays >= good.intervalDays)
        #expect(good.intervalDays >= hard.intervalDays)
    }

    @Test func intervalsGrowAcrossSuccessfulReviews() {
        var state = FSRS.State()
        var now = Date(timeIntervalSince1970: 0)
        var previous = 0.0
        for _ in 0..<5 {
            state = FSRS.review(state, grade: .good, now: now)
            #expect(state.intervalDays >= previous)
            previous = state.intervalDays
            now = state.due
        }
        #expect(state.intervalDays > 5)   // healthy growth after 5 goods
    }

    @Test func againResetsToRelearning() {
        var state = FSRS.State()
        let now = Date(timeIntervalSince1970: 0)
        state = FSRS.review(state, grade: .good, now: now)
        let stabilityBefore = state.stability
        state = FSRS.review(state, grade: .again, now: state.due)
        #expect(state.intervalDays == 0)
        #expect(state.stability <= stabilityBefore)
    }
}

@Suite struct NoteTests {
    @Test func roundTripsThroughSerialization() {
        let original = Note(
            sourceApp: "Safari",
            sourceURL: "https://developer.apple.com/documentation/screencapturekit",
            topic: "macOS screen capture",
            confidence: 0.86,
            state: .kept,
            seenCount: 2,
            srs: FSRS.State(stability: 2.5, difficulty: 5.1, intervalDays: 3,
                            due: Date(timeIntervalSince1970: 1_760_000_000), reps: 1,
                            lastReview: Date(timeIntervalSince1970: 1_759_700_000)),
            body: "**SCScreenshotManager** takes one-off screenshots.\n\nQ: What API?\nA: SCScreenshotManager."
        )
        let parsed = Note.parse(original.serialize())
        #expect(parsed != nil)
        #expect(parsed?.id == original.id)
        #expect(parsed?.topic == original.topic)
        #expect(parsed?.state == .kept)
        #expect(parsed?.seenCount == 2)
        #expect(parsed?.srs?.reps == 1)
        #expect(parsed?.srs?.due == original.srs?.due)
        #expect(parsed?.questionAnswer?.question == "What API?")
        #expect(parsed?.body == original.body)
    }

    @Test func noteWithoutQAIsReferenceOnly() {
        let note = Note(topic: "x", body: "just a fact, no card")
        #expect(note.questionAnswer == nil)
    }

    @Test func ulidsAreSortableByTime() {
        let earlier = Note.ulid(now: Date(timeIntervalSince1970: 1_000))
        let later = Note.ulid(now: Date(timeIntervalSince1970: 2_000))
        #expect(earlier < later)
        #expect(earlier.count == 26)
    }
}

@Suite struct VaultStoreTests {
    private func scratchVault() throws -> VaultStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-vault-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return VaultStore(root: dir, database: try ShifuDatabase.inMemory())
    }

    @Test func saveAndDiscardLifecycle() throws {
        let vault = try scratchVault()
        let note = Note(topic: "SQLite WAL", srs: FSRS.State(due: Date()),
                        body: "WAL survives kill -9.\n\nQ: q\nA: a")
        try vault.save(note)
        #expect(try vault.due().count == 1)

        let kept = try vault.due()[0]
        try vault.discard(kept)
        #expect(try vault.allNotes().isEmpty)
    }

    /// A legacy `state: inbox` note — from a backup, or a machine still on the
    /// old version — must stay out of the review queue even though there is no
    /// longer any triage step to resolve it. Deleting the enum case would make
    /// it parse as `kept` and turn declined suggestions into cards.
    @Test func legacyInboxNotesNeverReachTheQueue() throws {
        let vault = try scratchVault()
        let legacy = Note(topic: "old candidate", state: .inbox,
                          srs: FSRS.State(due: Date()),
                          body: "a proposal from the old world\n\nQ: q\nA: a")
        try vault.save(legacy)

        #expect(try vault.allNotes().count == 1)
        #expect(try vault.due().isEmpty)
        #expect(Note.parse(legacy.serialize())?.state == .inbox)
    }

    @Test func reviewSchedulesAndKeepsFileCount() throws {
        let vault = try scratchVault()
        let note = Note(topic: "swift actors", state: .kept,
                        srs: FSRS.State(due: Date()), body: "fact\n\nQ: q\nA: a")
        try vault.save(note)

        let reviewed = try vault.review(note, grade: .good)
        #expect(reviewed.srs!.reps == 1)
        #expect(reviewed.srs!.due > Date())
        #expect(try vault.allNotes().count == 1)     // updated in place, no duplicate file
        #expect(try vault.due().isEmpty)             // no longer due today
    }

    @Test func duplicateCandidateBumpsSeenCount() throws {
        let vault = try scratchVault()
        let existing = Note(topic: "dhash", state: .kept, body: "dHash compares adjacent pixels of an 8x8 grid")
        try vault.save(existing)

        let dupe = Note(topic: "dHash", body: "dHash compares adjacent pixels of an 8x8 grid!")
        #expect(try vault.mergeIfDuplicate(of: dupe))
        let notes = try vault.allNotes()
        #expect(notes.count == 1)
        #expect(notes[0].seenCount == 2)

        let fresh = Note(
            topic: "dhash",
            body: "completely different content about perceptual hashing "
                + "thresholds and hamming distance tuning"
        )
        #expect(try !vault.mergeIfDuplicate(of: fresh))
    }
}

/// The shared card-JSON shape and its LaTeX repairs — exercised here rather
/// than through any one of the three prompts that answer in it.
@Suite struct CardCandidatesTests {
    @Test func parsesCandidates() {
        let candidates = CardCandidates.parse("""
        [{"topic": "GRDB WAL", "note": "GRDB queues serialize writes.",
          "question": "How does GRDB serialize?", "answer": "DatabaseQueue.", "confidence": 0.9}]
        """)
        #expect(candidates.count == 1)
        #expect(candidates[0].topic == "GRDB WAL")
        #expect(candidates[0].question == "How does GRDB serialize?")
    }

    @Test func emptyArrayMeansNothingWorthKeeping() {
        #expect(CardCandidates.parse("[]").isEmpty)
        #expect(CardCandidates.parse("no json at all").isEmpty)
    }

    /// `\(` is not a JSON escape, so an un-doubled backslash used to fail the
    /// whole array and lose every candidate in the batch.
    @Test func rawLaTeXInJSONStillParses() {
        let candidates = CardCandidates.parse(
            #"[{"topic": "cone", "note": "\(a^T x \ge c\|x\|\)", "confidence": 0.9}]"#)
        #expect(candidates.count == 1)
        #expect(candidates[0].note == #"\(a^T x \ge c\|x\|\)"#)
    }

    /// `\frac` is worse than a parse failure: JSON reads `\f` as a formfeed and
    /// silently eats the "f", so the card renders as "rac{a}{b}".
    @Test func commandsThatLookLikeEscapesSurviveIntact() {
        let candidates = CardCandidates.parse(
            #"[{"topic": "t", "note": "\frac{a}{b} with \theta", "confidence": 0.9}]"#)
        #expect(candidates.first?.note == #"\frac{a}{b} with \theta"#)
    }

    /// The repair only knows LaTeX commands, so a real `\n` between sentences
    /// stays a newline — `\next` is not a command CardMarkup renders.
    @Test func genuineJSONEscapesAreLeftAlone() {
        let candidates = CardCandidates.parse(
            #"[{"topic": "t", "note": "One.\nTwo, \"quoted\", 50% done.", "confidence": 0.9}]"#)
        #expect(candidates.first?.note == "One.\nTwo, \"quoted\", 50% done.")
    }

    @Test func correctlyEscapedLaTeXIsNotDoubleEscaped() {
        let candidates = CardCandidates.parse(
            #"[{"topic": "t", "note": "Good \\(x\\) here", "confidence": 0.9}]"#)
        #expect(candidates.first?.note == #"Good \(x\) here"#)
    }
}
