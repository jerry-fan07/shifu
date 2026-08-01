import Foundation
import GRDB

/// The ledger's live edge (design.md §4.4): raw observations the analyzer
/// hasn't folded into activities yet, read back as stand-in blocks so a
/// running Focus session can score its own last hour instead of waiting for
/// the hourly fold.
///
/// Tier-1 classification only, on purpose. These rows are ephemeral — the
/// analyzer will fold and possibly relabel the same minutes, and nothing here
/// is written back — and the rules tier is the same one the daemon's glow
/// pulse runs on, so the line the page draws and the nudge on the screen
/// cannot disagree about what just happened.
public enum ObservationTail {
    /// Observations overlapping (after, to), clamped to it, oldest first.
    /// `after` should be the fold's high-water mark (or the session start,
    /// whichever is later) so a straddling observation's already-folded half
    /// isn't counted twice. IDs are negated into their own namespace so a
    /// stand-in can never collide with a folded activity row.
    public static func activities(
        after: Int64, to: Int64, database: ShifuDatabase, classifier: RulesClassifier
    ) throws -> [LedgerBuilder.LabeledActivity] {
        guard to > after else { return [] }
        let rows = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, started_at, last_seen, app_bundle, url, capture_kind
                FROM observations
                WHERE last_seen > ? AND started_at < ?
                ORDER BY started_at
                """, arguments: [after, to])
        }
        return rows.compactMap { row in
            let start = max(row["started_at"] as Int64? ?? after, after)
            let end = min(row["last_seen"] as Int64? ?? to, to)
            guard end > start else { return nil }
            let bundle: String = row["app_bundle"] ?? ""
            let domain = Sessionizer.domain(of: row["url"])
            let verdict = classifier.classify(block: Sessionizer.Block(
                appBundle: bundle, domain: domain, startedAt: start, endedAt: end,
                observationIDs: [], titles: [],
                excluded: (row["capture_kind"] as String?) == CaptureKind.excluded.rawValue))
            return LedgerBuilder.LabeledActivity(
                id: -(row["id"] as Int64? ?? 0),
                startedAt: start, endedAt: end,
                category: verdict.category.rawValue,
                source: domain ?? bundle)
        }
    }
}
