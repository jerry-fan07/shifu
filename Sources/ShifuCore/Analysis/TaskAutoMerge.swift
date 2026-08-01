import Foundation
import GRDB

/// Auto-merge (vault-features.md §5.2): the half of the suggestion queue
/// Shifu resolves on its own. Split from TaskMerges.swift for length only —
/// it is the same enum, and `suggest` upstream is what puts pairs here.
extension TaskMerges {
    public static let autoMergeThresholdKey = "tasks.auto_merge_threshold"
    /// The bar for folding two *substantial* tasks together, well above
    /// `defaultMergeThreshold` (0.9, where the spike measured precision ≈0.8 —
    /// one wrong pair in five, far too many to apply to real work silently).
    /// Set the key above 1 to switch auto-merge off entirely.
    static let defaultAutoMergeThreshold = 0.97
    /// The bar for a *reconciler*-proposed pair (`source = 'reconcile'`,
    /// v27). A different scale needs a different number: 0.97 was calibrated
    /// to embedding cosine, where the score is a geometric accident of two
    /// centroids and 0.9 still mixed one wrong pair in five. The reconciler
    /// reaches its number the way a person would — it is shown both names,
    /// both gists, hours logged, days active and top sources, and asked
    /// whether they are one effort — and it reports in round hundredths.
    /// On the dogfood roster its proposals at ≥0.9 were the three real
    /// duplicate families and nothing else.
    static let defaultLLMAutoMergeThreshold = 0.9
    /// Backstop on the fixed-point loop in `autoMerge`; two or three passes
    /// settle a real backlog.
    static let maxPasses = 10

    /// An unordered task pair, so a lookup doesn't care which side is `task_a`.
    private struct PairKey: Hashable {
        var low: Int64
        var high: Int64

        init(_ left: Int64, _ right: Int64) {
            low = min(left, right)
            high = max(left, right)
        }
    }

    /// A pending pair with everything the safety gates need to judge it.
    private struct Candidate {
        var taskA: Int64
        var taskB: Int64
        var cosine: Double
        var defaultNamed: Bool
        /// The hand-filed theme on each side, if any (`theme_user_set`).
        var filedA: String?
        var filedB: String?
        /// Lifetime activity of the *smaller* side. A pair is a fragment pair
        /// when this is under the substance gate.
        var smallerMs: Int64
        /// Who proposed the pair — `"embedding"` (`TaskMerges.suggest`) or
        /// `"reconcile"` (`TaskReconciler`), which decides which bar
        /// `cosine` is judged against. v27; rows written before it read as
        /// `"embedding"` and keep the stricter treatment.
        var source: String

        var isReconciled: Bool { source == "reconcile" }

        /// Unfiled compares as its own value, so filing one side and leaving
        /// the other alone reads as "these differ" — the pre-v14 `project_id`
        /// semantics, kept for embedding pairs, where the score alone is thin
        /// evidence and any user signal should outweigh it.
        var filedApart: Bool { filedA != filedB }

        /// Both sides were filed by hand, under different themes. This is the
        /// bar a *reconciler* pair is held to: it read both gists and said
        /// they are one effort, which is stronger evidence than a NULL. An
        /// absent theme is the absence of a judgement, not a judgement that
        /// the two differ — and on the dogfood roster the strict reading
        /// alone blocked the largest real duplicate ("Shifu Development" <>
        /// "shifu app development and task log features") on nothing more
        /// than one side never having been filed.
        var filedApartByHand: Bool {
            guard let filedA, let filedB else { return false }
            return filedA != filedB
        }
    }

