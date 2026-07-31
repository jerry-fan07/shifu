import Foundation

/// Interval gate for LLM stages that shouldn't bill on every analyzer pass.
/// The pass itself stays hourly — ledger rebuild and grouping are local or
/// cheap — but some *stages* re-bill work whose answer barely changes within
/// a few hours (an open day's narrative, the daily reconciliation).
///
/// Same shape as the radar's weekly watermark (`radar.last_mined`): a settings
/// row holding the last-run timestamp. Callers stamp only after the stage
/// returns without throwing, so a failed run retries on the next pass instead
/// of waiting out the interval.
public enum LLMStageGate {
    public static func due(
        _ key: String, everyMs: Int64, now: Int64, database: ShifuDatabase
    ) -> Bool {
        // Never stamped means due, whatever the clock says — not "ran at 0".
        guard let last = lastRan(key, database: database) else { return true }
        return now - last >= everyMs
    }

    public static func stamp(_ key: String, now: Int64, database: ShifuDatabase) {
        try? Settings.set(key, to: String(now), database: database)
    }

    static func lastRan(_ key: String, database: ShifuDatabase) -> Int64? {
        ((try? Settings.get(key, database: database)) ?? nil).flatMap(Int64.init)
    }
}
