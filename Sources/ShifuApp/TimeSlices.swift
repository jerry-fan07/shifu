import ShifuCore
import SwiftUI

/// What the Time tab breaks time down by (design.md §7, §5.3). Both Time-tab
/// modes — the timeline bars and the Screen Time–style summary — read the same
/// lens, so switching modes never changes what a group means.
enum TimeLens: String, CaseIterable {
    case category = "Category"
    case theme = "Theme"
    case task = "Task"

    /// This lens's group label for one activity block.
    func label(_ activity: LedgerBuilder.LabeledActivity) -> String {
        switch self {
        case .category: return activity.category
        case .theme: return activity.themeName ?? "No theme"
        case .task: return activity.taskName ?? "No task"
        }
    }

    /// Categories are lowercase enum raw values; theme and task names are the
    /// user's (or the LLM's) own text and are shown untouched.
    func display(_ group: String) -> String {
        self == .category ? group.capitalized : group
    }

    /// "8 categories", "1 theme".
    func counted(_ count: Int) -> String {
        guard count != 1 else { return "1 \(rawValue.lowercased())" }
        return self == .category ? "\(count) categories" : "\(count) \(rawValue.lowercased())s"
    }
}

/// One group's share of a window: the row of the summary's ranked list and one
/// wedge of its donut. Built by `TimeBreakdown.slices`.
struct TimeSlice: Identifiable {
    /// An app or domain the group's time actually went through.
    struct Source: Identifiable {
        let name: String
        let ms: Int64
        var id: String { name }
    }

    let name: String
    let ms: Int64
    /// 0…1 of the window's tracked time.
    let share: Double
    let color: Color
    let blocks: Int
    /// Hour of day (0–23) the group spent most of its time in, if any.
    let peakHour: Int?
    let sources: [Source]

    var id: String { name }
}

/// Turns labeled activity blocks into ranked `TimeSlice`s.
enum TimeBreakdown {
    /// Where everything past the lens's group limit lands.
    static let otherLabel = "Other"
    /// How many sources a summary row names when expanded.
    static let maxSources = 3

    /// One block, already trimmed to the window and reduced to what the
    /// breakdown counts.
    private struct Clipped {
        let label: String
        let ms: Int64
        let hour: Int
        let source: String
    }

    /// Running totals for one group.
    private struct Tally {
        var ms: Int64 = 0
        var blocks = 0
        var hours: [Int: Int64] = [:]
        var sources: [String: Int64] = [:]
    }

