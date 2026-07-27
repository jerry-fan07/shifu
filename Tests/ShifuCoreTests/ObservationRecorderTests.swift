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

    // MARK: - Dedupe TTL (design.md §3.4 memory bound; aligned to Sessionizer.gapThresholdMs)

    @Test func dedupeStateExpiresPastTTLInsertsNewRow() throws {
        let (recorder, db) = try makeRecorder()
        let text = Array(repeating: "stable page content about swift actors", count: 30)
            .joined(separator: " ")
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: text
        ))
        // Gap equal to the TTL: the sessionizer would already split a block
        // here, so this must no longer be treated as the same window.
        let afterTTL = 1_000 + ObservationRecorder.dedupeTTLMs
        let second = try recorder.record(.init(
            timestamp: afterTTL, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: text + " cursor blink"
        ))
        guard case .inserted = second else {
            Issue.record("expected a new row once dedupe state expired, got \(second)")
            return
        }
        let count = try db.queue.read { try Observation.fetchCount($0) }
        #expect(count == 2)
    }

    @Test func dedupeStateSurvivesRepeatedHeartbeatsWithinTTL() throws {
        let (recorder, db) = try makeRecorder()
        let text = Array(repeating: "stable page content about swift actors", count: 30)
            .joined(separator: " ")
        let heartbeatMs: Int64 = 60_000
        var timestamp: Int64 = 1_000
        try recorder.record(.init(
            timestamp: timestamp, appBundle: "com.apple.Safari", windowTitle: "Docs",
            captureKind: .ax, text: text
        ))
        // Five more heartbeats, each within the TTL of the previous one, but
        // the total span (300 s) is well past a single 120 s TTL window —
        // this only stays one row if the TTL slides forward on activity
        // instead of being measured from the original insert (design.md §10
        // "one observation for the whole movie").
        var lastOutcome: ObservationRecorder.Outcome?
        for _ in 0..<5 {
            timestamp += heartbeatMs
            lastOutcome = try recorder.record(.init(
                timestamp: timestamp, appBundle: "com.apple.Safari", windowTitle: "Docs",
                captureKind: .ax, text: text + " cursor blink"
            ))
        }
        guard case .refreshed? = lastOutcome else {
            Issue.record("expected the row to still be refreshing, got \(String(describing: lastOutcome))")
            return
        }
        let rows = try db.queue.read { try Observation.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].startedAt == 1_000)
        #expect(rows[0].lastSeen == timestamp)
    }

    @Test func sweepDropsExpiredWindowsFromTrackedCount() throws {
        let (recorder, _) = try makeRecorder()
        try recorder.record(.init(
            timestamp: 0, appBundle: "com.apple.Safari", windowTitle: "A", captureKind: .meta
        ))
        try recorder.record(.init(
            timestamp: 0, appBundle: "com.apple.Safari", windowTitle: "B", captureKind: .meta
        ))
        try recorder.record(.init(
            timestamp: 0, appBundle: "com.apple.Safari", windowTitle: "C", captureKind: .meta
        ))
        #expect(recorder.trackedWindowCount == 3)

        // A record() call at the TTL boundary triggers a sweep; A/B/C's
        // dedupe state is now stale, so only the new window's entry remains.
        try recorder.record(.init(
            timestamp: ObservationRecorder.dedupeTTLMs, appBundle: "com.apple.Safari",
            windowTitle: "D", captureKind: .meta
        ))
        #expect(recorder.trackedWindowCount == 1)
    }

    @Test func touchReturnsFalseAfterTTLExpires() throws {
        let (recorder, db) = try makeRecorder()
        try recorder.record(.init(
            timestamp: 1_000, appBundle: "com.apple.Terminal", windowTitle: "logs", captureKind: .meta
        ))
        let touched = try recorder.touch(
            appBundle: "com.apple.Terminal", windowTitle: "logs", url: nil,
            timestamp: 1_000 + ObservationRecorder.dedupeTTLMs
        )
        #expect(touched == false)
        let stored = try db.queue.read { try Observation.fetchOne($0) }
        #expect(stored?.lastSeen == 1_000)  // untouched: no bump happened
    }

    @Test func touchRenewsTTLAcrossRepeatedCalls() throws {
        let (recorder, db) = try makeRecorder()
        try recorder.record(.init(
            timestamp: 0, appBundle: "com.apple.QuickTimePlayerX", windowTitle: "Movie",
            captureKind: .ocr, text: "opening credits"
        ))
        // Five touches 60 s apart (the capture heartbeat), spanning 300 s —
        // past a single TTL window but each gap comfortably inside it, so
        // the fullscreen-video "whole movie" case never expires.
        let heartbeatMs: Int64 = 60_000
        var timestamp: Int64 = 0
        var lastTouch = false
        for _ in 0..<5 {
            timestamp += heartbeatMs
            lastTouch = try recorder.touch(
                appBundle: "com.apple.QuickTimePlayerX", windowTitle: "Movie", url: nil, timestamp: timestamp
            )
        }
        #expect(lastTouch)
        let stored = try db.queue.read { try Observation.fetchOne($0) }
        #expect(stored?.startedAt == 0)
        #expect(stored?.lastSeen == timestamp)
        let count = try db.queue.read { try Observation.fetchCount($0) }
        #expect(count == 1)
    }
}
