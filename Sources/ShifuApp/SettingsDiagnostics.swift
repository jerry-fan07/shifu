import Foundation
import GRDB
import ShifuCore

/// What the Settings page's right-hand column reads: the machine's own facts,
/// as opposed to the dials on its left.
///
/// The whole point of the column is to answer "is this actually working",
/// which a settings screen normally can't — so every field here is a *measured*
/// number from the same database the daemon writes, never a restatement of a
/// setting. If a number can't be measured it is absent rather than estimated:
/// the daemon's own TCC grants, for one, are not readable from this process
/// (it is a separate binary in `~/Shifu/bin` with its own identity), so this
/// screen does not claim to know them.
struct SettingsDiagnostics: Equatable {
    /// Today's observations, split the way the capture ladder produced them
    /// (§3.2). The split is the useful part: `text` versus `metadata` is
    /// whether the cheap rung is working, and `excluded` is the privacy rules
    /// doing their job.
    var text = 0
    var ocr = 0
    var metadata = 0
    var excluded = 0

    /// Per-model LLM usage since midnight, and what it is estimated to have
    /// cost at the configured rates.
    var llm: [LLMUsage.Totals] = []
    var llmCost: Double = 0

    var databaseBytes: Int64?
    var databaseEncrypted = false

    var captureTotal: Int { text + ocr + metadata + excluded }

    /// Reads everything in one pass. Never throws: a diagnostics column that
    /// can take a page down is worse than one that shows dashes.
    ///
    /// `file` is a parameter only so a test can stay hermetic — in the app it
    /// is always the database that `database` is open on.
    static func read(
        database: ShifuDatabase, file: URL = ShifuPaths.database, now: Date = Date()
    ) -> SettingsDiagnostics {
        var diagnostics = SettingsDiagnostics()
        let dayStart = Int64(
            Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1_000)

        let rows = (try? database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT capture_kind, COUNT(*) AS n FROM observations
                WHERE last_seen >= ? GROUP BY capture_kind
                """, arguments: [dayStart])
        }) ?? []
        for row in rows {
            let count: Int = row["n"]
            switch CaptureKind(rawValue: row["capture_kind"] as String) {
            case .ax: diagnostics.text = count
            case .ocr: diagnostics.ocr = count
            case .meta: diagnostics.metadata = count
            case .excluded: diagnostics.excluded = count
            case nil: break
            }
        }

        let priceBook = LLMPriceBook.load(database: database)
        diagnostics.llm =
            (try? LLMUsage.totals(from: dayStart, to: Int64.max, database: database)) ?? []
        diagnostics.llmCost = diagnostics.llm.reduce(0) { $0 + priceBook.cost(of: $1) }

        diagnostics.databaseBytes = try? FileManager.default
            .attributesOfItem(atPath: file.path)[.size] as? Int64
        diagnostics.databaseEncrypted = ShifuDatabase.isEncrypted(at: file)
        return diagnostics
    }

    /// "128.4 MB" — the one figure on this page that is about disk rather than
    /// about your day, so it gets the same mono treatment and no more.
    var databaseSizeLabel: String {
        guard let bytes = databaseBytes else { return "—" }
        let megabytes = Double(bytes) / 1_048_576
        return megabytes < 10
            ? String(format: "%.1f MB", megabytes)
            : String(format: "%.0f MB", megabytes)
    }

    /// Today's spend as its own figure. Nil rather than "$0.000" on a day
    /// nothing was billed — an untouched instrument should read blank.
    var llmCostLabel: String? {
        llmCost > 0 ? String(format: "≈ $%.3f", llmCost) : nil
    }

    var llmCalls: Int { llm.reduce(0) { $0 + $1.calls } }

    /// Every token that crossed the wire today, in and out. The count is the
    /// ground truth on this page — the dollar figure beside it is an estimate
    /// at rates the user can edit, this is what was actually sent.
    var llmTokensLabel: String {
        let total = llm.reduce(0) { $0 + $1.promptTokens + $1.completionTokens }
        if total >= 1_000_000 { return String(format: "%.1fM", Double(total) / 1_000_000) }
        if total >= 1_000 { return "\(total / 1_000)k" }
        return "\(total)"
    }
}
