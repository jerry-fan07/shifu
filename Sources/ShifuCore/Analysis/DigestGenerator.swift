import Foundation
import GRDB

/// Daily digest (design.md §4.3): time breakdown, top topics/apps, anomalies.
/// Markdown into `~/Shifu/digests/`; the menu bar app notices new files.
public enum DigestGenerator {
    /// Pure renderer — testable without a database.
    public struct TopBlock {
        public let label: String
        public let category: Category
        public let ms: Int64
    }

    struct DayData {
        var date: Date
        var totals: [Category: Int64]
        var topBlocks: [TopBlock]
        var topics: [String]
        var weekAverages: [Category: Int64]   // per-day average over trailing week
        var inboxCount: Int = 0               // new knowledge candidates (§5.1)
        var suggestions: [String] = []        // top radar suggestions (§6.2)
    }

    static func render(_ data: DayData) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d yyyy"
        var lines = ["# Shifu digest — \(formatter.string(from: data.date))", ""]

        let tracked = data.totals.values.reduce(0, +)
        lines.append("## Time")
        lines.append("Tracked: \(hours(tracked))")
        lines.append("")
        for (category, ms) in data.totals.sorted(by: { $0.value > $1.value }) where ms >= 60_000 {
            var line = "- **\(category.rawValue)**: \(hours(ms))"
            // Anomaly: ≥2× the trailing-week average and at least 30 min (§4.3).
            if let avg = data.weekAverages[category], avg > 0, ms >= 1_800_000,
               Double(ms) / Double(avg) >= 2.0 {
                line += "  ⚠️ \(String(format: "%.1f", Double(ms) / Double(avg)))× your daily average"
            }
            lines.append(line)
        }

        if !data.topBlocks.isEmpty {
            lines.append("")
            lines.append("## Longest blocks")
            for block in data.topBlocks.prefix(5) {
                lines.append("- \(block.label) — \(hours(block.ms)) (\(block.category.rawValue))")
            }
        }

        if !data.topics.isEmpty {
            lines.append("")
            lines.append("## Topics")
            for topic in data.topics.prefix(8) {
                lines.append("- \(topic)")
            }
        }

        if data.inboxCount > 0 {
            lines.append("")
            lines.append("## Vault")
            lines.append("\(data.inboxCount) new knowledge candidate\(data.inboxCount == 1 ? "" : "s") awaiting triage")
        }

        if !data.suggestions.isEmpty {
            lines.append("")
            lines.append("## Radar")
            for suggestion in data.suggestions.prefix(3) {
                lines.append("- \(suggestion)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func hours(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%.1f h", Double(ms) / 3_600_000)
    }

    /// Generates the digest for the given day and writes it to `digests/`.
    /// Returns the file URL, or nil if one already exists (idempotent daily).
    @discardableResult
    public static func generate(
        database: ShifuDatabase, day: Date = Date(), force: Bool = false
    ) throws -> URL? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        let url = ShifuPaths.digests.appendingPathComponent("\(stamp.string(from: dayStart)).md")
        if !force && FileManager.default.fileExists(atPath: url.path) { return nil }

        let startMs = Int64(dayStart.timeIntervalSince1970 * 1_000)
        let endMs = startMs + 86_400_000
        let weekStartMs = startMs - 7 * 86_400_000

        let totals = try LedgerBuilder.totals(database: database, from: startMs, to: endMs)
        let weekTotals = try LedgerBuilder.totals(database: database, from: weekStartMs, to: startMs)
        let weekAverages = weekTotals.mapValues { $0 / 7 }

        let (topBlocks, topics) = try database.queue.read { db -> ([TopBlock], [String]) in
            let rows = try Activity
                .filter(sql: "ended_at > ? AND started_at < ?", arguments: [startMs, endMs])
                .order(sql: "(ended_at - started_at) DESC")
                .limit(10)
                .fetchAll(db)
            let blocks = rows.map { activity in
                TopBlock(
                    label: activity.domain ?? activity.appBundle.split(separator: ".").last.map(String.init)
                        ?? activity.appBundle,
                    category: activity.category,
                    ms: activity.durationMs
                )
            }
            let topics = try String.fetchAll(db, sql: """
                SELECT DISTINCT topic FROM activities
                WHERE topic IS NOT NULL AND ended_at > ? AND started_at < ?
                ORDER BY (ended_at - started_at) DESC LIMIT 8
                """, arguments: [startMs, endMs])
            return (blocks, topics)
        }

        guard !totals.isEmpty else { return nil }   // nothing tracked, no digest

        let inboxCount = (try? VaultStore(database: database).inbox().count) ?? 0
        let suggestionLines = ((try? Radar.active(database: database)) ?? []).prefix(3).map {
            $0.title ?? $0.evidence
        }

        let markdown = render(DayData(
            date: dayStart, totals: totals,
            topBlocks: topBlocks,
            topics: topics, weekAverages: weekAverages,
            inboxCount: inboxCount, suggestions: Array(suggestionLines)
        ))
        try FileManager.default.createDirectory(at: ShifuPaths.digests, withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
