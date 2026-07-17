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
    /// activities overlapping [from, to).
    @discardableResult
    public static func forgetRange(
        database: ShifuDatabase, from: Date, to: Date
    ) throws -> Counts {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            try db.execute(sql: "DELETE FROM observations WHERE last_seen > ? AND started_at < ?",
                           arguments: [fromMs, toMs])
            let obs = db.changesCount
            try db.execute(sql: "DELETE FROM activities WHERE ended_at > ? AND started_at < ?",
                           arguments: [fromMs, toMs])
            return Counts(observations: obs, activities: db.changesCount)
        }
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
