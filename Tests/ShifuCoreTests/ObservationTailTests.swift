import GRDB
import Testing
@testable import ShifuCore

/// The live edge the Focus page reads while the analyzer's fold is still an
/// hour away: raw observations as stand-in blocks, classified by the same
/// rules tier the daemon's glow pulse runs on.
@Suite struct ObservationTailTests {
    private let minute: Int64 = 60_000

    private func observation(
        _ db: ShifuDatabase, bundle: String, from: Int64, to: Int64,
        url: String? = nil, kind: String = "ax"
    ) throws {
        try db.queue.write {
            try $0.execute(sql: """
                INSERT INTO observations (started_at, last_seen, app_bundle, url, capture_kind)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [from, to, bundle, url, kind])
        }
    }

    @Test func tailClassifiesByRulesAndClampsToTheWindow() throws {
        let db = try ShifuDatabase.inMemory()
        // Straddles the fold's high-water mark: only the unfolded half counts.
        try observation(db, bundle: "com.apple.dt.Xcode", from: 0, to: 2 * minute)
        try observation(db, bundle: "com.apple.MobileSMS", from: 2 * minute, to: 4 * minute)
        let tail = try ObservationTail.activities(
            after: minute, to: 4 * minute, database: db, classifier: RulesClassifier())
        #expect(tail.count == 2)
        #expect(tail[0].category == "work")
        #expect(tail[0].startedAt == minute)
        #expect(tail[1].category == "communication")
        #expect(FocusReport.leaning(tail[1].category) == -1)
        // Stand-ins live in their own id namespace, below zero.
        #expect(tail.allSatisfy { $0.id < 0 })
    }

    @Test func excludedCapturesStayOpaqueAndNeutral() throws {
        let db = try ShifuDatabase.inMemory()
        try observation(
            db, bundle: "com.apple.Safari", from: 0, to: minute, kind: "excluded")
        let tail = try ObservationTail.activities(
            after: 0, to: minute, database: db, classifier: RulesClassifier())
        #expect(tail.count == 1)
        #expect(FocusReport.leaning(tail[0].category) == 0)
    }

    @Test func domainBeatsBundleForBrowserTime() throws {
        let db = try ShifuDatabase.inMemory()
        try observation(
            db, bundle: "com.apple.Safari", from: 0, to: minute,
            url: "https://github.com/anthropics/shifu/pull/1")
        let tail = try ObservationTail.activities(
            after: 0, to: minute, database: db, classifier: RulesClassifier())
        #expect(tail.first.map { FocusReport.leaning($0.category) } == 1)
    }

    @Test func anEmptyOrDrainedWindowReadsNothing() throws {
        let db = try ShifuDatabase.inMemory()
        try observation(db, bundle: "com.apple.dt.Xcode", from: 0, to: minute)
        #expect(try ObservationTail.activities(
            after: minute, to: 2 * minute, database: db,
            classifier: RulesClassifier()).isEmpty)
        #expect(try ObservationTail.activities(
            after: minute, to: minute, database: db,
            classifier: RulesClassifier()).isEmpty)
    }
}
