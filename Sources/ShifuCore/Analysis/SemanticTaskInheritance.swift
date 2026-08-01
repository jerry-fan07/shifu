import Foundation
import GRDB

// Neighbour inheritance (design.md §5.3): the token-free half of semantic
// grouping. Split from SemanticTaskGrouper.swift the way ThemeInheritance.swift
// is split from ThemeClusterer.swift — it is the same enum, and the model pass
// only ever sees what this one left unplaced.
//
// It writes `sem_key` directly — the same claim the model makes, arrived at by
// cheaper evidence, exactly as `inheritFromTasks` writes `theme_key` directly.
// A separate "inherited" column would cost the LedgerBuilder carry edits and
// buy nothing: no caller asks how a block came by its task, and riding
// `sem_key` means the verdict is carried across rebuilds for free.

extension SemanticTaskGrouper {
    /// Distraction categories never inherit their neighbours' task: a short
    /// messaging/social/entertainment detour inside a work stretch is a
    /// break from it, never part of it — the same fence the grouping prompt
    /// draws. On 14 dogfood days this rejected 18 of 146 sandwiches, every
    /// one sitting inside a `work` stretch.
    static let breakCategories: Set<Category> = [.communication, .entertainment, .social]

    /// One block of the window, as read for the sandwich walk.
    struct NeighborRow {
        var id: Int64
        var startedAt: Int64
        var endedAt: Int64
        var category: Category
        var semKey: String?
        var semAttempts: Int
    }

    /// Files unplaced sub-minute blocks under the task running on *both*
    /// sides of them — zero tokens, run before the model pass so the sliver
    /// pool it sweeps is already smaller. Only blocks nothing else will
    /// place: sub-`minBlockMs` (a long block is the model's to judge), with
    /// attempts left (a run the model *declined* must not be back-doored in,
    /// the same sentinel ThemeInheritance honours).
    ///
    /// `tasks.last_active_at` is deliberately not bumped — unlike the theme
    /// pass this runs *before* `TaskGrouper.run`, which bumps it for every
    /// key it groups, this one's included.
    @discardableResult
    public static func inheritFromNeighbors(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> Int {
        try database.queue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, category, sem_key, sem_attempts
                FROM activities
                WHERE ended_at > ? AND started_at < ? AND category != 'private'
                ORDER BY started_at
                """, arguments: [from, to]
            ).map { row in
                NeighborRow(id: row["id"], startedAt: row["started_at"],
                            endedAt: row["ended_at"],
                            category: Category(rawValue: row["category"]) ?? .unclassified,
                            semKey: row["sem_key"], semAttempts: row["sem_attempts"])
            }
            var filed = 0
            for (key, ids) in neighborAdoptions(rows).sorted(by: { $0.key < $1.key }) {
                try db.execute(sql: """
                    UPDATE activities SET sem_key = ?
                    WHERE id IN (\(databaseQuestionMarks(count: ids.count)))
                    """, arguments: [key] + StatementArguments(ids))
                filed += ids.count
            }
            return filed
        }
    }

    /// The sandwich policy, pure: task key → block ids that adopt it.
    ///
    /// A candidate's neighbours are the nearest sem-keyed blocks either side
    /// in time — other unplaced blocks between them don't break the
    /// sandwich, but they do widen the gaps, and both gaps must fit inside
    /// `Sessionizer.gapThresholdMs`. That contiguity is what makes the
    /// sandwich mean "inside one sitting" rather than "between two blocks
    /// eleven hours apart" (it cost 16 of 128 dogfood adoptions), and it is
    /// what makes excluding `private` from the read safe: a real private
    /// stretch leaves a hole wider than the threshold.
    static func neighborAdoptions(_ rows: [NeighborRow]) -> [String: [Int64]] {
        let sorted = rows.sorted { $0.startedAt < $1.startedAt }
        var prevSem: [NeighborRow?] = []
        var lastSeen: NeighborRow?
        for row in sorted {
            prevSem.append(lastSeen)
            if row.semKey != nil { lastSeen = row }
        }
        var nextSem = [NeighborRow?](repeating: nil, count: sorted.count)
        var upcoming: NeighborRow?
        for index in sorted.indices.reversed() {
            nextSem[index] = upcoming
            if sorted[index].semKey != nil { upcoming = sorted[index] }
        }

        var adoptions: [String: [Int64]] = [:]
        for (index, row) in sorted.enumerated() {
            guard row.semKey == nil,
                  row.endedAt - row.startedAt < minBlockMs,
                  row.semAttempts < maxAttempts,
                  !breakCategories.contains(row.category),
                  let before = prevSem[index], let after = nextSem[index],
                  let key = before.semKey, after.semKey == key,
                  row.startedAt - before.endedAt <= Sessionizer.gapThresholdMs,
                  after.startedAt - row.endedAt <= Sessionizer.gapThresholdMs
            else { continue }
            adoptions[key, default: []].append(row.id)
        }
        return adoptions
    }
}
