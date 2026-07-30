import ShifuCore
import SwiftUI

/// The Ledger's three places (design.md §7). All three read the same blocks
/// through the same lens; they differ only in what they draw over them.
///
/// - *Breakdown* — where the time went: the day as one ribbon, then a ranked
///   table with a meter per row.
/// - *Timeline* — when it happened: the same ribbon, then every block in order.
/// - *Week* — the same table over seven days, with one ribbon per day.
///
/// There is no bar chart anywhere. A bar chart answers "how much at 10 AM";
/// the ribbon answers "what was the morning", which is the question a day
/// actually raises.
struct LedgerView: View {
    enum Mode { case breakdown, timeline, week }

    let mode: Mode

    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    /// Kept across places and launches: the lens is how you read your ledger,
    /// not a per-screen preference.
    @AppStorage("shifu.ledger.lens") private var lensRaw = TimeLens.category.rawValue
    /// Which group's apps are showing. Hover reveals them inline rather than
    /// opening a row, so scanning the table never costs a click.
    @State private var hovered: String?
    /// The week's blocks, read once on appear — the day's come from the store.
    @State private var weekBlocks: [LedgerBuilder.LabeledActivity] = []

    /// Theme and task lenses fold everything past the biggest few into
    /// "Other", so the table and the ribbon stay readable over a busy week.
    private static let maxGroups = 6

    private var lens: TimeLens {
        get { TimeLens(rawValue: lensRaw) ?? .category }
        nonmutating set { lensRaw = newValue.rawValue }
    }

    private var isWeek: Bool { mode == .week }

    var body: some View {
        let window = range
        let blocks = isWeek ? weekBlocks : store.todayActivities
        let slices = TimeBreakdown.slices(
            blocks, lens: lens, from: window.from, to: window.to,
            limit: lens == .category ? nil : Self.maxGroups)
        let colors = Dictionary(uniqueKeysWithValues: slices.map { ($0.name, $0.color) })

        VStack(spacing: 0) {
            head(blocks: blocks, window: window)
            if !blocks.isEmpty {
                Band {
                    if isWeek {
                        weekRibbons(colors: colors)
                    } else {
                        dayRibbon(blocks: blocks, colors: colors, window: window)
                    }
                }
            }
            table(blocks: blocks, slices: slices)
        }
        .onAppear(perform: load)
        .onChange(of: mode) { _, _ in load() }
    }

    private func load() {
        store.refresh()
        if isWeek { weekBlocks = store.activities(sinceWeeksAgo: 1) }
    }

    // MARK: - Head

    private func head(
        blocks: [LedgerBuilder.LabeledActivity], window: (from: Date, to: Date)
    ) -> some View {
        let total = TimeBreakdown.total(blocks, from: window.from, to: window.to)
        return HeroHead(
            figure: TimeBreakdown.duration(total),
            caption: isWeek ? "tracked this week" : "tracked today"
        ) {
            summaryLine(blocks: blocks, total: total)
        } trailing: {
            HStack(spacing: 6) {
                SegmentedBar(
                    options: [("Day", false), ("Week", true)],
                    selection: Binding(
                        get: { isWeek },
                        set: { router.go(to: $0 ? .week : dayPlace) }))
                SegmentedBar(
                    options: TimeLens.allCases.map { ($0.rawValue, $0) },
                    selection: Binding(get: { lens }, set: { lens = $0 }))
            }
        }
    }

