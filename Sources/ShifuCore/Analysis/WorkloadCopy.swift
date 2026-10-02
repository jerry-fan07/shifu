import Foundation

/// What a Load reading says, in words — one source for the page and for
/// `shifu load`, so the terminal and the app cannot disagree about what a
/// verdict means (design.md §4.6). Every line names the figures it was
/// fitted from: a verdict the reader cannot check against their own week
/// costs more trust than it buys.
public enum WorkloadCopy {
    public static func title(_ verdict: Workload.Verdict) -> String {
        switch verdict {
        case .tooEarly: return "Too early to say"
        case .holding: return "Holding"
        case .overCommitted: return "Over-committed"
        case .spreadThin: return "Spread thin"
        case .slack: return "Slack"
        case .away: return "A lighter week"
        }
    }

    /// The sentence under the title.
    public static func line(_ reading: Workload.Reading) -> String {
        let week = hours(reading.capacity[0])
        switch reading.verdict {
        case .tooEarly:
            return "Fewer than three of the last four weeks have anything in them. "
                + "The verdict needs a baseline, and that takes about a month of days."
        case .holding:
            guard let baseline = reading.baselineMs else { return "Nothing is slipping." }
            return "\(week) on \(fronts(reading.activeFronts)) this week, against a "
                + "baseline of \(hours(baseline)) a week. Nothing here says drop or push."
        case .overCommitted:
            let demand = hours(reading.demandMsPerWeek)
            let given = hours(max(reading.capacity[0], reading.baselineMs ?? 0))
            return "Open deadlines need \(demand) a week between them; the fronts have "
                + "been getting \(given). Something has to move — a date, a target, or "
                + "a front off the list."
        case .spreadThin:
            let effective = String(format: "%.1f", reading.effectiveFronts)
            return "The week behaved like \(effective) fronts at once and "
                + "\(reading.slipping.count) of them are slipping. Fewer, deeper: pick "
                + "what to park."
        case .slack:
            guard let baseline = reading.baselineMs else { return "" }
            return "\(week) focused this week against a baseline of \(hours(baseline)) — "
                + "with the screen just as busy. The hours were there; the fronts didn't "
                + "get them."
        case .away:
            guard let baseline = reading.baselineMs else { return "" }
            return "\(week) focused this week against \(hours(baseline)), but tracked "
                + "time fell with it. A week away, not a week lost — nothing to correct."
        }
    }

    public static func status(_ status: Workload.Status) -> String {
        switch status {
        case .new: return "new"
        case .rising: return "rising"
        case .steady: return "steady"
        case .slipping: return "slipping"
        case .quiet: return "quiet"
        }
    }

    /// One line for a front's deadline: "needs 3h/wk, getting 40m · 12 days".
    public static func pace(_ pace: Workload.Pace) -> String {
        var parts: [String] = []
        if pace.isOverdue {
            parts.append("overdue \(-pace.daysLeft) day\(pace.daysLeft == -1 ? "" : "s")")
            if let remaining = pace.remainingMs, remaining > 0 {
                parts.append("\(hours(remaining)) still owed")
            }
        } else {
            if let needed = pace.neededMsPerWeek {
                parts.append("needs \(hours(needed))/wk, getting \(hours(pace.gettingMsPerWeek))")
            } else if let remaining = pace.remainingMs, remaining == 0 {
                parts.append("effort met")
            }
            parts.append(days(pace.daysLeft))
        }
        return parts.joined(separator: " · ")
    }

    /// Why a front is on the give-time list.
    public static func reason(_ front: Workload.Front) -> String {
        if let pace = front.pace, pace.isOverdue, (pace.remainingMs ?? 0) > 0 {
            return "overdue with \(hours(pace.remainingMs ?? 0)) still owed"
        }
        if let pace = front.pace, pace.isBehind, let needed = pace.neededMsPerWeek {
            return "needs \(hours(needed))/wk for \(pace.title), getting \(hours(pace.gettingMsPerWeek))"
        }
        return "\(hours(front.thisWeekMs)) this week, usually \(hours(front.meanMs))"
    }

    /// Why a front is on the quiet list.
    public static func quietReason(_ front: Workload.Front, now: Int64) -> String {
        let days = Int((now - front.lastActiveAt) / 86_400_000)
        return "untouched \(days) days · \(hours(front.meanMs))/wk before that"
    }

    // MARK: - Figures

    /// "3h 10m", "40m", "0m" — hours and minutes, never seconds: a week's
    /// figure has no use for them.
    public static func hours(_ ms: Int64) -> String {
        let minutes = max(0, ms) / 60_000
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    static func fronts(_ count: Int) -> String {
        "\(count) front\(count == 1 ? "" : "s")"
    }

    static func days(_ left: Int) -> String {
        switch left {
        case 0: return "due today"
        case 1: return "due tomorrow"
        default: return "\(left) days left"
        }
    }
}
