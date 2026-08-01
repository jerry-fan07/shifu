import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The system-shell denylist (design.md §5.3, §7): the lock screen, the Dock,
/// auth prompts, bundle-less processes and Shifu's own UI.
///
/// It is stated once, in Swift, and enforced at one place — `LedgerBuilder`,
/// as it writes. It used to be enforced at read time by every query that
/// touched `activities`, which meant the rule was only as good as the next
/// query's author remembering it; five remembered and four didn't. So these
/// tests are about the boundary, not about any one reader: nothing downstream
/// needs a clause of its own once the row was never written.
@Suite struct SystemBundleDenylistTests {
    @Test func systemBundlesAreBarredBySetAndPrefix() {
        #expect(TaskGrouper.isSystemBundle("com.apple.loginwindow"))
        #expect(TaskGrouper.isSystemBundle("com.apple.LoginWindow"))
        #expect(TaskGrouper.isSystemBundle("unknown.4242"))   // CaptureEngine's pid fallback
        #expect(TaskGrouper.isSystemBundle("com.shifu.app"))  // self-observation
        #expect(!TaskGrouper.isSystemBundle("com.mitchellh.ghostty"))
        #expect(!TaskGrouper.isSystemBundle("com.google.chrome"))
    }

    /// The whole guarantee in one assertion: a shell observed is a shell not
    /// in the ledger. Both prefix families and a bundle whose case doesn't
    /// match the list, since the check compares lowercased.
    @Test func systemShellObservationsBecomeNoActivity() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            let seeded = [
                ("com.apple.dt.Xcode", Int64(0), Int64(60_000)),
                ("com.apple.loginwindow", 200_000, 3_600_000),
                ("com.apple.dock", 3_800_000, 3_830_000),
                ("com.shifu.app", 4_000_000, 4_030_000),
                ("unknown.4213", 4_200_000, 4_230_000),
                ("com.apple.LoginWindow", 4_400_000, 4_430_000),
                ("com.mitchellh.ghostty", 4_600_000, 4_660_000)
            ]
            for (bundle, start, end) in seeded {
                var observation = Observation(
                    startedAt: start, lastSeen: end, appBundle: bundle,
                    windowTitle: "w", captureKind: .ax, text: "text")
                try observation.insert(sqlite)
            }
        }

        let summary = try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(), from: 0, to: 5_000_000)
        #expect(summary.blocksWritten == 2)

        let bundles = try db.queue.read {
            try String.fetchAll($0, sql: "SELECT app_bundle FROM activities ORDER BY started_at")
        }
        #expect(bundles == ["com.apple.dt.Xcode", "com.mitchellh.ghostty"])
    }

    /// Why the filter takes *blocks* and not observations. The sessionizer
    /// tiles — a gap under `gapThresholdMs` is credited to the block before it
    /// — so a shell dropped before sessionizing would let its neighbour swallow
    /// the gap and end somewhere else. A span is `carriedDerivedState`'s key,
    /// so a moved span re-bills that block's card and its grouping verdict on
    /// the next rebuild: the shell would cost tokens by leaving.
    @Test func droppingAShellLeavesItsNeighboursSpansAlone() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            // Xcode, then a 30-second lock — under the 120 s threshold, so the
            // tiling rule would extend Xcode over it — then Xcode again.
            let seeded = [
                ("com.apple.dt.Xcode", Int64(0), Int64(60_000)),
                ("com.apple.loginwindow", 70_000, 100_000),
                ("com.apple.dt.Xcode", 110_000, 170_000)
            ]
            for (bundle, start, end) in seeded {
                var observation = Observation(
                    startedAt: start, lastSeen: end, appBundle: bundle,
                    windowTitle: "w", captureKind: .ax, text: "swift code editing")
                try observation.insert(sqlite)
            }
        }

        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let spans = try db.queue.read { sqlite in
            try Row.fetchAll(
                sqlite, sql: "SELECT started_at, ended_at FROM activities ORDER BY started_at"
            ).map { ($0["started_at"] as Int64, $0["ended_at"] as Int64) }
        }
        // Two Xcode blocks with a hole where the lock was. Filtering the
        // observations instead would leave the sessionizer two adjacent Xcode
        // rows 50 s apart and merge them into one block spanning the lock.
        #expect(spans.count == 2)
        #expect(spans.first?.0 == 0)
        #expect(spans.first?.1 == 70_000)
        #expect(spans.last?.0 == 110_000)
    }

    /// The guarantee users actually care about, end to end: 90 minutes at the
    /// lock screen — well past the substance gate, and carrying a topic, which
    /// used to be enough to mint `topic:waiting-at-the-lock-screen` — produces
    /// no task. The grouper has no denylist of its own to do this with; it
    /// simply never sees a block.
    @Test func anObservedLockScreenNeverBecomesATask() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            var lock = Observation(
                startedAt: 0, lastSeen: 5_400_000, appBundle: "com.apple.loginwindow",
                windowTitle: "Login Window", captureKind: .ax, text: "waiting at the lock screen")
            try lock.insert(sqlite)
        }
        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(), from: 0, to: 6_000_000)
        let summary = try TaskGrouper.run(database: db, from: 0, to: 6_000_000)

        #expect(summary.tasksTouched == 0)
        let counts = try db.queue.read { sqlite in
            (tasks: try Int.fetchOne(sqlite, sql: "SELECT COUNT(*) FROM tasks") ?? -1,
             logs: try Int.fetchOne(sqlite, sql: "SELECT COUNT(*) FROM task_logs") ?? -1)
        }
        #expect(counts.tasks == 0)
        #expect(counts.logs == 0)
    }

    /// The rows are derived, so the denylist is not a one-way door: the
    /// observation behind a dropped block stays, and `--rebuild` re-derives the
    /// ledger from observations. That is what makes the list safe to be
    /// "grounded rather than exhaustive" — a bundle listed by mistake costs a
    /// rebuild, not the time it covered.
    @Test func shellObservationsSurviveSoTheLedgerCanBeReDerived() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            var observation = Observation(
                startedAt: 0, lastSeen: 600_000, appBundle: "com.apple.dock",
                windowTitle: "Dock", captureKind: .ax, text: "dock")
            try observation.insert(sqlite)
        }
        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        #expect(try db.queue.read { try Activity.fetchCount($0) } == 0)

        // The observation is untouched, which is the whole basis of the claim.
        let observations = try db.queue.read { try Observation.fetchCount($0) }
        #expect(observations == 1)
    }
}
