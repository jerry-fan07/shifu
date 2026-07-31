import Foundation
import ShifuCore

/// The figures the shell itself reads — the source list's counts, the title
/// bar's state, the two lines in the footer. Split out of LedgerStore.swift for
/// length only; everything here is derived from state published there.
@MainActor
extension LedgerStore {
    var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    /// Tracked ms today, clipped the same way every other figure on the
    /// Breakdown page is — so the source list and the hero never disagree.
    var todayMs: Int64 {
        TimeBreakdown.total(todayActivities, from: todayStart, to: Date())
    }

    var todayTotalLabel: String { TimeBreakdown.duration(todayMs) }

    var todayBlockCount: Int { todayActivities.count }

    /// How far the ledger reaches. Not "when the analyzer last ran" — that
    /// would be a number about Shifu; this is a number about your day, and it
    /// is the one that explains a screen emptier than the morning felt.
    var ledgerThrough: Date? {
        let latest = max(
            todayActivities.map(\.endedAt).max() ?? 0,
            recentTasks.map(\.task.lastActiveAt).max() ?? 0)
        guard latest > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(latest) / 1_000)
    }

    /// The footer's first line: whether anything is being recorded, and where
    /// it goes. "local only" is the standing promise, so it is standing text.
    var captureLine: String {
        if let until = pausedUntil, until > Date() {
            return "Paused until \(until.formatted(.dateTime.hour().minute()))"
        }
        return focusModeOn ? "Focus Mode on · local only" : "Capture on · local only"
    }

    /// The menu bar's second line: what shape the day has, and what most of it
    /// went into. Two facts, because the total alone never answers the
    /// question the menu bar is opened to ask.
    var todayHeadline: String {
        let total = todayMs
        guard total > 0 else { return "Nothing tracked yet" }
        var parts: [String] = []
        let work = todayActivities
            .filter { $0.category == "work" }
            .reduce(0) { $0 + $1.durationMs }
        if work > 0 { parts.append("\(Int((Double(work) / Double(total) * 100).rounded()))% work") }

        var byTask: [String: Int64] = [:]
        for block in todayActivities {
            guard let task = block.taskName else { continue }
            byTask[task, default: 0] += block.durationMs
        }
        if let top = byTask.max(by: { $0.value < $1.value }),
           Double(top.value) / Double(total) > 0.2 {
            parts.append("most of it on \(top.key)")
        }
        return parts.isEmpty ? "\(todayBlockCount) blocks" : parts.joined(separator: " · ")
    }

    /// Blocks over an arbitrary window — the Week page and the Themes
    /// sparklines each read one of these once, on appear.
    func activities(sinceWeeksAgo weeks: Int) -> [LedgerBuilder.LabeledActivity] {
        let calendar = Calendar.current
        let start = calendar.date(
            byAdding: .weekOfYear, value: -(weeks - 1),
            to: calendar.startOfWeek(for: Date())) ?? todayStart
        return labeledActivities(from: start, to: Date())
    }
}
