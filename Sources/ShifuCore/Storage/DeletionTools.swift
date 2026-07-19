import Foundation
import GRDB

/// Deletion tooling (design.md §8, implementation.md Phase 6): the user can
/// inspect, export, and delete everything.
public enum DeletionTools {
    public struct Counts: Equatable, Sendable {
        public var observations: Int
        public var activities: Int
    }

    /// "Forget this afternoon": removes raw observations *and* derived
    /// activities overlapping [from, to), rebuilds the affected days' task
    /// logs, and — when a vault is passed — recompiles the affected days'
    /// work notes from what survives (vault-features.md §V7). Days emptied
    /// entirely lose their notes; boundary days keep only surviving content.
    @discardableResult
    public static func forgetRange(
        database: ShifuDatabase, from: Date, to: Date,
        vault: VaultStore? = nil, calendar: Calendar = .current
    ) throws -> Counts {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        let days = TaskGrouper.affectedDays(of: [(fromMs, toMs)], calendar: calendar)
        let counts = try database.queue.write { db in
            try db.execute(sql: "DELETE FROM observations WHERE last_seen > ? AND started_at < ?",
                           arguments: [fromMs, toMs])
            let obs = db.changesCount
            try db.execute(sql: "DELETE FROM activities WHERE ended_at > ? AND started_at < ?",
                           arguments: [fromMs, toMs])
            let acts = db.changesCount
            for day in days {
                try TaskGrouper.rebuildLogs(db, dayStart: day.start, dayEnd: day.end)
            }
            return Counts(observations: obs, activities: acts)
        }
        if let vault {
            try WorkNoteCompiler.recompile(
                days: days, database: database, vault: vault, calendar: calendar)
        }
        return counts
    }

    /// Per-app purge: everything ever recorded for a bundle id.
    @discardableResult
    public static func purgeApp(database: ShifuDatabase, bundleID: String) throws -> Counts {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM observations WHERE app_bundle = ?",
                           arguments: [bundleID])
            let obs = db.changesCount
            try db.execute(sql: "DELETE FROM activities WHERE app_bundle = ?",
                           arguments: [bundleID])
            return Counts(observations: obs, activities: db.changesCount)
        }
    }

    /// The kill switch: removes the database, vault, and digests entirely.
    /// Callers are responsible for confirming with the user first.
    public static func deleteEverything(home: URL = ShifuPaths.home) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil)
        for item in contents where item.lastPathComponent != "bin" {
            try FileManager.default.removeItem(at: item)
        }
    }
}
