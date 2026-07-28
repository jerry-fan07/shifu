import Foundation
import GRDB

/// Task merge suggestions (vault-features.md §5.2) — the shipped half of V3.
/// The day-one embedding spike (design.md §12) showed NLEmbedding separation
/// is too weak for silent centroid *assignment* but strong enough for
/// suggestions: pairwise cosine ≥ threshold over active-task centroids, *and*
/// overlapping sources, surfaces "these look like one task — Merge / Dismiss".
///
/// `autoMerge` then folds the top slice of that queue without asking. The
/// original rule was "never auto-merge", on the grounds that a silent merge
/// destroys user naming and history; what dogfooding showed is that a
/// suggestion queue nobody can drain is its own failure — hundreds of open
/// pairs bury the task list. The gates below preserve the original guarantee
/// instead of the rule: nothing with a name the *user* typed, and nothing
/// the user filed apart under two themes by hand, is ever folded silently.
public enum TaskMerges {
    public static let mergeThresholdKey = "tasks.merge_threshold"
    static let defaultMergeThreshold = 0.9
    static let activeWindowDays = 30

    /// An unresolved "these look like one task" suggestion, awaiting the user.
    /// Accepting merges B into A; dismissing keeps the ordered pair dismissed
    /// permanently via the unique key on `task_merge_suggestions`.
    public struct Pending: Identifiable, Sendable {
        public var id: Int64
        /// The survivor: accepting the merge repoints B's rows here and keeps
        /// this task's name.
        public var taskA: Int64
        public var nameA: String
        public var taskB: Int64
        public var nameB: String
        public var cosine: Double
    }

    // MARK: - Signatures

