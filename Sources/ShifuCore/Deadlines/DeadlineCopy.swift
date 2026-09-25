import Foundation

/// The words a reminder is made of (design.md §4.5), kept apart from the policy
/// that decides *whether* to speak so both can be read on their own.
///
/// Every line here is written for a notification banner, which is two short
/// lines and no scrolling. The rules: name the promise, then the date in the
/// form a person would say it, then — only when Shifu genuinely knows it — the
/// work already done. Never a number Shifu had to guess.
public enum DeadlineCopy {
    /// "3h 20m", "45m", "20h". Nearly the app's `TimeBreakdown.duration`,
    /// restated here because that one lives in the ShifuApp target and the CLI
    /// and the notifier both need it — with one difference: a whole number of
    /// hours drops the minutes. Targets are typed in round hours, and "of 20h
    /// 0m logged" is a figure that draws attention to its own formatting.
    public static func duration(_ ms: Int64) -> String {
        let minutes = max(0, ms / 60_000)
        if minutes < 60 { return "\(minutes)m" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// How a person says the distance to a day: "today", "tomorrow", "in 5
    /// days", "yesterday", "3 days ago". Weekday names are deliberately not
    /// used — inside a week they read well and outside one they are ambiguous,
    /// and a reminder is the wrong place to make someone count.
    public static func whenPhrase(daysLeft: Int) -> String {
        switch daysLeft {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let days where days > 1: return "in \(days) days"
        default: return "\(-daysLeft) days ago"
        }
    }

    /// The clock time of a timed deadline, in the user's locale ("5:00 PM").
    public static func clock(_ ms: Int64, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1_000)
        return date.formatted(.dateTime.hour().minute().locale(calendar.locale ?? .current))
    }

    /// The date half of a reminder: when it is due, and — when there is a task
    /// behind it — how much has gone in. Overdue leads with the fact that it is
    /// overdue, because that is the part that changes what you do next.
    public static func dateBody(
        _ standing: DeadlineHorizon.Standing, daysLeft: Int, calendar: Calendar = .current
    ) -> String {
        let deadline = standing.deadline
        var when: String
        if daysLeft < 0 {
            when = "was due \(whenPhrase(daysLeft: daysLeft))"
        } else {
            when = "due \(whenPhrase(daysLeft: daysLeft))"
            // The hour matters on the day itself and reads as noise a week out.
            if !deadline.allDay && daysLeft <= 1 {
                when += " at \(clock(deadline.dueAt, calendar: calendar))"
            }
        }
        guard let effort = effortClause(standing) else { return when }
        return "\(when) · \(effort)"
    }

    /// The progress half: a quarter of the intended effort, newly crossed, and
    /// how much runway is left to spend the rest in.
    public static func progressBody(
        _ standing: DeadlineHorizon.Standing, notch: Int, daysLeft: Int
    ) -> String {
        let logged = duration(standing.loggedMs)
        let target = standing.deadline.targetMs.map(duration) ?? logged
        let opening: String
        switch notch {
        case 100: opening = "\(logged) in — the whole \(target) you set"
        case 50: opening = "halfway: \(logged) of \(target)"
        default: opening = "\(notch)% in: \(logged) of \(target)"
        }
        if daysLeft < 0 { return "\(opening), and \(whenPhrase(daysLeft: daysLeft))" }
        if notch == 100 && daysLeft >= 0 { return "\(opening), with \(runway(daysLeft)) to spare" }
        return "\(opening) · due \(whenPhrase(daysLeft: daysLeft))"
    }

    /// "4h 10m of 20h logged", or "4h 10m logged" with no target set. Nil when
    /// the deadline has no task to measure, which is the honest answer rather
    /// than "0m logged" — nothing was measured, not nothing was done.
    public static func effortClause(_ standing: DeadlineHorizon.Standing) -> String? {
        guard standing.deadline.taskID != nil else { return nil }
        let logged = duration(standing.loggedMs)
        guard let target = standing.deadline.targetMs else { return "\(logged) logged" }
        return "\(logged) of \(duration(target)) logged"
    }

    private static func runway(_ daysLeft: Int) -> String {
        switch daysLeft {
        case 0: return "the day"
        case 1: return "a day"
        default: return "\(daysLeft) days"
        }
    }

    /// The line the Coming-up band and `shifu due` both print for one row:
    /// "Thesis draft — due tomorrow · 4h 10m of 20h logged".
    public static func summary(
        _ standing: DeadlineHorizon.Standing, now: Int64, calendar: Calendar = .current
    ) -> String {
        let daysLeft = DeadlineHorizon.daysUntil(
            dueAt: standing.deadline.dueAt, now: now, calendar: calendar)
        if standing.deadline.isDone { return "\(standing.deadline.title) — done" }
        return "\(standing.deadline.title) — \(dateBody(standing, daysLeft: daysLeft, calendar: calendar))"
    }
}
