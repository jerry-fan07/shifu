import ShifuCore
import SwiftUI

/// The Ledger's two places (design.md §7). Both read the same blocks through
/// the same lens and the same Day / Week window; they differ in what they
/// draw over them.
///
/// - *Breakdown* — where the time went: the window as a ribbon (one rail a
///   day), then a ranked table with a meter per row.
/// - *Timeline* — when it happened, in detail: stacked bars over the hours or
///   days with each group's total under them, then every block in order. The
///   ribbon says "what was the morning"; the bars say "how much at 10 AM".
struct LedgerView: View {
    enum Mode { case breakdown, timeline }

    let mode: Mode

    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    /// Kept across places and launches: the lens is how you read your ledger,
    /// not a per-screen preference.
    @AppStorage("shifu.ledger.lens") private var lensRaw = TimeLens.category.rawValue
    /// The Day / Week window, persisted the same way — leaving for the
    /// Timeline shouldn't snap the ledger back to today.
    @AppStorage("shifu.ledger.week") private var isWeek = false
    /// The week's blocks, read once on appear — the day's come from the store.
    @State private var weekBlocks: [LedgerBuilder.LabeledActivity] = []
    /// Tracked ms in the window one day (or week) back, read once in `load()`
    /// with the blocks. The body must never open the database: it re-runs on
    /// every store publish, and it used to re-run per hover crossing — the
    /// read alone was ~4 ms of every one of those passes on a dogfood week.
    @State private var previousTotal: Int64 = 0
    /// What the week's nights are doing, fitted in `load()` beside the blocks
    /// they came from. Week only: a single day has no run to read.
    @State private var signals: [Rhythms.Signal] = []

    /// Theme and task lenses fold everything past the biggest few into
    /// "Other", so the table and the ribbon stay readable over a busy week.
    private static let maxGroups = 6

    private var lens: TimeLens {
        get { TimeLens(rawValue: lensRaw) ?? .category }
        nonmutating set { lensRaw = newValue.rawValue }
    }

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
                    if mode == .timeline {
                        TimelineChart(
                            blocks: blocks, slices: slices, colors: colors,
                            window: window, lens: lens, isWeek: isWeek)
                    } else if isWeek {
                        WeekBand(
                            blocks: weekBlocks, lens: lens, colors: colors,
                            window: window, signals: signals)
                    } else {
                        dayRibbon(blocks: blocks, colors: colors, window: window)
                    }
                }
            }
            table(blocks: blocks, slices: slices)
        }
        .onAppear(perform: load)
        .onChange(of: isWeek) { _, _ in load() }
    }

    private func load() {
        store.refresh()
        let window = range
        if isWeek {
            weekBlocks = store.activities(sinceWeeksAgo: 1)
            signals = Rhythms.signals(weekBlocks, from: window.from, to: window.to)
        } else {
            signals = []
        }
        let calendar = Calendar.current
        let shift = isWeek ? -7 : -1
        if let previousFrom = calendar.date(byAdding: .day, value: shift, to: window.from),
           let previousTo = calendar.date(byAdding: .day, value: shift, to: window.to) {
            previousTotal = TimeBreakdown.total(
                store.labeledActivities(from: previousFrom, to: previousTo),
                from: previousFrom, to: previousTo)
        }
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
                    selection: $isWeek)
                SegmentedBar(
                    options: TimeLens.allCases.map { ($0.rawValue, $0) },
                    selection: Binding(get: { lens }, set: { lens = $0 }))
            }
        }
    }

    /// The line that turns a number into a fact: how it compares, how many
    /// pieces it came in, when the weight of it fell, and how much was never
    /// read. Always one line: when the head runs out of room the trailing
    /// facts drop off whole, so a narrow window costs detail rather than
    /// wrapping the head taller and jolting everything under it when the
    /// window flips Day ↔ Week.
    private func summaryLine(
        blocks: [LedgerBuilder.LabeledActivity], total: Int64
    ) -> some View {
        var parts: [(text: String, color: Color)] = []
        if let delta = deltaText(total: total) { parts.append((delta, Instrument.muted)) }
        parts.append(
            ("\(blocks.count) block\(blocks.count == 1 ? "" : "s")", Instrument.muted))
        if let peak = peakText(blocks) { parts.append((peak, Instrument.muted)) }

        // Read from the blocks rather than the slices: private time is a
        // category, and under the theme or task lens it is scattered through
        // groups that are named something else entirely.
        let privateMs = blocks
            .filter { $0.category == "private" }
            .reduce(0) { $0 + $1.durationMs }
        if privateMs > 0 {
            parts.append(("\(TimeBreakdown.duration(privateMs)) private", Instrument.faint))
        }
        return SummaryLine(parts: parts)
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
            RibbonAxis(ticks: LedgerShapes.ticks(clock))
        }
    }

    // The week's rails, and the rhythm read off them, live in WeekRhythm.swift.

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
            let timeWidth: CGFloat = isWeek ? 100 : 66
            PageBody {
                ColumnHead {
                    Text("Time").frame(width: timeWidth, alignment: .leading)
                    Text("Block").frame(maxWidth: .infinity, alignment: .leading)
                    Text("For").frame(width: 88, alignment: .trailing)
                    Text("Category").frame(width: 92, alignment: .trailing)
                }
                // Lazy because a week of heartbeat-sized blocks is a
                // four-figure row count, and every row is the same height.
                LazyVStack(spacing: 0) {
                    ForEach(blocks.sorted { $0.startedAt > $1.startedAt }, id: \.id) { block in
                        BlockRow(block: block, lens: lens, dated: isWeek)
                        Rule()
                    }
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
                BreakdownTable(slices: slices, lens: lens)
                if !isWeek { latestBlocks(blocks) }
            }
        }
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

    private var range: (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        return isWeek
            ? (calendar.startOfWeek(for: now), now)
            : (calendar.startOfDay(for: now), now)
    }

    /// "18% more than yesterday". Nil when there is nothing to compare with,
    /// or the change is noise. Reads the `load()`-time `previousTotal` rather
    /// than the database — see that property for why.
    private func deltaText(total: Int64) -> String? {
        guard total > 0, previousTotal > 0 else { return nil }
        let change = Double(total - previousTotal) / Double(previousTotal)
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

}

