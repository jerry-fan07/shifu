import Foundation
import GRDB

/// The daily reconciliation pass (design.md §5.3): one reasoning-model call
/// a day reviews the active task roster — the tasks the hourly fast-model
/// stages minted and fed — and proposes what only judgment can see: two
/// names that are one effort, and the one-sentence gists still missing.
///
/// This is where the pricier slot stays in the loop after the hourly
/// grouping moved to the fast model: flash does the assignment volume with
/// card evidence, pro audits the *roster* once a day for a fraction of a
/// cent. Merges land in the existing `task_merge_suggestions` queue and ride
/// its gates; nothing here renames, folds, or deletes anything directly.
public enum TaskReconciler {
    /// Below this the model is guessing, and a guessed merge pair clutters
    /// the queue the auto-merge gates then have to re-judge.
    public static let mergeConfidenceFloor = 0.75
    /// The auto-merge bar (0.97) was calibrated to *embedding cosine*
    /// precision; an LLM's self-reported confidence is a different scale.
    /// Capping what lands in the `cosine` column keeps a substantial pair
    /// from ever folding silently on the model's say-so — fragments may
    /// still fold (their path is documented as the conservative one), and
    /// everything else waits for the user.
    public static let storedScoreCap = 0.96
    public static let responseTokens = 2_000

    public struct Summary: Equatable, Sendable {
        public var mergesSuggested: Int
        public var gistsFilled: Int

        public init(mergesSuggested: Int = 0, gistsFilled: Int = 0) {
            self.mergesSuggested = mergesSuggested
            self.gistsFilled = gistsFilled
        }
    }

    /// One proposed pair, by roster handle.
    struct MergeProposal: Equatable {
        var handleA: String
        var handleB: String
        var confidence: Double
    }

    struct Verdict: Equatable {
        var merges: [MergeProposal] = []
        var gists: [String: String] = [:]   // handle → gist
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(roster: [SemanticTaskGrouper.RosterEntry]) -> String {
        var lines: [String] = [
            "Review the user's active task roster.",
            "Flag pairs that are one ongoing effort under two names — the same goal,",
            "not merely the same website — and write the missing one-sentence gists.",
            "",
            "Tasks (name — gist · time over days · last active · top sources):"
        ]
        for (index, entry) in roster.enumerated() {
            lines.append(SemanticTaskGrouper.rosterLine(
                handle: "t\(index + 1)", entry: entry, detail: .full))
        }
        lines.append(contentsOf: [
            "",
            "Only pair tasks you are confident are the same effort (confidence 0-1).",
            "Only write gists for tasks shown without one; one concrete sentence each.",
            "Either list may be empty. Respond with ONLY JSON:",
            #"{"merges": [{"a": "t1", "b": "t3", "confidence": 0.9}],"#,
            #" "gists": [{"task": "t2", "gist": "Comparing fares and picking dates."}]}"#
        ])
        return lines.joined(separator: "\n")
    }

    static func parse(_ response: String) -> Verdict {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Verdict() }
        var verdict = Verdict()
        for item in object["merges"] as? [[String: Any]] ?? [] {
            guard let handleA = item["a"] as? String, let handleB = item["b"] as? String,
                  handleA != handleB,
                  let confidence = (item["confidence"] as? NSNumber)?.doubleValue
            else { continue }
            verdict.merges.append(MergeProposal(
                handleA: handleA, handleB: handleB, confidence: confidence))
        }
        for item in object["gists"] as? [[String: Any]] ?? [] {
            guard let handle = item["task"] as? String,
                  let gist = (item["gist"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !gist.isEmpty
            else { continue }
            verdict.gists[handle] = String(gist.prefix(200))
        }
        return verdict
    }

    // MARK: - Pipeline

    /// One call over the active roster; a roster of one has nothing to
    /// reconcile. The caller gates this daily (`LLMStageGate`) and stamps
    /// only on success.
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: any LLMBackend, now: Date = Date()
    ) async throws -> Summary {
        var roster = try SemanticTaskGrouper.activeRoster(database: database, now: now)
        guard roster.count > 1 else { return Summary() }
        // Invariant 7: shed the roster's tail rather than fail. With the
        // roster capped at 40 entries this loop never fires in practice.
        let budget = backend.contextWindowTokens - backend.responseReserve(responseTokens)
        while roster.count > 2, LLMTokens.estimate(prompt(roster: roster)) > budget {
            roster.removeLast()
        }
        let response = try await backend.complete(
            prompt: prompt(roster: roster), maxTokens: responseTokens)
        return try apply(parse(response), roster: roster, database: database, now: now)
    }

    /// Writes one verdict: merge pairs land in `task_merge_suggestions`
    /// (score capped — see `storedScoreCap`), gists fill only tasks that
    /// have none. Unknown handles are dropped; ids resolve through the
    /// roster the model was actually shown.
    static func apply(
        _ verdict: Verdict, roster: [SemanticTaskGrouper.RosterEntry],
        database: ShifuDatabase, now: Date = Date()
    ) throws -> Summary {
        var keyByHandle: [String: String] = [:]
        for (index, entry) in roster.enumerated() { keyByHandle["t\(index + 1)"] = entry.key }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            var summary = Summary()
            func taskID(_ handle: String) throws -> Int64? {
                guard let key = keyByHandle[handle] else { return nil }
                return try Int64.fetchOne(
                    db, sql: "SELECT id FROM tasks WHERE key = ?", arguments: [key])
            }
            for merge in verdict.merges where merge.confidence >= mergeConfidenceFloor {
                guard let idA = try taskID(merge.handleA),
                      let idB = try taskID(merge.handleB), idA != idB else { continue }
                // Same ordering as TaskMerges.suggest; OR IGNORE keeps
                // dismissed (and previously merged) pairs dismissed.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO task_merge_suggestions
                        (task_a, task_b, cosine, status, created_at)
                    VALUES (?, ?, ?, 'new', ?)
                    """, arguments: [min(idA, idB), max(idA, idB),
                                     min(merge.confidence, storedScoreCap), nowMs])
                summary.mergesSuggested += db.changesCount
            }
            for (handle, gist) in verdict.gists.sorted(by: { $0.key < $1.key }) {
                guard let id = try taskID(handle) else { continue }
                try db.execute(sql: """
                    UPDATE tasks SET gist = ?
                    WHERE id = ? AND (gist IS NULL OR gist = '')
                    """, arguments: [gist, id])
                summary.gistsFilled += db.changesCount
            }
            return summary
        }
    }
}
