import Foundation
import GRDB

// Theme inheritance (design.md §5.3): the token-free half of theme
// assignment. Split from ThemeClusterer.swift for length only — it is the
// same enum, and `run` over there only ever sees what this pass left.

extension ThemeClusterer {
    /// A task's dominant theme takes its unthemed blocks outright when it
    /// holds at least this share of the task's themed time.
    public static let inheritDominanceShare = 0.7

    /// Files unthemed blocks under their task's dominant theme — pure SQL,
    /// zero tokens, runs before the LLM pass so the model only sees blocks
    /// inheritance couldn't place (tasks with no clear theme yet). Existing
    /// themes only, never proposals; user filings are untouched by
    /// construction (a hand-filed block already has its `theme_key`).
    @discardableResult
    public static func inheritFromTasks(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> Int {
        try database.queue.write { db in
            // Themed time per (task, theme) for every task that has unthemed
            // blocks in the window. Joined on `themes` so a stale key from a
            // deleted theme can't propagate.
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.task_id, a.theme_key, SUM(a.ended_at - a.started_at) AS ms
                FROM activities a
                JOIN themes th ON th.key = a.theme_key
                WHERE a.task_id IN (
                        SELECT DISTINCT task_id FROM activities
                        WHERE ended_at > ? AND started_at < ? AND theme_key IS NULL
                          AND task_id IS NOT NULL AND category != 'private')
                  AND a.theme_key IS NOT NULL
                GROUP BY a.task_id, a.theme_key
                """, arguments: [from, to])
            var totalMs: [Int64: Int64] = [:]
            var dominant: [Int64: (key: String, ms: Int64)] = [:]
            for row in rows {
                let task: Int64 = row["task_id"]
                let key: String = row["theme_key"]
                let ms: Int64 = row["ms"]
                totalMs[task, default: 0] += ms
                // Key breaks ties so the answer is stable across runs, same
                // rule as TaskStore.dominantThemeSQL.
                if let best = dominant[task],
                   ms < best.ms || (ms == best.ms && key >= best.key) { continue }
                dominant[task] = (key, ms)
            }
            var filed = 0
            for (task, best) in dominant.sorted(by: { $0.key < $1.key }) {
                guard let total = totalMs[task], total > 0,
                      Double(best.ms) / Double(total) >= inheritDominanceShare
                else { continue }
                try db.execute(sql: """
                    UPDATE activities SET theme_key = ?
                    WHERE task_id = ? AND theme_key IS NULL AND category != 'private'
                      AND ended_at > ? AND started_at < ?
                    """, arguments: [best.key, task, from, to])
                filed += db.changesCount
            }
            return filed
        }
    }
}
