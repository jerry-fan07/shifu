import ShifuCore
import SwiftUI

/// What the Ledger breaks time down by (design.md §7, §5.3). Breakdown,
/// Timeline, and Week all read the same lens, so changing place never changes
/// what a group means — only how much of it you are looking at.
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

/// One group's share of a window: a row of the Breakdown table, a colour in
/// the ribbon. Built by `TimeBreakdown.slices`.
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
    /// The biggest few, for the row's inline reveal.
    let sources: [Source]
    /// How many there were in total — what "+4 more" counts.
    let sourceCount: Int

    var id: String { name }
}

/// Turns labeled activity blocks into ranked `TimeSlice`s.
enum TimeBreakdown {
    /// Where everything past the lens's group limit lands.
    static let otherLabel = "Other"
    /// How many groups a theme or task lens ranks before folding the rest into
    /// `otherLabel`, so the table and the ribbon stay readable over a busy
    /// week. Lives here rather than on the view that passes it, because it is
    /// half of an invariant whose other half is `TimePalette.groupHues`: a
    /// limit larger than the palette hands out means two groups on one chart
    /// wearing one colour, and that has to be checkable.
    static let maxGroups = 6
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
                    .map { TimeSlice.Source(name: $0.key, ms: $0.value) },
                sourceCount: entry.sources.count)
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
    ///
    /// Sub-minute blocks print in seconds. Rounding them to "0m" is what a
    /// block list of a real day looks like — the sessionizer emits plenty of
    /// forty-second visits, and a column of zeroes says nothing about any of
    /// them.
    static func duration(_ ms: Int64) -> String {
        let seconds = max(0, ms / 1_000)
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "2 PM" in the user's locale.
    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

/// Chart colors for every Ledger view, so a group wears the same color in the
/// ribbon, the table's meter, and the week's rows. All hues come from
/// `Instrument.slots` — the accent stepped, one neutral, one warm, two greens —
/// and nowhere else: the scale is short on purpose (design.md §7).
///
/// Hue is never the only cue here: every series is named in the row beside its
/// swatch, and the ribbon carries its group in the tooltip. That is what buys
/// the right to a scale this narrow.
enum TimePalette {
    /// Fixed category hues, ranked the way the ledger ranks the categories:
    /// work takes the strongest step, the low-signal ones (admin, private,
    /// unclassified) stay recessive.
    ///
    /// `unclassified` wears `other` and not `quiet`, which is where it started:
    /// `quiet` is a hair off a receded band in dark, so hovering "unclassified"
    /// in the Timeline's legend lit a set of bands that rendered #3D3D3C
    /// against neighbours rendering #3D3D3C — the one series the highlight
    /// couldn't point at. Nothing collides: `other` is the leftover bucket's
    /// grey, and this scale is closed, so it never draws one.
    private static let categoryColors: [String: Color] = [
        "work": Instrument.strong, "communication": Instrument.mid,
        "learning": Instrument.soft, "social": Instrument.deep,
        "entertainment": Instrument.warm, "admin": Instrument.neutral,
        "private": Instrument.quiet, "unclassified": Instrument.other
    ]

    /// Hue order for theme and task groups. Still a *short* fixed list — an
    /// eighth group takes a slot again rather than minting a hue, and anything
    /// past the lens's limit folds into "Other" — but no longer shorter than
    /// the limit it serves: at five slots against a `TimeBreakdown.maxGroups`
    /// of six, the sixth group had nowhere to go and always duplicated one of
    /// the five. Seven slots is what makes "two groups on screen together never
    /// share one" true rather than aspirational.
    static let groupHues: [Color] = Instrument.slots

    /// The leftover bucket, and any category the ledger grew without a hue here.
    static let otherColor = Instrument.other

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
