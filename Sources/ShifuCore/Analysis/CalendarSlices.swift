import Foundation

/// Splitting an activity block across calendar buckets — the hour columns of
/// the Time page and the stepping stones of Today (design.md §7).
///
/// This exists as one function because the naive version is a hang. Walking a
/// range with `date(bySettingHour: hour, minute: 59, second: 59, of: cursor)`
/// looks equivalent and is not:
///
/// - it force-unwraps an optional that is genuinely nil when the wall clock
///   skips that hour (DST spring-forward), and
/// - on the *repeated* hour of a fall-back it resolves to the **first**
///   occurrence, which is behind the cursor — so the cursor moves backwards
///   and the loop never terminates.
///
/// `dateInterval(of:for:)` is DST-correct by construction: the interval it
/// returns contains the cursor, so the walk always advances. The explicit
/// forward-progress guard is a second belt — a calendar that ever returned
/// something degenerate would end the walk rather than freeze the window.
public enum CalendarSlices {
    /// Walks `[from, to)` one calendar `unit` at a time, calling `body` with
    /// the cursor at the start of each slice and the slice's length in ms.
    ///
    /// Slices are clipped to the range at both ends, so a block that straddles
    /// a boundary contributes only what falls inside each bucket and the parts
    /// sum to the overlap — never more.
    public static func walk(
        from: Date, to: Date, unit: Calendar.Component, calendar: Calendar = .current,
        body: (_ sliceStart: Date, _ ms: Int64) -> Void
    ) {
        guard from < to, from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite
        else { return }
        var cursor = from
        while cursor < to {
            let boundary = calendar.dateInterval(of: unit, for: cursor)?.end
                ?? cursor.addingTimeInterval(fallbackLength(of: unit))
            // Forward progress or stop: never spin on a calendar that folds.
            guard boundary > cursor else { return }
            let sliceEnd = min(to, boundary)
            body(cursor, Int64((sliceEnd.timeIntervalSince(cursor) * 1_000).rounded()))
            cursor = boundary
        }
    }

    private static func fallbackLength(of unit: Calendar.Component) -> TimeInterval {
        switch unit {
        case .hour: return 3_600
        case .day: return 86_400
        default: return 3_600
        }
    }
}