    /// Writes the durable block signature ("topic; title sample; domain")
    /// for the window's activities. LedgerBuilder's rebuild recreates rows
    /// signature-less every run; this pass re-derives the same strings from
    /// the same observations, so values are stable while ids are not.
    @discardableResult
    public static func writeSignatures(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> Int {
        try database.queue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, topic, domain, app_bundle FROM activities
                WHERE ended_at > ? AND started_at < ?
                  AND category != 'private' AND signature IS NULL
                """, arguments: [from, to])
            for row in rows {
                let title = try String.fetchOne(db, sql: """
                    SELECT window_title FROM observations
                    WHERE session_id = ? AND window_title IS NOT NULL
                      AND LENGTH(window_title) > 3 LIMIT 1
                    """, arguments: [row["id"] as Int64])
                let signature = signature(
                    topic: row["topic"], title: title,
                    domain: row["domain"], appBundle: row["app_bundle"])
                try db.execute(sql: "UPDATE activities SET signature = ? WHERE id = ?",
                               arguments: [signature, row["id"] as Int64])
            }
            return rows.count
        }
    }

    static func signature(
        topic: String?, title: String?, domain: String?, appBundle: String
    ) -> String {
        [topic ?? "", title ?? "", domain ?? appBundle].joined(separator: "; ")
    }

    // MARK: - Weekly suggestion pass

    private struct TaskData {
        var signatures: Set<String> = []
        var sources: Set<String> = []
    }

    /// Active tasks' distinct signatures and sources, last `activeWindowDays`.
    private static func activeTaskData(
        database: ShifuDatabase, cutoff: Int64
    ) throws -> [Int64: TaskData] {
        try database.queue.read { db in
            var out: [Int64: TaskData] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT task_id, signature, domain, app_bundle FROM activities
                WHERE task_id IS NOT NULL AND signature IS NOT NULL
                  AND category != 'private' AND started_at > ?
                """, arguments: [cutoff]) {
                let taskID: Int64 = row["task_id"]
                var data = out[taskID] ?? TaskData()
                data.signatures.insert(row["signature"])
                data.sources.insert((row["domain"] as String?) ?? row["app_bundle"])
                out[taskID] = data
            }
            return out
        }
    }

    private static func centroids(
        of perTask: [Int64: TaskData], embedder: any Embedder
    ) -> [Int64: [Float]] {
        var out: [Int64: [Float]] = [:]
        var vectorCache: [String: [Float]?] = [:]
        for (taskID, data) in perTask {
            let vectors = data.signatures.compactMap { sig -> [Float]? in
                if let cached = vectorCache[sig] { return cached }
                let vector = embedder.embed(sig)
                vectorCache[sig] = vector
                return vector
            }
            if let centroid = EmbedMath.centroid(vectors) { out[taskID] = centroid }
        }
        return out
    }

    /// Centroids are recomputed per run from the last 30 days' signatures
    /// (re-embedding is milliseconds) — never accumulated, so re-running
    /// cannot drift them. A nil-embedding signature simply drops out; an
    /// embedder that can embed nothing makes the whole pass a no-op.
    @discardableResult
    public static func suggest(
        database: ShifuDatabase, embedder: any Embedder, now: Date = Date()
    ) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(activeWindowDays) * 86_400_000
        let perTask = try activeTaskData(database: database, cutoff: cutoff)
        let centroids = centroids(of: perTask, embedder: embedder)
        guard centroids.count > 1 else { return 0 }

        let raw = (try? Settings.get(mergeThresholdKey, database: database)) ?? nil
        let threshold = Float(raw.flatMap(Double.init) ?? defaultMergeThreshold)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let ids = centroids.keys.sorted()

        return try database.queue.write { db in
            var inserted = 0
            for (index, taskA) in ids.enumerated() {
                for taskB in ids[(index + 1)...] {
                    guard let vecA = centroids[taskA], let vecB = centroids[taskB],
                          EmbedMath.cosine(vecA, vecB) >= threshold,
                          let dataA = perTask[taskA], let dataB = perTask[taskB],
                          !dataA.sources.isDisjoint(with: dataB.sources)
                    else { continue }
                    // OR IGNORE: dismissed (and merged) pairs stay that way.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO task_merge_suggestions
                            (task_a, task_b, cosine, status, created_at)
                        VALUES (?, ?, ?, 'new', ?)
                        """, arguments: [taskA, taskB,
                                         Double(EmbedMath.cosine(vecA, vecB)), nowMs])
                    inserted += db.changesCount
                }
            }
            return inserted
        }
    }

    // Auto-merge (§5.2) lives in TaskAutoMerge.swift.

    // MARK: - Task → theme suggestions (vault-features.md §5.3)

    public static let themeThresholdKey = "themes.suggest_threshold"
    static let defaultThemeThreshold = 0.85

    /// An unresolved "add this task to that theme?" suggestion. `task_id` is
    /// unique in `theme_suggestions`, so a task has at most one open
    /// suggestion and a dismissed task stays quiet.
    public struct PendingTheme: Identifiable, Sendable {
        public var id: Int64
        public var taskID: Int64
        public var taskName: String
        public var themeKey: String
        public var themeName: String
        public var cosine: Double
    }

    /// In the same weekly pass: an unthemed active task whose centroid clears
    /// the threshold against a theme centroid (mean of the centroids of the
    /// tasks already sitting in it) becomes a one-tap "Add to X?" suggestion.
    ///
    /// This is a *second* opinion on the same question the clusterer answers
    /// per block, and it exists for the blocks the clusterer declined: those
    /// burn out at `theme_attempts` and would otherwise stay themeless
    /// forever, while their task looks, by embedding, exactly like a theme the
    /// user already has.
    @discardableResult
    public static func suggestThemes(
        database: ShifuDatabase, embedder: any Embedder, now: Date = Date()
    ) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(activeWindowDays) * 86_400_000
        let taskCentroids = centroids(
            of: try activeTaskData(database: database, cutoff: cutoff), embedder: embedder)
        guard !taskCentroids.isEmpty else { return 0 }

        let themes = try dominantThemes(database: database)
        var themeVectors: [String: [[Float]]] = [:]
        for (taskID, centroid) in taskCentroids {
            if let key = themes[taskID] { themeVectors[key, default: []].append(centroid) }
        }
        let themeCentroids = themeVectors.compactMapValues(EmbedMath.centroid)
        guard !themeCentroids.isEmpty else { return 0 }

        let raw = (try? Settings.get(themeThresholdKey, database: database)) ?? nil
        let threshold = Float(raw.flatMap(Double.init) ?? defaultThemeThreshold)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)

        return try database.queue.write { db in
            var inserted = 0
            for (taskID, centroid) in taskCentroids where themes[taskID] == nil {
                let best = themeCentroids
                    .map { ($0.key, EmbedMath.cosine(centroid, $0.value)) }
                    .max { $0.1 < $1.1 }
                guard let best, best.1 >= threshold else { continue }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO theme_suggestions
                        (task_id, theme_key, cosine, status, created_at)
                    VALUES (?, ?, ?, 'new', ?)
                    """, arguments: [taskID, best.0, Double(best.1), nowMs])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// Task id → the theme its time mostly sits in; absent when none of its
    /// blocks are filed. Same ranking the task list shows, so a suggestion
    /// can't propose a theme the row already claims.
    private static func dominantThemes(database: ShifuDatabase) throws -> [Int64: String] {
        try database.queue.read { db in
            var out: [Int64: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT task_id, theme_key FROM \(TaskStore.dominantThemeSQL)
                WHERE rank = 1
                """) {
                out[row["task_id"]] = row["theme_key"]
            }
            return out
        }
    }

    public static func pendingThemes(database: ShifuDatabase) throws -> [PendingTheme] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.task_id, t.name AS task_name,
                       s.theme_key, th.name AS theme_name, s.cosine
                FROM theme_suggestions s
                JOIN tasks t ON t.id = s.task_id
                JOIN themes th ON th.key = s.theme_key
                WHERE s.status = 'new'
                  AND NOT EXISTS (SELECT 1 FROM activities a
                                  WHERE a.task_id = t.id AND a.theme_key IS NOT NULL)
                ORDER BY s.cosine DESC
                """
            ).map { row in
                PendingTheme(id: row["id"], taskID: row["task_id"],
                             taskName: row["task_name"], themeKey: row["theme_key"],
                             themeName: row["theme_name"], cosine: row["cosine"])
            }
        }
    }

    public static func dismissTheme(suggestionID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE theme_suggestions SET status = 'dismissed' WHERE id = ?",
                arguments: [suggestionID])
        }
    }

    /// Accepts: file the task through the same path the row menu uses.
    public static func acceptTheme(
        _ suggestion: PendingTheme, database: ShifuDatabase
    ) throws {
        try TaskStore.assignTheme(taskID: suggestion.taskID, themeKey: suggestion.themeKey,
                                  database: database)
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE theme_suggestions SET status = 'accepted' WHERE id = ?",
                arguments: [suggestion.id])
        }
    }

    // MARK: - UI queries & actions

    /// Open suggestions with live task names, strongest first. Rows whose
    /// tasks vanished (merged away) drop out via the join.
    public static func pending(database: ShifuDatabase) throws -> [Pending] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.task_a, ta.name AS name_a, s.task_b, tb.name AS name_b, s.cosine
                FROM task_merge_suggestions s
                JOIN tasks ta ON ta.id = s.task_a
                JOIN tasks tb ON tb.id = s.task_b
                WHERE s.status = 'new'
                ORDER BY s.cosine DESC
                """
            ).map { row in
                Pending(id: row["id"], taskA: row["task_a"], nameA: row["name_a"],
                        taskB: row["task_b"], nameB: row["name_b"], cosine: row["cosine"])
            }
        }
    }

    public static func dismiss(suggestionID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE task_merge_suggestions SET status = 'dismissed' WHERE id = ?",
                arguments: [suggestionID])
        }
    }

    /// Clears the whole open queue in one action — "these are all fine as
    /// they are". Same permanence as dismissing them one by one: the unique
    /// pair key keeps every one of them from being re-suggested.
    @discardableResult
    public static func dismissAll(database: ShifuDatabase) throws -> Int {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE task_merge_suggestions SET status = 'dismissed' WHERE status = 'new'")
            return db.changesCount
        }
    }

    @discardableResult
    public static func dismissAllThemes(database: ShifuDatabase) throws -> Int {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE theme_suggestions SET status = 'dismissed' WHERE status = 'new'")
            return db.changesCount
        }
    }

    /// Accepts a suggestion: the task with more recorded time survives (it is
    /// the one the user lived in and likely named); the other is absorbed.
    public static func merge(
        _ suggestion: Pending, database: ShifuDatabase, vault: VaultStore?,
        calendar: Calendar = .current
    ) throws {
        let durations: [Int64: Int64] = try database.queue.read { db in
            var out: [Int64: Int64] = [:]
            for taskID in [suggestion.taskA, suggestion.taskB] {
                out[taskID] = try Int64.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(ended_at - started_at), 0)
                    FROM activities WHERE task_id = ?
                    """, arguments: [taskID]) ?? 0
            }
            return out
        }
        let survivor = (durations[suggestion.taskA] ?? 0) >= (durations[suggestion.taskB] ?? 0)
            ? suggestion.taskA : suggestion.taskB
        let absorbed = survivor == suggestion.taskA ? suggestion.taskB : suggestion.taskA
        try TaskStore.merge(survivorID: survivor, absorbedID: absorbed,
                            database: database, vault: vault, calendar: calendar)
    }
}