    /// Folds the unambiguous end of the suggestion queue and leaves the rest
    /// for the user. Runs over the *stored* suggestions rather than fresh
    /// centroids, which is what lets one pass drain a backlog that built up
    /// under the old suggest-only regime.
    ///
    /// Two ways in, because the cost of being wrong is not the same for both:
    ///
    /// - **Fragments** (the smaller side under `TaskGrouper.minNewTaskMs`) fold
    ///   at the ordinary suggestion threshold. A default-named task with under
    ///   five minutes on it is not work the user tracks — `TaskStore.prune`
    ///   already *deletes* exactly that shape once it goes quiet, so folding it
    ///   into its near-twin is the more conservative of the two: the time stays
    ///   in the ledger instead of going task-less. This is where the backlog
    ///   lives — of 679 open pairs on the dogfood DB, 582 have a sub-five-minute
    ///   side and only 9 clear 0.97.
    /// - **Substantial pairs** (both sides real work) need `autoMergeThreshold`.
    ///
    /// On top of that, and regardless of score, a pair is skipped when:
    /// - either task wears a name the *user* typed (`TaskGrouper.isDefaultName`
    ///   is false) — user naming is the thing a silent merge must not destroy;
    /// - the user filed them under two different themes by hand — filing them
    ///   apart is an explicit judgement that they are different work (a theme
    ///   the *clusterer* chose does not count; see `theme_user_set`, v14);
    /// - the pair was dismissed (only `status = 'new'` is read here, so a
    ///   dismissal keeps it out permanently, exactly as before).
    ///
    /// `suggest` having recorded the pair at all already means the two share a
    /// source (domain or app).
    ///
    /// Chains fold to one survivor — A~B and B~C makes all three one task,
    /// and the longest-running member absorbs the rest (same "the one you
    /// lived in" rule as a confirmed merge) — but only fragments ride a chain.
    /// A substantial member must have scored against the survivor itself.
    ///
    /// Runs to a fixed point. One pass resolves each component against the
    /// survivor it had *that* pass; folding a component can leave a member
    /// whose own strong partner is now the biggest thing left, so the next
    /// pass places it. Passes only ever remove pairs (absorbing a task deletes
    /// the open rows naming it), so this terminates — `maxPasses` is a
    /// backstop, not the mechanism.
    @discardableResult
    public static func autoMerge(
        database: ShifuDatabase, vault: VaultStore? = nil, calendar: Calendar = .current
    ) throws -> Int {
        var merged = 0
        for _ in 0..<maxPasses {
            let folded = try autoMergePass(
                database: database, vault: vault, calendar: calendar)
            if folded == 0 { break }
            merged += folded
        }
        return merged
    }

    private static func autoMergePass(
        database: ShifuDatabase, vault: VaultStore?, calendar: Calendar
    ) throws -> Int {
        let autoRaw = (try? Settings.get(autoMergeThresholdKey, database: database)) ?? nil
        let autoThreshold = autoRaw.flatMap(Double.init) ?? defaultAutoMergeThreshold
        let suggestRaw = (try? Settings.get(mergeThresholdKey, database: database)) ?? nil
        let fragmentThreshold = suggestRaw.flatMap(Double.init) ?? defaultMergeThreshold
        // Dialling `autoMergeThresholdKey` above 1 switches auto-merge off.
        // That has to hold for reconciler pairs too, so the LLM bar follows
        // it out of range rather than sitting under a switch the user just
        // turned off. Below that it is its own constant: the two scales are
        // what v27 exists to separate.
        let llmThreshold = autoThreshold > 1 ? autoThreshold : defaultLLMAutoMergeThreshold

        let candidates = try self.candidates(
            database: database,
            minimumCosine: min(autoThreshold, fragmentThreshold, llmThreshold))
        let eligible = candidates.filter { candidate in
            guard candidate.defaultNamed else { return false }
            // A reconciler pair answers to the hand-filing test only; every
            // other gate — default-named, dismissed-stays-dismissed, and the
            // fragment fast path — applies to both sources unchanged.
            guard !(candidate.isReconciled
                        ? candidate.filedApartByHand : candidate.filedApart)
            else { return false }
            if candidate.smallerMs < TaskGrouper.minNewTaskMs {
                return candidate.cosine >= fragmentThreshold
            }
            return candidate.cosine >= (candidate.isReconciled
                                        ? llmThreshold : autoThreshold)
        }
        guard !eligible.isEmpty else { return 0 }

        let groups = components(of: eligible.map { ($0.taskA, $0.taskB) })
        let durations = try lifetimeDurations(
            of: Set(groups.flatMap { $0 }), database: database)
        // "Strong" is per scale, like eligibility: a reconciler pair at 0.95
        // is a direct verdict on these two tasks, so it carries a substantial
        // member across a chain exactly as a 0.97 cosine does.
        let strongPairs = Set(eligible
            .filter { $0.cosine >= ($0.isReconciled ? llmThreshold : autoThreshold) }
            .map { PairKey($0.taskA, $0.taskB) })
        let pairs = groups.flatMap { group -> [TaskStore.MergePair] in
            // Longest-running survives; the lowest id breaks ties, so a rerun
            // over the same data picks the same survivor.
            guard let survivor = group.max(by: { left, right in
                let (leftMs, rightMs) = (durations[left] ?? 0, durations[right] ?? 0)
                return leftMs == rightMs ? left > right : leftMs < rightMs
            }) else { return [] }
            return group
                .filter { member in
                    // Transitivity is only safe for fragments. Two hours of
                    // real work joined by a chain of one-minute scraps is not
                    // evidence that they are the same work, so a substantial
                    // member has to have scored against *this survivor*
                    // directly, at the high bar, to be absorbed. Otherwise it
                    // stays put and the user gets asked.
                    member != survivor
                        && ((durations[member] ?? 0) < TaskGrouper.minNewTaskMs
                            || strongPairs.contains(PairKey(member, survivor)))
                }
                .map { TaskStore.MergePair(survivor: survivor, absorbed: $0) }
        }
        guard !pairs.isEmpty else { return 0 }
        try TaskStore.merge(pairs: pairs, database: database, vault: vault,
                            calendar: calendar, resolution: .automatic)
        return pairs.count
    }

