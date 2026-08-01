import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Auto-merge, judged per *proposal source* (`v27-merge-source`). Split from
/// TaskMergeTests.swift for length only, the way TaskAutoMerge.swift is split
/// from TaskMerges.swift.
///
/// The column exists because one `cosine` column carried two incompatible
/// scales. An embedding cosine is a geometric fact about two centroids, and
/// 0.9 there still mixed in one wrong pair in five. `TaskReconciler`'s number
/// is a reasoning model's answer after reading both names, both gists, hours
/// logged, days active and top sources. Holding the second to a bar
/// calibrated for the first meant every reconciler proposal was capped at
/// 0.96 on the way in and judged at 0.97 on the way out — so none of them
/// ever folded, including the correct ones, and duplicate tasks accumulated
/// in a queue nobody drained.
@Suite struct TaskAutoMergeSourceTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private var day2: Date { calendar.date(byAdding: .day, value: 1, to: day1)! }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    /// Any signature containing a key maps to that fixed vector, so the two
    /// "capture daemon" topics attract a suggestion and the third task does
    /// not. Mirrors TaskMergeTests' stub.
    private struct Stub: Embedder {
        func embed(_ text: String) -> [Float]? {
            if text.contains("capture daemon") { return EmbedMath.normalize([1, 0, 0]) }
            if text.contains("cooking") { return EmbedMath.normalize([0, 1, 0]) }
            return nil
        }
    }

    /// Two hour-long tasks over one app that should attract a suggestion,
    /// plus an unrelated third. Both sides are real work, so only the
    /// substantial bar applies — the fragment fast path would otherwise mask
    /// what these tests are checking.
    private func seed(_ database: ShifuDatabase) throws {
        try database.queue.write { db in
            for (topic, app, offset) in [
                ("capture daemon", "com.apple.dt.Xcode", 9.0),
                ("capture daemon leak", "com.apple.dt.Xcode", 11.0),
                ("cooking pasta", "com.apple.Safari", 14.0)
            ] {
                var activity = Activity(
                    startedAt: ms(day1.addingTimeInterval(offset * 3_600)),
                    endedAt: ms(day1.addingTimeInterval(offset * 3_600)) + 3_600_000,
                    appBundle: app, category: .work, topic: topic)
                try activity.insert(db)
            }
        }
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))
        try TaskMerges.writeSignatures(database: database, from: ms(day1), to: ms(day2))
        _ = try TaskMerges.suggest(database: database, embedder: Stub(), now: day2)
    }

    /// Forces every open suggestion to one score and source, so a test can put
    /// the seeded pair on either side of either bar.
    private func stamp(
        _ database: ShifuDatabase, cosine: Double, source: String = "embedding"
    ) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE task_merge_suggestions SET cosine = ?, source = ?",
                           arguments: [cosine, source])
        }
    }

    private func id(_ database: ShifuDatabase, key: String) throws -> Int64 {
        try database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks WHERE key = ?", arguments: [key])!
        }
    }

    /// The whole point of v27: the same 0.95 on two substantial tasks stays
    /// put when a *centroid* says so and folds when the *reconciler* does.
    @Test func reconcilerPairsFoldOnTheirOwnScale() throws {
        let embedding = try ShifuDatabase.inMemory()
        try seed(embedding)
        try stamp(embedding, cosine: 0.95)
        #expect(try TaskMerges.autoMerge(database: embedding) == 0)

        let reconciled = try ShifuDatabase.inMemory()
        try seed(reconciled)
        try stamp(reconciled, cosine: 0.95, source: "reconcile")
        #expect(try TaskMerges.autoMerge(database: reconciled) == 1)
    }

    /// Even on its own scale the reconciler has a floor: 0.85 is the model
    /// hedging, and a hedge must not delete a task row.
    @Test func lowConfidenceReconcilerPairsStayForTheUser() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database)
        try stamp(database, cosine: 0.85, source: "reconcile")

        #expect(try TaskMerges.autoMerge(database: database) == 0)
        #expect(try TaskMerges.pending(database: database).count == 1)
    }

    /// For a reconciler pair an *absent* theme is the absence of a judgement,
    /// not a judgement that the two differ. The strict reading — unfiled
    /// compares as its own value — blocked the largest real duplicate on the
    /// dogfood roster ("Shifu Development" against "shifu app development and
    /// task log features") on nothing more than one side never having been
    /// filed. Two hand-filed themes still block.
    @Test func onlyBothSidesHandFiledBlocksAReconcilerPair() throws {
        let oneSide = try ShifuDatabase.inMemory()
        try seed(oneSide)
        try stamp(oneSide, cosine: 0.95, source: "reconcile")
        let shifu = try #require(try ThemeStore.create(named: "Shifu", database: oneSide))
        try TaskStore.assignTheme(taskID: try id(oneSide, key: "topic:capture-daemon"),
                                  themeKey: shifu, database: oneSide)
        #expect(try TaskMerges.autoMerge(database: oneSide) == 1)

        let bothSides = try ShifuDatabase.inMemory()
        try seed(bothSides)
        try stamp(bothSides, cosine: 0.95, source: "reconcile")
        let work = try #require(try ThemeStore.create(named: "Shifu", database: bothSides))
        let travel = try #require(try ThemeStore.create(named: "Travel", database: bothSides))
        try TaskStore.assignTheme(taskID: try id(bothSides, key: "topic:capture-daemon"),
                                  themeKey: work, database: bothSides)
        try TaskStore.assignTheme(taskID: try id(bothSides, key: "topic:capture-daemon-leak"),
                                  themeKey: travel, database: bothSides)
        #expect(try TaskMerges.autoMerge(database: bothSides) == 0)
    }

    /// Setting the auto-merge threshold above 1 switches auto-merge off. That
    /// has to reach the reconciler's scale too, or the off switch is a lie.
    @Test func theOffSwitchAlsoStopsReconcilerPairs() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database)
        try stamp(database, cosine: 0.99, source: "reconcile")
        try Settings.set(TaskMerges.autoMergeThresholdKey, to: "1.1", database: database)

        #expect(try TaskMerges.autoMerge(database: database) == 0)
    }

    /// Rows written before v27 carry the default and keep the stricter bar.
    /// The reconciler's own history is indistinguishable by column value, and
    /// folding it silently on a migration would be a surprise.
    @Test func preMigrationRowsKeepTheEmbeddingBar() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database)
        try database.queue.write { db in
            try db.execute(sql: "UPDATE task_merge_suggestions SET cosine = 0.95")
        }
        let source = try database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT source FROM task_merge_suggestions")
        }
        #expect(source == "embedding")
        #expect(try TaskMerges.autoMerge(database: database) == 0)
    }
}
