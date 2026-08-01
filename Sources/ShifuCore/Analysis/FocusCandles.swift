import Foundation

/// The running session read as a market: a focus index that gains a point for
/// every on-task minute and loses one for every off-task minute (neutral
/// minutes hold), resampled into open-high-low-close candles for the slab's
/// chart. The index is a shape, not a score — `FocusReport` owns the score;
/// this only says *when* the session rose and fell.
///
/// Pure functions over already-read rows, like `FocusReport`: no database, no
/// clock, so a series can be checked in a test. The on/off split is
/// `FocusReport.leaning`, so the candles can never disagree with the score
/// printed beside them.
public enum FocusCandles {
    /// One bucket of the session. `open`…`close` in index points; a candle
    /// whose close matches its open is a doji — a stretch that said nothing.
    public struct Candle: Identifiable, Equatable, Sendable {
        public let id: Int
        public let open: Double
        public let high: Double
        public let low: Double
        public let close: Double

        public init(id: Int, open: Double, high: Double, low: Double, close: Double) {
            self.id = id
            self.open = open
            self.high = high
            self.low = low
            self.close = close
        }

        public var direction: Direction {
            if close > open { return .up }
            if close < open { return .down }
            return .flat
        }
    }

    public enum Direction: Sendable { case up, down, flat }

    private static let minuteMs: Int64 = 60_000

    /// The index itself: one reading per minute boundary, starting at zero.
    /// Each minute moves it by its classified balance as a share of the
    /// minute — a full on-task minute is +1, a half-tracked one half that —
    /// so untracked and neutral stretches draw flat rather than optimistic.
    /// The Focus page draws this raw as a line; `series` folds it into
    /// candles for the rail's slab.
    public static func path(
        from: Int64, to: Int64,
        activities: [LedgerBuilder.LabeledActivity]
    ) -> [Double] {
        guard to > from else { return [] }
        let minuteCount = Int((to - from + minuteMs - 1) / minuteMs)

        // Classified ms per minute, split by which way they pull.
        var onMs = [Double](repeating: 0, count: minuteCount)
        var offMs = [Double](repeating: 0, count: minuteCount)
        for activity in activities {
            let pull = FocusReport.leaning(activity.category)
            guard pull != 0 else { continue }
            let start = max(activity.startedAt, from)
            let end = min(activity.endedAt, to)
            guard end > start else { continue }
            let first = Int((start - from) / minuteMs)
            let last = Int((end - from - 1) / minuteMs)
            for minute in first...last {
                let minuteStart = from + Int64(minute) * minuteMs
                let overlap = Double(min(end, minuteStart + minuteMs) - max(start, minuteStart))
                guard overlap > 0 else { continue }
                if pull > 0 { onMs[minute] += overlap } else { offMs[minute] += overlap }
            }
        }

        var readings = [Double](repeating: 0, count: minuteCount + 1)
        for minute in 0..<minuteCount {
            let minuteStart = from + Int64(minute) * minuteMs
            let length = Double(min(to, minuteStart + minuteMs) - minuteStart)
            let delta = length > 0 ? (onMs[minute] - offMs[minute]) / length : 0
            readings[minute + 1] = readings[minute] + delta
        }
        return readings
    }

    /// The session [from, to) as at most `candles` candles, oldest first. A
    /// session younger than `candles` minutes gets one candle per minute — the
    /// chart fills rightward as the session ages, the way a market opens.
    public static func series(
        from: Int64, to: Int64,
        activities: [LedgerBuilder.LabeledActivity],
        candles: Int
    ) -> [Candle] {
        guard candles > 0 else { return [] }
        let path = path(from: from, to: to, activities: activities)
        guard path.count > 1 else { return [] }
        let minuteCount = path.count - 1

        // Minutes folded into buckets, spread as evenly as integer math can.
        let count = min(candles, minuteCount)
        var series: [Candle] = []
        series.reserveCapacity(count)
        for bucket in 0..<count {
            let firstMinute = bucket * minuteCount / count
            let lastMinute = (bucket + 1) * minuteCount / count
            var high = path[firstMinute]
            var low = high
            for step in firstMinute...lastMinute {
                high = max(high, path[step])
                low = min(low, path[step])
            }
            series.append(Candle(
                id: bucket, open: path[firstMinute], high: high, low: low,
                close: path[lastMinute]))
        }
        return series
    }
}
