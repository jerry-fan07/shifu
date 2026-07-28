import Foundation

/// A "week" in the UI is always the calendar week you are *in*, Monday through
/// Sunday — not the seven days behind you. Monday is fixed rather than taken
/// from the locale's `firstWeekday` (Sunday in en_US) so the weekday axis and
/// the heatmap rows read the same everywhere (design.md §7).
extension Calendar {
    /// This calendar with weeks anchored to Monday.
    var mondayFirst: Calendar {
        var calendar = self
        calendar.firstWeekday = 2   // Gregorian weekdays are 1-based from Sunday
        return calendar
    }

    /// Midnight on the Monday of the week containing `date`.
    func startOfWeek(for date: Date) -> Date {
        mondayFirst.dateInterval(of: .weekOfYear, for: date)?.start
            ?? startOfDay(for: date)
    }
}
