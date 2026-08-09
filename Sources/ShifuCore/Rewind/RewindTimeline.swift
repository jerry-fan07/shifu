import Foundation

/// The rail under the player, as data (design.md §3.6).
///
/// The Rewind page draws four strips over one span — fidelity, apps, tasks, and
/// the marks where something was saved — and every one of them is the same
/// arithmetic: turn a list of stamped things into fractions of a span. Doing it
/// here rather than in the view is what lets it be checked against a span with
/// one frame in it, a span with none, and a span where every frame is excluded,
/// none of which are states you can conveniently put a real buffer into.
public enum RewindTimeline {
    /// One contiguous stretch of the rail — an app, or a gap where nothing was
    /// captured. Positions are fractions of the span, 0…1.
    public struct Band: Sendable, Equatable, Identifiable {
        public var start: Double
        public var end: Double
        /// Nil for an excluded stretch: there is no app to name, because
        /// nothing was looked at.
        public var label: String?
        public var excluded: Bool
        /// Where in the frame list this band begins — what a click on the rail
        /// scrubs to.
        public var frameIndex: Int

        public var id: Int { frameIndex }
        public var width: Double { max(0, end - start) }

        public init(
            start: Double, end: Double, label: String?, excluded: Bool, frameIndex: Int
        ) {
            self.start = start
            self.end = end
            self.label = label
            self.excluded = excluded
            self.frameIndex = frameIndex
        }
    }

    /// A saved rewind or snip, as a tick on the rail: where in this span it was
    /// taken from.
    public struct Mark: Sendable, Equatable, Identifiable {
        public var at: Double
        public var id: Int64
        public var title: String

        public init(at: Double, id: Int64, title: String) {
            self.at = at
            self.id = id
            self.title = title
        }
    }

    /// The span the rail covers. Always the *configured* window rather than the
    /// frames' own extent, so a buffer that has only been filling for a minute
    /// draws as one minute of a five-minute rail instead of stretching to fill
    /// it — the rail's width is a promise about how far back you can go.
    public struct Span: Sendable, Equatable {
        public var start: Int64
        public var end: Int64

        public init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
        }

        public var lengthMs: Int64 { max(1, end - start) }

        /// Where a moment sits on the rail, 0…1, clamped to it.
        public func fraction(of moment: Int64) -> Double {
            min(1, max(0, Double(moment - start) / Double(lengthMs)))
        }
    }

    /// The span a buffer of `settings` reaches over, ending now.
    public static func span(now: Int64, settings: RewindSettings) -> Span {
        Span(start: now - settings.bufferMs, end: now)
    }

    /// Frames → bands, merging consecutive frames that share an app (and every
    /// consecutive excluded frame, which all say the same nothing).
    ///
    /// A band runs to the *next* band's start rather than to its own last
    /// frame, so the strip has no gaps between apps — the seconds between two
    /// frames belong to the app that was there when the earlier one was taken.
    public static func bands(frames: [RewindFrame], span: Span) -> [Band] {
        guard !frames.isEmpty else { return [] }
        var bands: [Band] = []
        for (index, frame) in frames.enumerated() {
            let key = frame.excluded ? nil : frame.appBundle
            if var last = bands.last, last.label == key, last.excluded == frame.excluded {
                last.end = span.fraction(of: frame.capturedAt)
                bands[bands.count - 1] = last
                continue
            }
            let start = span.fraction(of: frame.capturedAt)
            if !bands.isEmpty { bands[bands.count - 1].end = start }
            bands.append(Band(
                start: start, end: start, label: key,
                excluded: frame.excluded, frameIndex: index))
        }
        // The last band runs to the live end of the rail: what was on screen at
        // the newest frame is what is on screen now.
        bands[bands.count - 1].end = 1
        return bands
    }

    /// How long each app held the screen, longest first — the legend under the
    /// rail. Excluded time is its own entry with a nil label, because "1m
    /// excluded" is a fact worth printing rather than one to leave off.
    public static func legend(bands: [Band], span: Span) -> [(label: String?, ms: Int64)] {
        var totals: [String: Int64] = [:]
        var excluded: Int64 = 0
        for band in bands {
            let ms = Int64(band.width * Double(span.lengthMs))
            if band.excluded || band.label == nil {
                excluded += ms
            } else if let label = band.label {
                totals[label, default: 0] += ms
            }
        }
        var entries = totals
            .map { (label: Optional($0.key), ms: $0.value) }
            .sorted { $0.ms > $1.ms }
        if excluded > 0 { entries.append((label: nil, ms: excluded)) }
        return entries
    }

    /// The marks: every saved rewind or snip whose moment falls inside the
    /// span. A rewind saved an hour ago has no place on a five-minute rail.
    public static func marks(saved: [SavedRewind], span: Span) -> [Mark] {
        saved.compactMap { rewind in
            guard let id = rewind.id, rewind.endedAt >= span.start, rewind.endedAt <= span.end
            else { return nil }
            return Mark(at: span.fraction(of: rewind.endedAt), id: id, title: rewind.title)
        }
    }

    /// The frame nearest a moment, as an index into `frames`.
    ///
    /// **Nearest, not the one before it.** A click on the rail is a gesture at
    /// a moment, and rounding down puts the viewport visibly behind the finger
    /// — up to a whole frame interval behind, which at the default cadence is
    /// five seconds of "the scrubber is lagging".
    public static func nearestFrame(to moment: Int64, in frames: [RewindFrame]) -> Int? {
        var best: Int?
        var distance = Int64.max
        for index in frames.indices {
            let gap = abs(frames[index].capturedAt - moment)
            if gap < distance {
                distance = gap
                best = index
            }
        }
        return best
    }

    /// The axis ticks: `count` evenly spaced labels across the span, in local
    /// wall-clock, with the live end named rather than stamped.
    public static func ticks(span: Span, count: Int = 6) -> [(at: Double, label: String)] {
        guard count > 1 else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return (0..<count).map { step in
            let place = Double(step) / Double(count - 1)
            guard step < count - 1 else { return (at: place, label: "now") }
            let moment = span.start + Int64(place * Double(span.lengthMs))
            return (
                at: place,
                label: formatter.string(from: Date(timeIntervalSince1970: Double(moment) / 1_000)))
        }
    }
}
