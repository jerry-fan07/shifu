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

    @Test func saveKeepDiscardLifecycle() throws {
        let vault = try scratchVault()
        let note = Note(topic: "SQLite WAL", body: "WAL survives kill -9.\n\nQ: q\nA: a")
        try vault.save(note)

        #expect(try vault.inbox().count == 1)
        #expect(try vault.due().isEmpty)   // inbox notes are never in the queue

        try vault.keep(note)
        #expect(try vault.inbox().isEmpty)
        #expect(try vault.due().count == 1)

        let kept = try vault.due()[0]
        try vault.discard(kept)
        #expect(try vault.allNotes().isEmpty)
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

@Suite struct KnowledgeExtractorTests {
    @Test func promptAsksForLaTeXWithDoubledBackslashes() {
        let prompt = KnowledgeExtractor.prompt(
            context: .init(text: "text sample"), app: "com.apple.Safari", topic: nil)
        #expect(prompt.contains(#"\( ... \)"#))
        #expect(prompt.contains("$$ ... $$"))
        #expect(prompt.contains(#"\\frac{a}{b}"#))
    }

    /// The task and its screen source are the difference between a note that
    /// still reads months later and one that says "the error above".
    @Test func promptCarriesTaskAndSourceContext() {
        let context = KnowledgeExtractor.BlockContext(
            text: "Actors serialize access to their state.",
            url: "https://docs.swift.org/actors",
            titles: ["Concurrency — Swift.org"],
            taskKey: "swift-concurrency",
            taskName: "Learning Swift concurrency")
        let prompt = KnowledgeExtractor.prompt(
            context: context, app: "com.apple.Safari", topic: "swift actors")
        #expect(prompt.contains("Learning Swift concurrency"))
        #expect(prompt.contains("swift actors"))
        #expect(prompt.contains("Concurrency — Swift.org"))
        #expect(prompt.contains("https://docs.swift.org/actors"))
        #expect(prompt.contains("Actors serialize access to their state."))
    }

    @Test func promptOmitsWorkingLineWithoutTaskOrTopic() {
        let prompt = KnowledgeExtractor.prompt(
            context: .init(text: "text sample"), app: "com.apple.Safari", topic: nil)
        #expect(!prompt.contains("working on"))
    }

    @Test func promptForbidsFlashcards() {
        let prompt = KnowledgeExtractor.prompt(
            context: .init(text: "text sample"), app: "com.apple.Safari", topic: nil)
        #expect(prompt.contains("reference notes"))
        #expect(prompt.contains("Do not write quiz questions or flashcards"))
        // The JSON shape must not offer the fields either, or the model fills
        // them in whatever the prose says.
        #expect(!prompt.contains("\"question\""))
        #expect(!prompt.contains("\"answer\""))
    }

    /// A model that volunteers a Q/A anyway must not get a card into the
    /// review queue through the back door — cards are user-requested (§5.2).
    @Test func candidateBecomesReferenceNoteWithoutQA() {
        let activity = Activity(startedAt: 1_000, endedAt: 400_000,
                                appBundle: "com.apple.Safari", category: .learning)
        let note = KnowledgeExtractor.note(
            from: .init(topic: "t", note: "fact", question: "q?", answer: "a", confidence: 0.8),
            activity: activity, sourceURL: "https://x.test/doc", taskKey: nil)
        #expect(note.state == .inbox)
        #expect(note.questionAnswer == nil)
        #expect(!note.body.contains("Q:"))
        #expect(note.body == "fact")
        #expect(note.sourceURL == "https://x.test/doc")
        #expect(note.deck == nil)
    }
}
