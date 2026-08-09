import Foundation

/// Playing the buffer back, as arithmetic (design.md §3.6).
///
/// **The playhead is a moment, not a frame index.** The buffer is deliberately
/// mixed-cadence — `hotMinutes` at `hotFPS`, then one frame every
/// `frameSeconds` out to `bufferMinutes` — so stepping N indices per tick would
/// run the tail forty times faster than the head and call it 1×. Playback
/// therefore advances a clock through *footage time* and asks
/// `RewindTimeline.nearestFrame` what to draw, which makes 1× mean one second
/// of screen per second of wall clock everywhere on the rail.
///
/// It also survives the live buffer moving underneath it: the recorder appends
/// and the trimmer drops while the page is open, so an index-shaped playhead
/// jumps on every five-second refresh. A moment doesn't — the next tick simply
/// resolves it against the new frame list.
public enum RewindPlayback {
    /// The speeds the transport cycles through. Fast rates matter more than
    /// slow ones here: this is a half-hour of screen you are looking *for*
    /// something in, not a film.
    public static let rates: [Double] = [0.5, 1, 2, 4, 8, 16]

    /// How far a skip button jumps, in seconds of footage.
    public static let skipSeconds: Double = 10

    /// A tick that ran longer than this is a stall — the app was in the
    /// background, the run loop was blocked, the machine slept. Playing the
    /// whole gap at once would teleport the playhead, so the tick is charged
    /// as this much and no more.
    public static let maxTickSeconds: TimeInterval = 0.5

    /// Where the playhead is after a tick.
    public struct Step: Sendable, Equatable {
        /// Footage time, in milliseconds since the epoch.
        public var moment: Double
        /// The clock ran into the live end — the caller stops and parks the
        /// playhead there.
        public var reachedEnd: Bool

        public init(moment: Double, reachedEnd: Bool) {
            self.moment = moment
            self.reachedEnd = reachedEnd
        }
    }

    /// The next speed in the cycle, wrapping. Unknown rates land on 1×, which
    /// is the only sensible answer to "I don't know how fast this is going".
    public static func nextRate(after rate: Double) -> Double {
        guard let index = rates.firstIndex(of: rate) else { return 1 }
        return rates[(index + 1) % rates.count]
    }

    /// "2×", and "0.5×" without a trailing zero — the label a transport wears.
    public static func rateLabel(_ rate: Double) -> String {
        let whole = rate.rounded()
        if abs(rate - whole) < 0.001 { return "\(Int(whole))×" }
        return String(format: "%g×", rate)
    }

    /// Where `elapsed` seconds of wall clock at `rate` puts a playhead sitting
    /// at `moment`, bounded by the footage it is playing.
    ///
    /// A nil `moment` is a playhead parked at the live end, and playing from
    /// there starts the footage over from its oldest frame — the same thing a
    /// video player does when you press play on a finished one.
    public static func advance(
        from moment: Double?, rate: Double, elapsed: TimeInterval, start: Int64, end: Int64
    ) -> Step {
        guard end > start else { return Step(moment: Double(end), reachedEnd: true) }
        let charged = min(max(0, elapsed), maxTickSeconds)
        let from = clamp(moment ?? Double(start), start: start, end: end)
        let landed = from + charged * 1_000 * max(0, rate)
        guard landed < Double(end) else { return Step(moment: Double(end), reachedEnd: true) }
        return Step(moment: landed, reachedEnd: false)
    }

    /// A skip button: `seconds` of footage forward or back from where the
    /// playhead is. Skipping forward off the end lands on the end, which for
    /// the live buffer is "now" — skipping past the present is not a thing.
    public static func skip(
        from moment: Double?, seconds: Double, start: Int64, end: Int64
    ) -> Step {
        guard end > start else { return Step(moment: Double(end), reachedEnd: true) }
        let landed = clamp(moment ?? Double(end), start: start, end: end) + seconds * 1_000
        guard landed < Double(end) else { return Step(moment: Double(end), reachedEnd: true) }
        return Step(moment: max(Double(start), landed), reachedEnd: false)
    }

    /// `m:ss`, or `h:mm:ss` once there is an hour of it — how long a stretch of
    /// footage reads on a transport.
    public static func duration(ms: Int64) -> String {
        let total = max(0, Int(ms / 1_000))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3_600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func clamp(_ moment: Double, start: Int64, end: Int64) -> Double {
        min(max(moment, Double(start)), Double(end))
    }
}
