import GRDB
import Testing
@testable import ShifuCore

@Suite struct ObservationRecorderTests {
    private func makeRecorder() throws -> (ObservationRecorder, ShifuDatabase) {
        let db = try ShifuDatabase.inMemory()
        return (ObservationRecorder(database: db), db)
    }

    @Test func insertsNewObservation() throws {
        let (recorder, db) = try makeRecorder()
        let outcome = try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Safari",
            windowTitle: "Docs", url: "https://developer.apple.com",
            captureKind: .ax, text: "ScreenCaptureKit overview"
        ))
        guard case .inserted = outcome else {
            Issue.record("expected insert, got \(outcome)")
            return
        }
        let count = try db.queue.read { try Observation.fetchCount($0) }
        #expect(count == 1)
    }

    @Test func nearDuplicateBumpsLastSeen() throws {
        let (recorder, db) = try makeRecorder()
        let text = Array(repeating: "stable page content about swift actors", count: 30)
            .joined(separator: " ")
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: text
        ))
        let second = try recorder.record(.init(
            timestamp: 61_000, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: text + " cursor blink"
        ))
        guard case .refreshed = second else {
            Issue.record("expected refresh, got \(second)")
            return
        }
        let rows = try db.queue.read { try Observation.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].startedAt == 1_000)
        #expect(rows[0].lastSeen == 61_000)
    }

    @Test func changedContentInsertsNewRow() throws {
        let (recorder, db) = try makeRecorder()
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: "swift concurrency actors sendable isolation"
        ))
        try recorder.record(.init(
            timestamp: 61_000, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: "formula one qualifying results monza hamilton"
        ))
        let count = try db.queue.read { try Observation.fetchCount($0) }
        #expect(count == 2)
    }

    @Test func metaOnlySameWindowRefreshes() throws {
        let (recorder, db) = try makeRecorder()
        try recorder.record(.init(timestamp: 1_000, appBundle: "com.apple.dt.Xcode",
                                  windowTitle: "shifu", captureKind: .meta))
        try recorder.record(.init(timestamp: 61_000, appBundle: "com.apple.dt.Xcode",
                                  windowTitle: "shifu", captureKind: .meta))
        let rows = try db.queue.read { try Observation.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].lastSeen == 61_000)
    }

    @Test func excludedNeverStoresText() throws {
        let (recorder, db) = try makeRecorder()
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.1password.1password", windowTitle: "Vault",
            captureKind: .excluded, text: "master password hunter2"
        ))
        let rows = try db.queue.read { try Observation.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].text == nil)
        #expect(rows[0].captureKind == .excluded)
    }

    @Test func textIsRedactedBeforeDisk() throws {
        let (recorder, db) = try makeRecorder()
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Safari", windowTitle: "Checkout",
            captureKind: .ax, text: "card number 4111 1111 1111 1111 exp 12/28"
        ))
        let stored = try db.queue.read { try Observation.fetchOne($0)?.text }
        #expect(stored?.contains("4111") == false)
        #expect(stored?.contains("[REDACTED:CARD]") == true)
    }

    @Test func textIsCapped() throws {
        let (recorder, db) = try makeRecorder()
        let huge = String(repeating: "abcdefgh ", count: 4_000)  // 36 KB
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Terminal", windowTitle: "logs",
            captureKind: .ax, text: huge
        ))
        let stored = try db.queue.read { try Observation.fetchOne($0)?.text }
        #expect((stored?.utf8.count ?? 0) <= ObservationRecorder.maxTextBytes)
    }
}