    /// The line that turns a number into a fact: how it compares, how many
    /// pieces it came in, when the weight of it fell, and how much was never
    /// read.
    private func summaryLine(
        blocks: [LedgerBuilder.LabeledActivity], total: Int64
    ) -> some View {
        var parts: [String] = []
        if let delta = deltaText(total: total) { parts.append(delta) }
        parts.append("\(blocks.count) block\(blocks.count == 1 ? "" : "s")")
        if let peak = peakText(blocks) { parts.append(peak) }

        // Read from the blocks rather than the slices: private time is a
        // category, and under the theme or task lens it is scattered through
        // groups that are named something else entirely.
        let privateMs = blocks
            .filter { $0.category == "private" }
            .reduce(0) { $0 + $1.durationMs }
        return HStack(spacing: 0) {
            Text(parts.joined(separator: " · "))
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.muted)
            if privateMs > 0 {
                Text(" · \(TimeBreakdown.duration(privateMs)) private")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.faint)
            }
        }
    }

    // MARK: - Ribbons

    private func dayRibbon(
        blocks: [LedgerBuilder.LabeledActivity], colors: [String: Color],
        window: (from: Date, to: Date)
    ) -> some View {
        let clock = LedgerShapes.clock(blocks, from: window.from, to: window.to)
        let rail = clock.on(window.from)
        return VStack(spacing: 0) {
            Ribbon(segments: LedgerShapes.ribbon(
                blocks, lens: lens, colors: colors, from: rail.from, to: rail.to))
            RibbonAxis(hours: LedgerShapes.ticks(clock))
        }
    }

    /// One rail per day, on a shared clock: the week's shape is the *shift* of
    /// the bands down the column, which separate day-charts never show.
    private func weekRibbons(colors: [String: Color]) -> some View {
        let calendar = Calendar.current
        let window = range
        let clock = LedgerShapes.clock(weekBlocks, from: window.from, to: window.to)
        let today = calendar.startOfDay(for: Date())

        return VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<7, id: \.self) { offset in
                if let day = calendar.date(byAdding: .day, value: offset, to: window.from),
                   day <= today {
                    let rail = clock.on(day)
                    HStack(spacing: 8) {
                        Figure(
                            day.formatted(.dateTime.weekday(.abbreviated)),
                            size: 10.5,
                            color: day == today ? Instrument.ink : Instrument.faint)
                            .frame(width: 34, alignment: .leading)
                        Ribbon(
                            segments: LedgerShapes.ribbon(
                                weekBlocks, lens: lens, colors: colors,
                                from: rail.from, to: rail.to),
                            height: 15, corner: 3)
                    }
                }
            }
            RibbonAxis(hours: LedgerShapes.ticks(clock), leading: 42)
        }
    }

    // MARK: - Table

    @ViewBuilder private func table(
        blocks: [LedgerBuilder.LabeledActivity], slices: [TimeSlice]
    ) -> some View {
        if blocks.isEmpty {
            PageBody {
                BlankSlate(
                    isWeek
                        ? "Nothing tracked this week yet. The analyzer folds new captures "
                            + "in hourly."
                        : "Nothing tracked today yet. The analyzer folds new captures in "
                            + "hourly — the ledger fills in behind it.")
            }
        } else if mode == .timeline {
            PageBody {
                ColumnHead {
                    Text("Time").frame(width: 66, alignment: .leading)
                    Text("Block").frame(maxWidth: .infinity, alignment: .leading)
                    Text("For").frame(width: 88, alignment: .trailing)
                    Text("Category").frame(width: 92, alignment: .trailing)
                }
                ForEach(blocks.sorted { $0.startedAt > $1.startedAt }, id: \.id) { block in
                    BlockRow(block: block, lens: lens)
                    Rule()
                }
            }
        } else {
            PageBody {
                ColumnHead {
                    Text(lens.rawValue).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Time").frame(width: 76, alignment: .trailing)
                    Text("Share").frame(width: 54, alignment: .trailing)
                    Text("Where").frame(width: 148, alignment: .leading)
                }
                ForEach(slices) { slice in
                    groupRow(slice)
                }
                if !isWeek { latestBlocks(blocks) }
            }
        }
    }

    private func groupRow(_ slice: TimeSlice) -> some View {
        let isPrivate = slice.name == "private"
        let isOpen = hovered == slice.id && !slice.sources.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 9) {
                    SeriesSwatch(color: slice.color, hatched: isPrivate)
                    Text(lens.display(slice.name))
                        .font(Instrument.sans(13, isOpen ? .medium : .regular))
                        .foregroundStyle(isPrivate ? Instrument.muted : Instrument.ink)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Figure(
                    TimeBreakdown.duration(slice.ms),
                    color: isPrivate ? Instrument.muted : Instrument.ink)
                    .frame(width: 76, alignment: .trailing)
                Figure(percent(slice.share), color: isPrivate ? Instrument.ghost : Instrument.muted)
                    .frame(width: 54, alignment: .trailing)
                Group {
                    if isPrivate {
                        Text("never read")
                            .font(Instrument.sans(11))
                            .foregroundStyle(Instrument.ghost)
                    } else {
                        Meter(share: slice.share, color: slice.color)
                    }
                }
                .frame(width: 148, alignment: .leading)
            }
            .padding(.vertical, 7)
            if isOpen { sources(slice) }
            Rule()
        }
        .background(isOpen ? Instrument.rowTint : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside ? slice.id : (hovered == slice.id ? nil : hovered)
        }
    }

    /// What the group was actually made of. Inline on hover — the drill-down a
    /// legend could never give, at no cost to the scan.
    private func sources(_ slice: TimeSlice) -> some View {
        HStack(spacing: 18) {
            ForEach(slice.sources) { source in
                Figure(
                    "\(source.name) \(TimeBreakdown.duration(source.ms))",
                    size: 11, color: Instrument.faint)
            }
            if slice.sourceCount > slice.sources.count {
                Figure(
                    "+\(slice.sourceCount - slice.sources.count) more",
                    size: 11, color: Instrument.ghost)
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 9)
    }

    /// The tail of the day under the table — enough to recognise where you
    /// just were, with the whole log one word away.
    private func latestBlocks(_ blocks: [LedgerBuilder.LabeledActivity]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Latest blocks")
                Spacer()
                InlineLink("All \(blocks.count)") { router.go(to: .timeline) }
            }
            .padding(.top, 14)
            .padding(.bottom, 8)
            ForEach(blocks.sorted { $0.startedAt > $1.startedAt }.prefix(3), id: \.id) { block in
                Rule()
                BlockRow(block: block, lens: lens)
            }
        }
    }

    // MARK: - Window and figures

    private var dayPlace: Place { mode == .timeline ? .timeline : .breakdown }

    private var range: (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        return isWeek
            ? (calendar.startOfWeek(for: now), now)
            : (calendar.startOfDay(for: now), now)
    }

    /// "18% more than yesterday". Nil when there is nothing to compare with,
    /// or the change is noise.
    private func deltaText(total: Int64) -> String? {
        let window = range
        let calendar = Calendar.current
        let shift = isWeek ? -7 : -1
        guard total > 0,
              let previousFrom = calendar.date(byAdding: .day, value: shift, to: window.from),
              let previousTo = calendar.date(byAdding: .day, value: shift, to: window.to)
        else { return nil }
        let previous = TimeBreakdown.total(
            store.labeledActivities(from: previousFrom, to: previousTo),
            from: previousFrom, to: previousTo)
        guard previous > 0 else { return nil }
        let change = Double(total - previous) / Double(previous)
        guard abs(change) >= 0.01 else { return nil }
        return "\(Int((abs(change) * 100).rounded()))% \(change > 0 ? "more" : "less") "
            + "than \(isWeek ? "last week" : "yesterday")"
    }

    /// "busiest around 10 AM" for a day, "busiest Wednesday" for a week.
    private func peakText(_ blocks: [LedgerBuilder.LabeledActivity]) -> String? {
        let calendar = Calendar.current
        var totals: [Int: Int64] = [:]
        for block in blocks {
            let start = Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
            let key = calendar.component(isWeek ? .weekday : .hour, from: start)
            totals[key, default: 0] += block.endedAt - block.startedAt
        }
        guard let peak = totals.max(by: { $0.value < $1.value })?.key else { return nil }
        if isWeek {
            let symbols = calendar.standaloneWeekdaySymbols
            return "busiest \(symbols[(peak - 1 + symbols.count) % symbols.count])"
        }
        return "busiest around \(TimeBreakdown.hourLabel(peak))"
    }

    private func percent(_ share: Double) -> String {
        share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }
}

/// One raw block, in the Timeline's and the Breakdown's shared row shape:
/// when it started, what it was, how long, and which group it belongs to.
private struct BlockRow: View {
    let block: LedgerBuilder.LabeledActivity
    let lens: TimeLens

    var body: some View {
        HStack(spacing: 12) {
            Figure(
                Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
                    .formatted(.dateTime.hour().minute()),
                color: Instrument.faint)
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)
            Text(title)
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure(TimeBreakdown.duration(block.endedAt - block.startedAt),
                   color: Instrument.muted)
                .frame(width: 88, alignment: .trailing)
            Text(trailing)
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.muted)
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    /// The source is always named — it is the only part of a block the user
    /// saw with their own eyes — with whatever the lens adds after a dash.
    private var title: String {
        let detail = lens == .category ? block.taskName : lens.label(block)
        guard let detail, !detail.isEmpty else { return block.source }
        return "\(block.source) — \(detail)"
    }

    private var trailing: String { block.category }
}
