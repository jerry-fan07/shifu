import Foundation

/// Deterministic pattern miner (design.md §6.1): structural repetition in
/// activity sequences. Pure over rows; cheap enough to run weekly.
public enum PatternMiner {
    public struct Pattern: Equatable, Sendable {
        public var key: String            // stable identity, e.g. "ngram:a>b"
        public var kind: String           // ngram | frequent_visit | alternation
        public var evidence: String       // human-readable evidence line
        public var occurrences: Int
        public var avgMinutes: Double
        public var estMinutesSavedWeekly: Double
    }

    /// Label an activity by what the user would call it.
    static func label(_ activity: Activity) -> String {
        activity.domain ?? activity.appBundle.split(separator: ".").last.map(String.init)
            ?? activity.appBundle
    }

    public static func mine(_ activities: [Activity], windowDays: Double = 14) -> [Pattern] {
        let sorted = activities.sorted { $0.startedAt < $1.startedAt }
        var patterns = recurringNgrams(sorted, windowDays: windowDays)
        patterns += frequentShortVisits(sorted, windowDays: windowDays)
        patterns += alternations(sorted, windowDays: windowDays)
        return patterns.sorted { $0.estMinutesSavedWeekly > $1.estMinutesSavedWeekly }
    }

    /// Recurring transition n-grams: `Gmail → Sheets → Gmail` every morning
    /// suggests a ritual (§6.1). Consecutive distinct labels, length 3.
    static func recurringNgrams(_ sorted: [Activity], windowDays: Double) -> [Pattern] {
        let labels = collapseConsecutive(sorted.map(label))
        guard labels.count >= 3 else { return [] }

        var counts: [String: Int] = [:]
        for index in 0..<(labels.count - 2) {
            let gram = [labels[index], labels[index + 1], labels[index + 2]]
            guard Set(gram).count == gram.count else { continue }   // skip A>B>A here
            counts[gram.joined(separator: " → "), default: 0] += 1
        }

        return counts.filter { $0.value >= 5 }.map { gram, count in
            let weekly = Double(count) / windowDays * 7
            return Pattern(
                key: "ngram:\(gram)",
                kind: "ngram",
                evidence: "sequence \(gram) seen \(count)× in \(Int(windowDays)) days",
                occurrences: count,
                avgMinutes: 0,
                estMinutesSavedWeekly: weekly * 2   // assume ~2 min of glue work per run
            )
        }
    }

    /// High-frequency short visits: 30 visits/day to one dashboard suggests
    /// an alerting gap (§6.1).
    static func frequentShortVisits(_ sorted: [Activity], windowDays: Double) -> [Pattern] {
        var visits: [String: (count: Int, totalMs: Int64)] = [:]
        for activity in sorted where activity.durationMs < 120_000 {
            let key = label(activity)
            visits[key, default: (0, 0)].count += 1
            visits[key]!.totalMs += activity.durationMs
        }
        return visits.compactMap { key, stat in
            let perDay = Double(stat.count) / windowDays
            guard perDay >= 10 else { return nil }
            let avgMinutes = Double(stat.totalMs) / Double(stat.count) / 60_000
            return Pattern(
                key: "freq:\(key)",
                kind: "frequent_visit",
                evidence: "\(key) visited \(stat.count)× (\(Int(perDay))/day), "
                    + "avg \(String(format: "%.1f", avgMinutes)) min",
                occurrences: stat.count,
                avgMinutes: avgMinutes,
                estMinutesSavedWeekly: perDay * 7 * max(avgMinutes, 0.25)
            )
        }
    }

    /// Manual-transfer signature: rapid alternation between two apps with
    /// copy-adjacent dwell times (§6.1). Runs of A↔B with short blocks.
    static func alternations(_ sorted: [Activity], windowDays: Double) -> [Pattern] {
        var runs: [String: (count: Int, totalMs: Int64)] = [:]
        var index = 0
        while index + 3 < sorted.count {
            let labelA = label(sorted[index])
            let labelB = label(sorted[index + 1])
            guard labelA != labelB else { index += 1; continue }

            // Extend a maximal a,b,a,b… run (each block matches two back).
            var end = index + 1
            while end + 1 < sorted.count, label(sorted[end + 1]) == label(sorted[end - 1]) {
                end += 1
            }
            let runLength = end - index + 1
            let allShort = sorted[index...end].allSatisfy { $0.durationMs < 90_000 }
            if runLength >= 4 && allShort {
                let pair = [labelA, labelB].sorted().joined(separator: " ↔ ")
                let ms = sorted[index...end].reduce(Int64(0)) { $0 + $1.durationMs }
                runs[pair, default: (0, 0)].count += 1
                runs[pair]!.totalMs += ms
                index = end + 1
            } else {
                index += 1
            }
        }
        return runs.compactMap { pair, stat in
            guard stat.count >= 3 else { return nil }
            let avgMinutes = Double(stat.totalMs) / Double(stat.count) / 60_000
            return Pattern(
                key: "alt:\(pair)",
                kind: "alternation",
                evidence: "rapid switching \(pair), \(stat.count) bouts, "
                    + "avg \(String(format: "%.1f", avgMinutes)) min each",
                occurrences: stat.count,
                avgMinutes: avgMinutes,
                estMinutesSavedWeekly: Double(stat.count) / windowDays * 7 * avgMinutes * 0.6
            )
        }
    }

    static func collapseConsecutive(_ labels: [String]) -> [String] {
        var out: [String] = []
        for label in labels where label != out.last {
            out.append(label)
        }
        return out
    }
}
