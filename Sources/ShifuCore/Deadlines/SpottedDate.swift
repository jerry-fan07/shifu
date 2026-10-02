import Foundation

/// Reading a date the way it appears *on someone else's screen* (design.md
/// §4.7) — "Sep 25 at 12:00PM", "Monday, September 28", "by Monday 11:59",
/// "9/17", "February 5, 2027", "tomorrow".
///
/// Deliberately not `DeadlineDate`. That one parses *input* the user typed and
/// refuses anything it is not sure of, which is right for a field. This reads
/// prose it was never meant to be read from, so it has to accept every shape a
/// syllabus, an email or a dashboard uses — and every ambiguity is resolved
/// the way a reader would: a year-less date is the next one coming, a weekday
/// is the next one coming, and anything already past when it was *seen* is
/// not a deadline but a record of one.
///
/// Everything is resolved relative to `seenAt`, the moment the text was on
/// screen, never to the clock now: "by Monday" read on a Saturday meant the
/// Monday after that Saturday, however long ago the Saturday was.
public enum SpottedDate {
    public struct Match: Equatable, Sendable {
        /// Unix ms. Local midnight of the day when `allDay`.
        public var dueAt: Int64
        public var allDay: Bool
        /// Where in the line the date text sits, so the caller can read the
        /// words around it and leave the date itself out of a title.
        public var range: Range<String.Index>
        /// The shape it was written in — the scorer treats a dated weekday
        /// with a clock time as more deliberate than a bare "9/17".
        public var hasClock: Bool
        public var hasWeekday: Bool
        public var hasYear: Bool
        /// "tomorrow", "tonight", "end of week" — real, but vaguer than a
        /// calendar date.
        public var relative: Bool
        /// "9/17" — the least deliberate form, and the one a score or a
        /// fraction can wear.
        public var numeric: Bool
        /// A month-name, numeric or ISO date, as opposed to a weekday on its
        /// own or a relative word.
        public var calendarDate: Bool
    }

    /// Further out than this and a date is not something to look out for yet;
    /// it is also what turns a year-less date already past into nothing
    /// rather than next year's. Six months covers an application cycle.
    public static let horizonDays = 180

    // MARK: - Patterns

