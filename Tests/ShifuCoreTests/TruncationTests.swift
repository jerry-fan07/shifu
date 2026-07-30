import Foundation
import Testing
@testable import ShifuCore

/// The 8 KB cap on captured text (design.md §3.2), which every observation
/// passes through on the capture write path. The cap is in **bytes**, but the
/// cut has to land on a character boundary or the stored text ends in a
/// replacement character — and OCR pages are exactly where multi-byte text and
/// over-cap lengths both show up.
@Suite struct TextTruncationTests {
    private let cap = ObservationRecorder.maxTextBytes

    @Test func textUnderTheCapIsReturnedUntouched() {
        let short = "a normal window's worth of text"
        #expect(ObservationRecorder.truncate(short) == short)
        #expect(ObservationRecorder.truncate("") == "")
    }

    @Test func textExactlyAtTheCapIsUntouched() {
        let exact = String(repeating: "a", count: cap)
        #expect(ObservationRecorder.truncate(exact) == exact)
    }

    @Test func oneByteOverTheCapLosesExactlyOneByte() {
        let over = String(repeating: "a", count: cap + 1)
        #expect(ObservationRecorder.truncate(over).utf8.count == cap)
    }

    @Test func aVeryLongPageIsCutToTheCap() {
        let page = String(repeating: "screen text ", count: 20_000)
        let truncated = ObservationRecorder.truncate(page)
        #expect(truncated.utf8.count <= cap)
        #expect(page.hasPrefix(truncated))
    }

    /// A blind byte cut here would split a scalar and leave U+FFFD on disk.
    @Test func multiByteTextIsNeverCutMidCharacter() {
        for filler in ["日", "é", "🍜", "👩‍💻"] {
            let text = String(repeating: filler, count: cap)   // well over the cap
            let truncated = ObservationRecorder.truncate(text)
            #expect(truncated.utf8.count <= cap)
            #expect(!truncated.unicodeScalars.contains("\u{FFFD}"))
            #expect(text.hasPrefix(truncated))
        }
    }

    /// The boundary case for the back-off loop: a single character that is
    /// itself wider than the bytes left before the cap.
    @Test func aWideCharacterStraddlingTheCapIsDroppedWhole() {
        let head = String(repeating: "a", count: cap - 1)
        let truncated = ObservationRecorder.truncate(head + "日本")
        #expect(truncated == head)
    }

    @Test func truncationHappensBeforeTheTextEverReachesDisk() throws {
        let database = try ShifuDatabase.inMemory()
        let recorder = ObservationRecorder(database: database)
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.example.app", captureKind: .ocr,
            text: String(repeating: "日", count: 20_000)))

        let stored = try database.queue.read {
            try String.fetchOne($0, sql: "SELECT text FROM observations")
        }
        #expect(stored != nil)
        #expect((stored?.utf8.count ?? 0) <= cap)
    }

    /// A dense page is an order of magnitude over the cap; the old
    /// character-at-a-time walk did ~180k removals to get there.
    @Test(.timeLimit(.minutes(1)))
    func cappingAMegabyteOfTextIsNotQuadratic() {
        let huge = String(repeating: "abcdefghij", count: 100_000)   // ~1 MB
        for _ in 0..<50 {
            #expect(ObservationRecorder.truncate(huge).utf8.count == cap)
        }
    }
}