    /// Open pairs at or above `minimumCosine`, each with the facts the gates
    /// judge. The per-side sums ride `idx_activities_task`.
    private static func candidates(
        database: ShifuDatabase, minimumCosine: Double
    ) throws -> [Candidate] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.task_a, s.task_b, s.cosine, s.source,
                       ta.name AS name_a, ta.key AS key_a,
                       tb.name AS name_b, tb.key AS key_b,
                       (SELECT a.theme_key FROM activities a
                        WHERE a.task_id = s.task_a AND a.theme_user_set = 1
                        LIMIT 1) AS filed_a,
                       (SELECT b.theme_key FROM activities b
                        WHERE b.task_id = s.task_b AND b.theme_user_set = 1
                        LIMIT 1) AS filed_b,
                       MIN(COALESCE((SELECT SUM(a.ended_at - a.started_at) FROM activities a
                                     WHERE a.task_id = s.task_a), 0),
                           COALESCE((SELECT SUM(b.ended_at - b.started_at) FROM activities b
                                     WHERE b.task_id = s.task_b), 0)) AS smaller_ms
                FROM task_merge_suggestions s
                JOIN tasks ta ON ta.id = s.task_a
                JOIN tasks tb ON tb.id = s.task_b
                WHERE s.status = 'new' AND s.cosine >= ?
                ORDER BY s.cosine DESC
                """, arguments: [minimumCosine]
            ).map { row in
                // Only *hand* filing is read at all: two tasks the clusterer
                // happened to put in different themes are not a user
                // judgement, and gating on that would stall the queue
                // auto-merge exists to drain. What "apart" then means differs
                // by source — see `filedApart` / `filedApartByHand`.
                Candidate(
                    taskA: row["task_a"], taskB: row["task_b"], cosine: row["cosine"],
                    defaultNamed:
                        TaskGrouper.isDefaultName(row["name_a"], forKey: row["key_a"])
                        && TaskGrouper.isDefaultName(row["name_b"], forKey: row["key_b"]),
                    filedA: row["filed_a"], filedB: row["filed_b"],
                    smallerMs: row["smaller_ms"],
                    source: (row["source"] as String?) ?? "embedding")
            }
        }
    }

    /// Connected components over the qualifying pairs (union-find), so a
    /// fragmentation spread across three keys collapses in one pass instead
    /// of leaving a dangling pair that names a task the first merge deleted.
    static func components(of pairs: [(Int64, Int64)]) -> [[Int64]] {
        var parent: [Int64: Int64] = [:]
        func find(_ id: Int64) -> Int64 {
            var root = parent[id] ?? id
            while let next = parent[root], next != root { root = next }
            parent[id] = root
            return root
        }
        for (left, right) in pairs {
            let (rootLeft, rootRight) = (find(left), find(right))
            parent[left] = rootLeft
            parent[right] = rootRight
            if rootLeft != rootRight { parent[rootRight] = rootLeft }
        }
        var groups: [Int64: [Int64]] = [:]
        for id in Set(pairs.flatMap { [$0.0, $0.1] }).sorted() {
            groups[find(id), default: []].append(id)
        }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    private static func lifetimeDurations(
        of taskIDs: Set<Int64>, database: ShifuDatabase
    ) throws -> [Int64: Int64] {
        guard !taskIDs.isEmpty else { return [:] }
        let ids = Array(taskIDs)
        return try database.queue.read { db in
            var out: [Int64: Int64] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT task_id, COALESCE(SUM(ended_at - started_at), 0) AS total
                FROM activities WHERE task_id IN (\(databaseQuestionMarks(count: ids.count)))
                GROUP BY task_id
                """, arguments: StatementArguments(ids)) {
                out[row["task_id"]] = row["total"]
            }
            return out
        }
    }
}