    private static let months = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]
    private static let monthPattern =
        "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|"
        + "aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    private static let weekdayFull =
        "(monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
    private static let weekdayAny =
        "(mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?)?|fri(?:day)?|"
        + "sat(?:urday)?|sun(?:day)?)"
    /// "12:00PM", "11:59 pm", "5pm", "17:00", "11:59". Hours alone need a
    /// meridiem, or "at 5" would read every "at 5 percent" as a time.
    private static let clockPattern =
        "(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm|a\\.m\\.|p\\.m\\.)|(\\d{1,2}):(\\d{2})(?!\\d)"
    private static let clockTail = "(?:,?\\s+(?:at|@)?\\s*(?:" + clockPattern + "))?"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Month-name forms, with an optional weekday in front, an optional day
    /// range ("November 12–13" is its first day), an optional year and an
    /// optional clock. Groups: 1 weekday, 2 month, 3 day, 4 year, 5… clock.
    private static let monthDay = regex(
        "\\b(?:" + weekdayAny + "\\.?,?\\s+)?" + monthPattern + "\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?"
        + "(?:\\s*[–-]\\s*\\d{1,2}(?:st|nd|rd|th)?)?(?!\\d)(?:,?\\s+(\\d{4}))?(?![\\d:])" + clockTail)
    /// "5 October 2026", "20th September". Groups: 1 day, 2 month, 3 year, 4… clock.
    private static let dayMonth = regex(
        "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?" + monthPattern + "\\.?(?![a-z])"
        + "(?:,?\\s+(\\d{4}))?" + clockTail)
    /// ISO. Groups: 1 year, 2 month, 3 day, 4… clock.
    private static let iso = regex(
        "\\b(\\d{4})-(\\d{2})-(\\d{2})(?:[ T](?:" + clockPattern + "))?")
    /// US numeric "9/17", "10/14/2026". Groups: 1 month, 2 day, 3 year.
    private static let numeric = regex("(?<![\\d/])(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?(?![\\d/])")
    /// A weekday on its own — full names only. "sun", "sat", "mon" and "wed"
    /// are all ordinary words, and "Mon–Thu" is opening hours, not a date.
    /// Groups: 1 weekday, 2… clock.
    private static let weekday = regex(
        "\\b(?:(?:this|next|coming)\\s+)?" + weekdayFull + "\\b" + clockTail)
    /// Groups: 1 phrase, 2… clock.
    private static let relative = regex(
        "\\b(today|tonight|tomorrow|tmrw|eod|end of (?:the )?day|end of (?:the )?week|"
        + "end of (?:the )?month)\\b" + clockTail)

    // MARK: - Reading

    /// The line being read and the moment it was seen — what every resolver
    /// needs besides the match itself.
    private struct Reading {
        var line: String
        var nsLine: NSString
        var seen: Date
        var seenDay: Date
        var calendar: Calendar
    }

    /// How the date was written, carried from the pattern to the `Match`.
    private struct Shape {
        var clock: Clock?
        var hasWeekday = false
        var hasYear = false
        var relative = false
        var numeric = false
        var weekdayOnly = false
    }

    private struct Clock: Equatable {
        var hour: Int
        var minute: Int
    }

    /// Every date in a line, left to right, overlapping candidates resolved
    /// in favour of the more specific form (a month-name date beats the bare
    /// weekday in front of it).
    public static func matches(
        in line: String, seenAt: Int64, calendar: Calendar = .current
    ) -> [Match] {
        let seen = Date(timeIntervalSince1970: Double(seenAt) / 1_000)
        let reading = Reading(line: line, nsLine: line as NSString, seen: seen,
                              seenDay: calendar.startOfDay(for: seen), calendar: calendar)
        var taken: [NSRange] = []
        var found: [Match] = []
        harvest(monthDay, reading, &taken, &found) { result in
            guard let month = months[prefix(result, 2, in: reading)],
                  let day = Int(text(result, 3, in: reading) ?? "") else { return nil }
            let shape = Shape(clock: clock(result, from: 5, in: reading),
                              hasWeekday: result.range(at: 1).location != NSNotFound,
                              hasYear: text(result, 4, in: reading) != nil)
            return resolve(DateComponents(year: Int(text(result, 4, in: reading) ?? ""), month: month, day: day),
                           shape: shape, range: result.range, reading: reading)
        }
        harvest(dayMonth, reading, &taken, &found) { result in
            guard let day = Int(text(result, 1, in: reading) ?? ""),
                  let month = months[prefix(result, 2, in: reading)] else { return nil }
            let shape = Shape(clock: clock(result, from: 4, in: reading),
                              hasYear: text(result, 3, in: reading) != nil)
            return resolve(DateComponents(year: Int(text(result, 3, in: reading) ?? ""), month: month, day: day),
                           shape: shape, range: result.range, reading: reading)
        }
        harvest(iso, reading, &taken, &found) { result in
            let components = DateComponents(
                year: Int(text(result, 1, in: reading) ?? ""), month: Int(text(result, 2, in: reading) ?? ""),
                day: Int(text(result, 3, in: reading) ?? ""))
            return resolve(components, shape: Shape(clock: clock(result, from: 4, in: reading), hasYear: true),
                           range: result.range, reading: reading)
        }
        harvest(numeric, reading, &taken, &found) { result in
            var year = Int(text(result, 3, in: reading) ?? "")
            if let short = year, short < 100 { year = 2_000 + short }
            let components = DateComponents(
                year: year, month: Int(text(result, 1, in: reading) ?? ""),
                day: Int(text(result, 2, in: reading) ?? ""))
            return resolve(components, shape: Shape(hasYear: year != nil, numeric: true),
                           range: result.range, reading: reading)
        }
        harvest(weekday, reading, &taken, &found) { result in
            guard let name = text(result, 1, in: reading)?.lowercased(),
                  let index = weekdayIndex(name) else { return nil }
            return resolveWeekday(index, shape: Shape(clock: clock(result, from: 2, in: reading)),
                                  range: result.range, reading: reading)
        }
        harvest(relative, reading, &taken, &found) { result in
            guard let phrase = text(result, 1, in: reading)?.lowercased() else { return nil }
            return resolveRelative(phrase, shape: Shape(clock: clock(result, from: 2, in: reading)),
                                   range: result.range, reading: reading)
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    public static func first(
        in line: String, seenAt: Int64, calendar: Calendar = .current
    ) -> Match? {
        matches(in: line, seenAt: seenAt, calendar: calendar).first
    }

    /// Runs one pattern over the line and keeps each match that does not
    /// overlap one already kept and that `build` can resolve.
    private static func harvest(
        _ regex: NSRegularExpression, _ reading: Reading,
        _ taken: inout [NSRange], _ found: inout [Match],
        build: (NSTextCheckingResult) -> Match?
    ) {
        let whole = NSRange(location: 0, length: reading.nsLine.length)
        for result in regex.matches(in: reading.line, range: whole) {
            guard !taken.contains(where: { NSIntersectionRange($0, result.range).length > 0 }),
                  let match = build(result)
            else { continue }
            taken.append(result.range)
            found.append(match)
        }
    }

    // MARK: - Resolution

    /// A calendar date to a moment, or nil when it is not one to look out
    /// for: already past when seen, past the horizon, or not a real day.
    private static func resolve(
        _ components: DateComponents, shape: Shape, range: NSRange, reading: Reading
    ) -> Match? {
        guard let month = components.month, let day = components.day,
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let candidateYears: [Int]
        if let year = components.year {
            guard year >= 2_000, year <= 2_100 else { return nil }
            candidateYears = [year]
        } else {
            let thisYear = reading.calendar.component(.year, from: reading.seenDay)
            candidateYears = [thisYear, thisYear + 1]
        }
        for candidate in candidateYears {
            guard let date = reading.calendar.date(from: DateComponents(year: candidate, month: month, day: day)),
                  reading.calendar.component(.day, from: date) == day
            else { return nil }   // Feb 30 and friends
            if date < reading.seenDay { continue }   // a year-less past date tries next year
            return place(day: date, shape: shape, range: range, reading: reading)
        }
        return nil
    }

    private static func resolveWeekday(
        _ index: Int, shape: Shape, range: NSRange, reading: Reading
    ) -> Match? {
        let calendar = reading.calendar
        let current = calendar.component(.weekday, from: reading.seenDay) - 1
        var ahead = (index - current + 7) % 7
        // The same weekday means today only while its hour is still ahead;
        // "by Monday 11:59" read at Monday noon is next week's Monday, and
        // read without a clock at all it is the one coming, not the one
        // half-spent.
        if ahead == 0 {
            if let clock = shape.clock, let moment = calendar.date(
                bySettingHour: clock.hour, minute: clock.minute, second: 0, of: reading.seenDay),
               moment > reading.seen {
                ahead = 0
            } else {
                ahead = 7
            }
        }
        guard let day = calendar.date(byAdding: .day, value: ahead, to: reading.seenDay) else { return nil }
        var marked = shape
        marked.hasWeekday = true
        marked.weekdayOnly = true
        return place(day: day, shape: marked, range: range, reading: reading)
    }

    private static func resolveRelative(
        _ phrase: String, shape: Shape, range: NSRange, reading: Reading
    ) -> Match? {
        let calendar = reading.calendar
        let seenDay = reading.seenDay
        let day: Date?
        switch phrase {
        case "today", "tonight", "eod", "end of day", "end of the day":
            day = seenDay
        case "tomorrow", "tmrw":
            day = calendar.date(byAdding: .day, value: 1, to: seenDay)
        case "end of week", "end of the week":
            // Friday — the end of the week that has deadlines in it.
            let ahead = (6 - calendar.component(.weekday, from: seenDay) + 7) % 7
            day = calendar.date(byAdding: .day, value: ahead, to: seenDay)
        case "end of month", "end of the month":
            day = calendar.dateInterval(of: .month, for: seenDay)
                .flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
        default:
            day = nil
        }
        guard let day else { return nil }
        var marked = shape
        marked.relative = true
        return place(day: day, shape: marked, range: range, reading: reading)
    }

    /// The last step every form shares: apply the clock, check the horizon,
    /// and convert the NSRange back into the caller's string.
    private static func place(day: Date, shape: Shape, range: NSRange, reading: Reading) -> Match? {
        let calendar = reading.calendar
        guard let distance = calendar.dateComponents([.day], from: reading.seenDay, to: day).day,
              distance >= 0, distance <= horizonDays,
              let swiftRange = Range(range, in: reading.line)
        else { return nil }
        var moment = day
        var allDay = true
        if let clock = shape.clock, let timed = calendar.date(
            bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day) {
            moment = timed
            allDay = false
        }
        return Match(
            dueAt: Int64((moment.timeIntervalSince1970 * 1_000).rounded()), allDay: allDay,
            range: swiftRange, hasClock: shape.clock != nil, hasWeekday: shape.hasWeekday,
            hasYear: shape.hasYear, relative: shape.relative, numeric: shape.numeric,
            calendarDate: !shape.relative && !shape.weekdayOnly)
    }

    // MARK: - Pieces

    private static func text(_ result: NSTextCheckingResult, _ group: Int, in reading: Reading) -> String? {
        let range = result.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return reading.nsLine.substring(with: range)
    }

    private static func prefix(_ result: NSTextCheckingResult, _ group: Int, in reading: Reading) -> String {
        String((text(result, group, in: reading) ?? "").lowercased().prefix(3))
    }

    /// The clock groups are laid out as `clockPattern` has them: hour,
    /// minute, meridiem for the 12-hour form, then hour, minute for the
    /// 24-hour form. `from` is the group index of the first.
    private static func clock(_ result: NSTextCheckingResult, from: Int, in reading: Reading) -> Clock? {
        if let hourText = text(result, from, in: reading), let hour = Int(hourText) {
            let minute = Int(text(result, from + 1, in: reading) ?? "") ?? 0
            let meridiem = (text(result, from + 2, in: reading) ?? "").lowercased()
            guard (1...12).contains(hour), (0...59).contains(minute) else { return nil }
            return Clock(hour: hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0), minute: minute)
        }
        if let hourText = text(result, from + 3, in: reading), let hour = Int(hourText),
           let minute = Int(text(result, from + 4, in: reading) ?? "") {
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            // "11:59" with no meridiem is a deadline's 11:59, and those are
            // never in the morning.
            if minute == 59 && hour < 12 { return Clock(hour: hour + 12, minute: minute) }
            return Clock(hour: hour, minute: minute)
        }
        return nil
    }

    private static func weekdayIndex(_ name: String) -> Int? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return names.firstIndex { $0.hasPrefix(name.prefix(3)) }
    }
}