/// The head's summary, cut to the room it has: the longest run of leading
/// `parts` whose joined line fits, so the facts at the end are the first to
/// go. The fit is *measured*, with the face's own NSFont, the way a drop-down
/// sizes its panel — not solved by `ViewThatFits`, whose trial layout of
/// every candidate re-ran on every commit of the page, whatever had changed,
/// and was most of a pinned core under a hover sweep of the table below.
private struct SummaryLine: View {
    let parts: [(text: String, color: Color)]

    @MainActor private static let font = Instrument.sansFont(12.5)
    @MainActor private static let lineHeight = ceil(
        font.ascender - font.descender + font.leading)

    var body: some View {
        GeometryReader { proxy in
            SummaryFacts(parts: parts.prefix(fitting(proxy.size.width)))
        }
        .frame(height: Self.lineHeight)
    }

    /// How many leading parts fit in `width`. Never less than one: a head
    /// too narrow for any fact still shows the first rather than none.
    private func fitting(_ width: CGFloat) -> Int {
        var count = parts.count
        while count > 1 {
            let line = parts.prefix(count).enumerated()
                .map { index, part in (index == 0 ? "" : " · ") + part.text }
                .joined()
            // A hair of slack: the HStack below measures each part alone,
            // and per-run rounding can land a point past one joined string.
            if line.size(withAttributes: [.font: Self.font]).width <= width - 4 { break }
            count -= 1
        }
        return count
    }
}

/// One row of the summary: the leading `parts`, dot-joined on a single line.
private struct SummaryFacts: View {
    let parts: ArraySlice<(text: String, color: Color)>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text((index == 0 ? "" : " · ") + part.text)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(part.color)
            }
        }
        .lineLimit(1)
    }
}

/// The Timeline's band: stacked bars over the day's hours — or the week's
/// days — with each group's total under them. The strip is a breakdown rather
/// than a color key: the block list below names no groups, so this is where
/// the chart's series are spelled out.
private struct TimelineChart: View {
    let blocks: [LedgerBuilder.LabeledActivity]
    let slices: [TimeSlice]
    let colors: [String: Color]
    let window: (from: Date, to: Date)
    let lens: TimeLens
    let isWeek: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StackedBars(
                stacks: LedgerShapes.bars(
                    blocks, lens: lens, colors: colors, order: slices.map(\.name),
                    slots: isWeek ? daySlots : hourSlots),
                endTick: isWeek ? nil : "24")
            legend
        }
    }

    /// One slot per hour, midnight to midnight. The grid is fixed rather than
    /// cut to the day's clock — where a column sits *is* where in the day you
    /// were, and an empty evening should look like an empty evening.
    private var hourSlots: [LedgerShapes.Slot] {
        let calendar = Calendar.current
        let ticked = Set(
            LedgerShapes.ticks(LedgerShapes.Clock(startHour: 0, endHour: 24)).map(\.hour))
        let midnight = calendar.startOfDay(for: window.from)
        return (0..<24).compactMap { hour in
            guard let from = calendar.date(byAdding: .hour, value: hour, to: midnight),
                  let to = calendar.date(byAdding: .hour, value: hour + 1, to: midnight)
            else { return nil }
            let label = String(format: "%02d", hour)
            return LedgerShapes.Slot(
                tick: ticked.contains(hour) ? label : "", from: from, to: to)
        }
    }

    /// One slot per day, all seven — a day that hasn't happened yet draws no
    /// column, so the week keeps its shape as it fills in.
    private var daySlots: [LedgerShapes.Slot] {
        let calendar = Calendar.current
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: window.from),
                  let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            return LedgerShapes.Slot(
                tick: day.formatted(.dateTime.weekday(.abbreviated)), from: day, to: next)
        }
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .leading)],
            alignment: .leading, spacing: 7
        ) {
            ForEach(slices) { slice in
                HStack(spacing: 7) {
                    SeriesSwatch(color: slice.color, hatched: slice.name == "private")
                    Text(lens.display(slice.name))
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.secondary)
                        .lineLimit(1)
                    Figure(
                        TimeBreakdown.duration(slice.ms),
                        size: 11, color: Instrument.faint)
                }
            }
        }
        .padding(.top, 12)
    }
}

/// One raw block, in the Timeline's and the Breakdown's shared row shape:
/// when it started, what it was, how long, and which group it belongs to.
private struct BlockRow: View {
    let block: LedgerBuilder.LabeledActivity
    let lens: TimeLens
    /// A week's list names the day; a day's doesn't have to.
    var dated = false

    var body: some View {
        HStack(spacing: 12) {
            Figure(
                Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
                    .formatted(dated
                        ? .dateTime.weekday(.abbreviated).hour().minute()
                        : .dateTime.hour().minute()),
                color: Instrument.faint)
                .lineLimit(1)
                .frame(width: dated ? 100 : 66, alignment: .leading)
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