    /// Groups in [from, to), biggest first, with "Other" pinned last.
    ///
    /// Blocks are clipped to the window before they are counted, so a session
    /// that straddles midnight contributes only the part inside it. `limit`
    /// folds everything past the top N into "Other"; the category lens passes
    /// nil because its groups are already a closed, fixed-color set.
    static func slices(
        _ activities: [LedgerBuilder.LabeledActivity], lens: TimeLens,
        from: Date, to: Date, limit: Int?
    ) -> [TimeSlice] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        let clipped = activities.compactMap { activity -> Clipped? in
            let ms = min(activity.endedAt, toMs) - max(activity.startedAt, fromMs)
            guard ms > 0 else { return nil }
            let hour = Calendar.current.component(
                .hour, from: Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000))
            return Clipped(label: lens.label(activity), ms: ms, hour: hour, source: activity.source)
        }

        var totals: [String: Int64] = [:]
        for block in clipped { totals[block.label, default: 0] += block.ms }
        let kept: Set<String>? = limit.map { count in
            Set(totals.sorted { $0.value > $1.value }.prefix(count).map(\.key))
        }

        var groups: [String: Tally] = [:]
        for block in clipped {
            let group = kept.map { $0.contains(block.label) ? block.label : otherLabel } ?? block.label
            var entry = groups[group] ?? Tally()
            entry.ms += block.ms
            entry.blocks += 1
            entry.hours[block.hour, default: 0] += block.ms
            entry.sources[block.source, default: 0] += block.ms
            groups[group] = entry
        }

        let total = groups.values.reduce(0) { $0 + $1.ms }
        // "Other" is a leftover bucket, not a group — it sorts last however big
        // it is, so the eye reads the ranked groups without a hole in them.
        let ranked = groups.sorted { lhs, rhs in
            if (lhs.key == otherLabel) != (rhs.key == otherLabel) { return rhs.key == otherLabel }
            return lhs.value.ms > rhs.value.ms
        }
        let colors = TimePalette.colors(for: ranked.map(\.key), lens: lens)
        return ranked.map { name, entry in
            TimeSlice(
                name: name,
                ms: entry.ms,
                share: total > 0 ? Double(entry.ms) / Double(total) : 0,
                color: colors[name] ?? TimePalette.otherColor,
                blocks: entry.blocks,
                peakHour: entry.hours.max { $0.value < $1.value }?.key,
                sources: entry.sources.sorted { $0.value > $1.value }
                    .prefix(maxSources)
                    .map { TimeSlice.Source(name: $0.key, ms: $0.value) })
        }
    }

    /// Total tracked ms in [from, to), clipped the same way `slices` clips.
    static func total(_ activities: [LedgerBuilder.LabeledActivity], from: Date, to: Date) -> Int64 {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        return activities.reduce(0) { sum, activity in
            sum + max(0, min(activity.endedAt, toMs) - max(activity.startedAt, fromMs))
        }
    }

    /// "4h 12m" — reads faster than "4.2 h" when rows are meant to be compared
    /// down a column. `LedgerStore.hours` still owns the menu bar's one-liner.
    static func duration(_ ms: Int64) -> String {
        let minutes = max(0, ms / 60_000)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "2 PM" in the user's locale.
    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

/// The timeline mode's stacked bars: the same window as `TimeBreakdown.slices`,
/// cut into calendar buckets instead of ranked into groups. Groups come *from*
/// the breakdown so both modes agree on what "Other" holds.
enum TimeBuckets {
    struct Bucket: Identifiable, Equatable {
        let label: String
        let group: String
        let hours: Double
        /// Chronological position, so the bars sort by time rather than by label.
        let order: Int

        var id: String { "\(order)-\(label)-\(group)" }
    }

    /// The span the bars cover, and the calendar that decides where its
    /// boundaries fall — one value because they are only ever meaningful
    /// together, and a DST-correct cut depends on both.
    struct Window {
        let from: Date
        let to: Date
        var calendar: Calendar = .current
    }

    /// Blocks are clipped to the window and split at every bucket boundary
    /// through `CalendarSlices`, which is DST-correct — a 23- or 25-hour day
    /// keeps its real hours instead of dropping or double-counting one.
    static func buckets(
        _ activities: [LedgerBuilder.LabeledActivity], lens: TimeLens, span: TimeView.Span,
        groups: Set<String>, window: Window
    ) -> [Bucket] {
        let (from, to, calendar) = (window.from, window.to, window.calendar)
        let dayZero = calendar.startOfDay(for: from)
        // bucket label → (chronological order, group → ms)
        var sums: [String: (order: Int, byGroup: [String: Int64])] = [:]
        for activity in activities {
            let raw = lens.label(activity)
            let group = groups.contains(raw) ? raw : TimeBreakdown.otherLabel
            let start = Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000)
            let end = min(Date(timeIntervalSince1970: Double(activity.endedAt) / 1_000), to)
            CalendarSlices.walk(
                from: max(start, from), to: end,
                unit: span == .day ? .hour : .day, calendar: calendar
            ) { sliceStart, ms in
                let (label, order) = bucket(sliceStart, span: span,
                                            dayZero: dayZero, calendar: calendar)
                var entry = sums[label] ?? (order: order, byGroup: [:])
                entry.byGroup[group, default: 0] += ms
                sums[label] = entry
            }
        }
        return sums.flatMap { label, entry in
            entry.byGroup.map { group, ms in
                Bucket(label: label, group: group, hours: Double(ms) / 3_600_000,
                       order: entry.order)
            }
        }
        .sorted { $0.order < $1.order }
    }

    /// One slice's bucket: "00"…"23" for a day, the weekday's short name for a
    /// week. `order` is days from the window's first day, so the week's bars
    /// stay in calendar order rather than alphabetical.
    private static func bucket(
        _ date: Date, span: TimeView.Span, dayZero: Date, calendar: Calendar
    ) -> (label: String, order: Int) {
        switch span {
        case .day:
            let hour = calendar.component(.hour, from: date)
            return (String(format: "%02d", hour), hour)
        case .week:
            let days = calendar.dateComponents(
                [.day], from: dayZero, to: calendar.startOfDay(for: date)).day ?? 0
            return (date.formatted(.dateTime.weekday(.abbreviated)), days)
        }
    }
}

/// Chart colors for both Time-page modes, so a group wears the same color in
/// the timeline bars, the summary donut, and every legend. All hues come from
/// `Dojo.chartSlots`, validated for CVD separation and 3:1 contrast on both
/// surfaces (design.md §7). Work wears the robe's terracotta; the low-signal
/// categories (admin, private, unclassified) stay recessive grays.
enum TimePalette {
    /// Fixed category hues.
    private static let categoryColors: [String: Color] = [
        "work": Dojo.terracotta, "learning": Dojo.jade, "entertainment": Dojo.gold,
        "social": Dojo.magenta, "communication": Dojo.blue, "admin": .gray,
        "private": .secondary, "unclassified": Color.gray.opacity(0.4)
    ]

    /// Hue order for theme and task groups — the validated slot order, which is
    /// what makes adjacent assignments CVD-distinct. Deliberately a *fixed*
    /// list: a 9th group never gets a generated hue, it folds into "Other".
    static let groupHues: [Color] = Dojo.chartSlots

    /// The leftover bucket, and any category the ledger grew without a hue here.
    static let otherColor = Color.gray.opacity(0.5)

    /// Colors for one lens's groups, in ranked order.
    ///
    /// Category names have fixed colors. Theme and task names take a hue from a
    /// stable hash of the name — color follows the *group*, not its rank, so
    /// flipping Day↔Week or dropping a group doesn't repaint the survivors.
    /// Hash collisions fall forward to the first free hue so two groups on
    /// screen together never share one.
    static func colors(for names: [String], lens: TimeLens) -> [String: Color] {
        guard lens != .category else {
            return Dictionary(uniqueKeysWithValues: names.map {
                ($0, categoryColors[$0] ?? otherColor)
            })
        }
        var used: Set<Int> = []
        var result: [String: Color] = [TimeBreakdown.otherLabel: otherColor]
        for name in names where name != TimeBreakdown.otherLabel {
            var index = Int(stableHash(name) % UInt64(groupHues.count))
            var probes = 0
            while used.contains(index), probes < groupHues.count {
                index = (index + 1) % groupHues.count
                probes += 1
            }
            used.insert(index)
            result[name] = groupHues[index]
        }
        return result
    }

    /// FNV-1a. `hashValue` is seeded per process, which would repaint every
    /// theme on every launch.
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
