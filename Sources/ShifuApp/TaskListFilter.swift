import Foundation
import ShifuCore

/// How far back the Task log's list reaches. Held as a range rather than a
/// timestamp so the cutoff is recomputed per query (see `LedgerStore.loadTasks`).
enum TaskRange: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case week = "This week"
    case month = "Last 30 days"
    case all = "All time"

    var id: String { rawValue }

    /// Unix ms cutoff, 0 for all time. Day-aligned for `today` so it means
    /// "since midnight", not "in the last 24 hours", and week-aligned for
    /// `week` so it means "since Monday", not "in the last seven days".
    func since(now: Date = Date(), calendar: Calendar = .current) -> Int64 {
        let start: Date
        switch self {
        case .today: start = calendar.startOfDay(for: now)
        case .week: start = calendar.startOfWeek(for: now)
        case .month: start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .all: return 0
        }
        return Int64(start.timeIntervalSince1970 * 1_000)
    }
}

/// The floor on time spent, which is what makes a real roster readable: the
/// grouper mints a task per subject, so most of them are a stray minute.
enum TaskMinimum: String, CaseIterable, Identifiable, Hashable {
    case any = "Any length"
    case oneMinute = "1 min+"
    case fiveMinutes = "5 min+"
    case halfHour = "30 min+"

    var id: String { rawValue }

    var ms: Int64 {
        switch self {
        case .any: return 0
        case .oneMinute: return 60_000
        case .fiveMinutes: return 300_000
        case .halfHour: return 1_800_000
        }
    }
}

/// The Task log's filter bar (design.md §5.3): how far back, how long, how to
/// order, which theme. Session state — deliberately not persisted, so
/// reopening the window always shows the unfiltered list.
struct TaskListFilter: Equatable {
    var range: TaskRange = .all
    /// Defaults to a floor rather than `.any`: an unfiltered roster is mostly
    /// stray minutes, and the header's "N of M" keeps the exclusion visible
    /// rather than silent.
    var minimum: TaskMinimum = .fiveMinutes
    var sort: TaskStore.Sort = .mostRecent
    var theme: TaskStore.ThemeScope = .any

    /// Whether the list is showing fewer tasks than exist. Sort reorders
    /// rather than narrows, so it stays out of this — an empty list under a
    /// non-default sort means no data, not an over-tight filter.
    var narrowsResults: Bool { range != .all || minimum != .any || theme != .any }

    /// Whether anything differs from the default — drives the "clear"
    /// affordance, which should also undo a non-default sort.
    var isNarrowed: Bool { self != TaskListFilter() }

    func core(now: Date = Date(), calendar: Calendar = .current, limit: Int)
        -> TaskStore.TaskFilter {
        TaskStore.TaskFilter(
            since: range.since(now: now, calendar: calendar),
            minimumMs: minimum.ms,
            themeScope: theme, sort: sort, limit: limit)
    }
}

/// What the review session pulls cards from (design.md §5.2): everything, one
/// theme's tasks, or a single task.
enum ReviewDeck: Hashable {
    case all
    case theme(key: String, name: String)
    case task(key: String, name: String)

    var label: String {
        switch self {
        case .all: return "All notes"
        case .theme(_, let name): return name
        case .task(_, let name): return name
        }
    }
}
