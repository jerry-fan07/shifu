import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The system-shell denylist (design.md §5.3, §7): the lock screen, the Dock,
/// auth prompts, bundle-less processes and Shifu's own UI. It is stated *twice* —
/// once in Swift for the grouper, once as SQL for the queries that filter in the
/// database — so these tests cover both statements and their agreement.
@Suite struct SystemBundleDenylistTests {
    @Test func systemBundlesAreBarredBySetAndPrefix() {
        #expect(TaskGrouper.isSystemBundle("com.apple.loginwindow"))
        #expect(TaskGrouper.isSystemBundle("com.apple.LoginWindow"))
        #expect(TaskGrouper.isSystemBundle("unknown.4242"))   // CaptureEngine's pid fallback
        #expect(TaskGrouper.isSystemBundle("com.shifu.app"))  // self-observation
        #expect(!TaskGrouper.isSystemBundle("com.mitchellh.ghostty"))
        #expect(!TaskGrouper.isSystemBundle("com.google.chrome"))
    }

    /// Nothing but this test stops the Swift check and its SQL twin from
    /// drifting, and a drift is silent: one surface would keep charting or
    /// grouping a shell the other had already dropped.
    @Test func theSQLPredicateAgreesWithTheSwiftCheck() throws {
        let bundles = TaskGrouper.systemBundles.sorted() + [
            "com.apple.LoginWindow", "unknown.4242", "unknown.-1", "com.shifu.app",
            "com.shifu.app.verify", "com.google.chrome", "com.mitchellh.ghostty",
            "com.apple.dt.Xcode", "com.apple.finder", "com.apple.mail"
        ]
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            for (offset, bundle) in bundles.enumerated() {
                var activity = Activity(
                    startedAt: Int64(offset) * 1_000, endedAt: Int64(offset) * 1_000 + 500,
                    appBundle: bundle, category: .work)
                try activity.insert(sqlite)
            }
        }

        let denied = TaskGrouper.notSystemBundleSQL()
        let admitted = try db.queue.read { sqlite in
            try String.fetchSet(sqlite, sql: """
                SELECT app_bundle FROM activities WHERE \(denied.clause)
                """, arguments: StatementArguments(denied.arguments))
        }
        for bundle in bundles {
            #expect(admitted.contains(bundle) == !TaskGrouper.isSystemBundle(bundle),
                    "SQL and Swift disagree about \(bundle)")
        }
    }
}
