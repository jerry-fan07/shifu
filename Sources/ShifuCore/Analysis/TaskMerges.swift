import Foundation
import GRDB

/// Task merge suggestions (vault-features.md §5.2) — the shipped half of V3.
/// The day-one embedding spike (design.md §12) showed NLEmbedding separation
/// is too weak for silent centroid *assignment* but strong enough for
/// user-confirmed suggestions: pairwise cosine ≥ threshold over active-task
/// centroids, *and* overlapping sources, surfaces "these look like one task —
/// Merge / Dismiss". Never auto-merge.
public enum TaskMerges {
    public static let mergeThresholdKey = "tasks.merge_threshold"
    static let defaultMergeThreshold = 0.9
    static let activeWindowDays = 30

    public struct Pending: Identifiable, Sendable {
        public var id: Int64
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

    // MARK: - Task → project suggestions (vault-features.md §5.3)

    public static let projectThresholdKey = "projects.suggest_threshold"
    static let defaultProjectThreshold = 0.85

    public struct PendingProject: Identifiable, Sendable {
        public var id: Int64
        public var taskID: Int64
        public var taskName: String
        public var projectID: Int64
        public var projectName: String
        public var cosine: Double
    }

    /// In the same weekly pass: an unassigned active task whose centroid
    /// clears the threshold against a project centroid (mean of member task
    /// centroids) becomes a one-tap "Add to X?" suggestion. task_id is
    /// unique, so a dismissed task stays quiet.
    @discardableResult
    public static func suggestProjects(
        database: ShifuDatabase, embedder: any Embedder, now: Date = Date()
    ) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(activeWindowDays) * 86_400_000
        let taskCentroids = centroids(
            of: try activeTaskData(database: database, cutoff: cutoff), embedder: embedder)
        guard !taskCentroids.isEmpty else { return 0 }

        let assignments: [Int64: Int64?] = try database.queue.read { db in
            var out: [Int64: Int64?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, project_id FROM tasks") {
                out[row["id"]] = row["project_id"] as Int64?
            }
            return out
        }
        var projectVectors: [Int64: [[Float]]] = [:]
        for (taskID, centroid) in taskCentroids {
            if let projectID = assignments[taskID] ?? nil {
                projectVectors[projectID, default: []].append(centroid)
            }
        }
        let projectCentroids = projectVectors.compactMapValues(EmbedMath.centroid)
        guard !projectCentroids.isEmpty else { return 0 }

        let raw = (try? Settings.get(projectThresholdKey, database: database)) ?? nil
        let threshold = Float(raw.flatMap(Double.init) ?? defaultProjectThreshold)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)

        return try database.queue.write { db in
            var inserted = 0
            for (taskID, centroid) in taskCentroids
            where (assignments[taskID] ?? nil) == nil {
                let best = projectCentroids
                    .map { ($0.key, EmbedMath.cosine(centroid, $0.value)) }
                    .max { $0.1 < $1.1 }
                guard let best, best.1 >= threshold else { continue }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO project_suggestions
                        (task_id, project_id, cosine, status, created_at)
                    VALUES (?, ?, ?, 'new', ?)
                    """, arguments: [taskID, best.0, Double(best.1), nowMs])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    public static func pendingProjects(database: ShifuDatabase) throws -> [PendingProject] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.task_id, t.name AS task_name,
                       s.project_id, p.name AS project_name, s.cosine
                FROM project_suggestions s
                JOIN tasks t ON t.id = s.task_id
                JOIN projects p ON p.id = s.project_id
                WHERE s.status = 'new' AND t.project_id IS NULL
                ORDER BY s.cosine DESC
                """
            ).map { row in
                PendingProject(id: row["id"], taskID: row["task_id"],
                               taskName: row["task_name"], projectID: row["project_id"],
                               projectName: row["project_name"], cosine: row["cosine"])
            }
        }
    }

    public static func dismissProject(suggestionID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE project_suggestions SET status = 'dismissed' WHERE id = ?",
                arguments: [suggestionID])
        }
    }

    /// Accepts: assign via the existing path, then recompile the project note
    /// (deterministic parts; a status paragraph waits for the weekly pass).
    public static func acceptProject(
        _ suggestion: PendingProject, database: ShifuDatabase, vault: VaultStore
    ) throws {
        try TaskStore.assign(taskID: suggestion.taskID, projectID: suggestion.projectID,
                             database: database)
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE project_suggestions SET status = 'accepted' WHERE id = ?",
                arguments: [suggestion.id])
        }
        try ProjectNoteCompiler.compileDeterministic(
            projectID: suggestion.projectID, database: database, vault: vault)
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
