import Foundation

/// The calendar half of a dated lead: what counts as a date span, and how the
/// margin sets one. Split from the line grammar the way `NoteProseDay` splits
/// the day reading — `NoteProse.swift` decides what a line *is*, this file
/// decides what its dates *say*.
extension NoteProse {
    /// One or two `YYYY-MM-DD` dates and nothing but their joiners — the
    /// "to", the dash, the spaces. `**2026-07-28:**` passes; a bold sentence
    /// that happens to contain a date does not.
    static func isDateSpan(_ text: String) -> Bool {
        let dates = isoDates(text)
        guard (1...2).contains(dates.count) else { return false }
        var rest = text
        for date in dates { rest = rest.replacingOccurrences(of: date, with: "") }
        return rest.allSatisfy { " to–—-".contains($0) }
    }

    /// Every `YYYY-MM-DD` in the text, in order, with real months and days —
    /// "1234-56-78" is a number, not a day.
    static func isoDates(_ text: String) -> [String] {
        text.matches(of: /\d{4}-(\d{2})-(\d{2})/).compactMap { match in
            guard let month = Int(match.1), (1...12).contains(month),
                  let day = Int(match.2), (1...31).contains(day)
            else { return nil }
            return String(match.0)
        }
    }

    /// A dated lead as the margin sets it: "Jul 28", "Jul 19–27", or
    /// "Jul 29–Aug 2", in the reader's locale like every other date the app
    /// prints — whether the file wrote ISO dates or "July 20–25". The full
    /// form stays in the file; the margin is a *place* on the timeline, and
    /// four-digit years there are noise at the width the column can afford.
    /// Unparseable leads come back as written.
    public static func dayLabel(_ span: String) -> String {
        compactLabel(isoDates(span).compactMap(calendarDay))
            ?? compactLabel(monthDayDates(span))
            ?? span
    }

    /// The calendar range a dated lead covers, for a rail that has to place
    /// it to scale. Month-name spans anchor to year 2000; the two forms never
    /// mix inside one timeline, so relative placement holds either way.
    public static func spanDates(_ span: String) -> ClosedRange<Date>? {
        let iso = isoDates(span).compactMap(calendarDay)
        let days = iso.isEmpty ? monthDayDates(span) : iso
        guard let first = days.first, let last = days.last else { return nil }
        return min(first, last)...max(first, last)
    }

    private static func compactLabel(_ days: [Date]) -> String? {
        guard let first = days.first else { return nil }
        let firstLabel = first.formatted(.dateTime.month(.abbreviated).day())
        guard days.count > 1, let last = days.last, last != first else { return firstLabel }
        let sameMonth = Calendar(identifier: .gregorian)
            .isDate(first, equalTo: last, toGranularity: .month)
        return sameMonth
            ? "\(firstLabel)–\(last.formatted(.dateTime.day()))"
            : "\(firstLabel)–\(last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "July 20–25", "July 27", "July 29 – August 2": one or two month-name
    /// days, the second allowed to be a bare day of the first's month. Month
    /// names are matched in English — the models write English whatever the
    /// reader's locale — and anchored to year 2000, which only ever feeds
    /// month-and-day formatting.
    static func monthDayDates(_ text: String) -> [Date] {
        let parts = text.replacingOccurrences(of: " to ", with: "–")
            .split(whereSeparator: { "–—-".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return [] }
        var month: Int?
        var dates: [Date] = []
        for part in parts {
            let tokens = part.split(separator: " ").map(String.init)
            if tokens.count == 2, let named = monthNumber(tokens[0]), let day = Int(tokens[1]) {
                month = named
                dates.append(contentsOf: calendarDay(month: named, day: day).map { [$0] } ?? [])
            } else if tokens.count == 1, let known = month, let day = Int(tokens[0]) {
                dates.append(contentsOf: calendarDay(month: known, day: day).map { [$0] } ?? [])
            }
        }
        return dates.count == parts.count ? dates : []
    }

    private static let englishMonths = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]

    private static func monthNumber(_ token: String) -> Int? {
        let name = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard name.count >= 3 else { return nil }
        return englishMonths.firstIndex { $0.hasPrefix(name) }.map { $0 + 1 }
    }

    private static func calendarDay(month: Int, day: Int) -> Date? {
        guard (1...31).contains(day) else { return nil }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2_000, month: month, day: day))
    }

    /// "2026-07-28" as a `Date`, read in the Gregorian calendar the vault
    /// writes — not the user's, which may number years differently.
    private static func calendarDay(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
