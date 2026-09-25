import Foundation

/// Reading a due date the way a person types one (design.md §4.5).
///
/// Pure and locale-fixed on purpose: this parses *input*, and input that only
/// works in one region is a bug the author never sees. `DeadlineCopy` handles
/// the other direction, where the locale should absolutely be the user's.
public enum DeadlineDate {
    public struct Parsed: Equatable, Sendable {
        /// Unix ms. Local midnight of the day for an all-day deadline, so the
        /// day arithmetic in `DeadlineHorizon` has nothing to round.
        public var dueAt: Int64
        public var allDay: Bool

        public init(dueAt: Int64, allDay: Bool) {
            self.dueAt = dueAt
            self.allDay = allDay
        }
    }

    /// Accepts, in this order: `2026-08-30`, `2026-08-30 17:00` (or with a `T`),
    /// `17:00` on its own, `today`/`tomorrow`, a weekday name (the next one, or
    /// a week out if today is it), and `+10d` / `+2w` / `+3m`.
    ///
    /// Returns nil rather than guessing. A misread deadline is worse than a
    /// rejected one: the reminder arrives on a day that means nothing and the
    /// user has no way to tell it was misread until it is late.
    public static func parse(
        _ text: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        calendar: Calendar = .current
    ) -> Parsed? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty else { return nil }
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1_000))
        return absolute(input, today: today, calendar: calendar)
            ?? relative(input, today: today, calendar: calendar)
            ?? weekday(input, today: today, calendar: calendar)
            ?? offset(input, today: today, calendar: calendar)
            ?? timeOnly(input, today: today, calendar: calendar)
    }

    // MARK: - Forms

    /// `2026-08-30`, optionally followed by `17:00` or `T17:00` (and `:ss`).
    private static func absolute(
        _ input: String, today: Date, calendar: Calendar
    ) -> Parsed? {
        let parts = input.split(whereSeparator: { $0 == " " || $0 == "t" })
        guard let datePart = parts.first else { return nil }
        let fields = datePart.split(separator: "-")
        guard fields.count == 3,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              year >= 1_970, (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        var allDay = true
        if parts.count > 1, let clock = self.clock(String(parts[1])) {
            components.hour = clock.hour
            components.minute = clock.minute
            allDay = false
        }
        guard let date = calendar.date(from: components) else { return nil }
        return Parsed(dueAt: ms(allDay ? calendar.startOfDay(for: date) : date), allDay: allDay)
    }

    private static func relative(_ input: String, today: Date, calendar: Calendar) -> Parsed? {
        switch input {
        case "today": return Parsed(dueAt: ms(today), allDay: true)
        case "tomorrow", "tmr":
            guard let day = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return Parsed(dueAt: ms(day), allDay: true)
        default: return nil
        }
    }

    /// A weekday name means the *next* one. Saying "friday" on a Friday means
    /// the Friday coming, not the one you are standing in — a deadline you
    /// would set for today you would say "today".
    private static func weekday(_ input: String, today: Date, calendar: Calendar) -> Parsed? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let short = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        guard let index = names.firstIndex(of: input) ?? short.firstIndex(of: input)
        else { return nil }
        let current = calendar.component(.weekday, from: today) - 1
        let ahead = (index - current + 7) % 7
        guard let day = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: today)
        else { return nil }
        return Parsed(dueAt: ms(day), allDay: true)
    }

    /// `+10d`, `+2w`, `+3m`. The leading `+` is required: a bare `10` is far
    /// more likely to be a mistyped date than "ten days from now".
    private static func offset(_ input: String, today: Date, calendar: Calendar) -> Parsed? {
        guard input.hasPrefix("+"), let unit = input.last else { return nil }
        let digits = input.dropFirst().dropLast()
        guard let count = Int(digits), count > 0 else { return nil }
        let component: Calendar.Component
        switch unit {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        default: return nil
        }
        guard let day = calendar.date(byAdding: component, value: count, to: today)
        else { return nil }
        return Parsed(dueAt: ms(day), allDay: true)
    }

    /// `17:00` alone is today at that hour — and tomorrow once it has passed,
    /// because a deadline set for a moment already gone is never what was meant.
    private static func timeOnly(_ input: String, today: Date, calendar: Calendar) -> Parsed? {
        guard let clock = clock(input),
              let moment = calendar.date(
                bySettingHour: clock.hour, minute: clock.minute, second: 0, of: today)
        else { return nil }
        return Parsed(dueAt: ms(moment), allDay: false)
    }

    // MARK: - Pieces

    private static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        let fields = text.split(separator: ":")
        guard (2...3).contains(fields.count),
              let hour = Int(fields[0]), let minute = Int(fields[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// Hours as the CLI and the app both accept them: `20`, `20h`, `90m`, `1.5`.
    /// Bare numbers are hours — the unit a person plans effort in.
    public static func parseEffort(_ text: String) -> Int64? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty else { return nil }
        if input.hasSuffix("m"), let minutes = Double(input.dropLast()), minutes > 0 {
            return Int64(minutes * 60_000)
        }
        let hoursText = input.hasSuffix("h") ? String(input.dropLast()) : input
        guard let hours = Double(hoursText), hours > 0 else { return nil }
        return Int64(hours * 3_600_000)
    }
}
