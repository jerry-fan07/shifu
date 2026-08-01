import ShifuCore
import SwiftUI

/// The theme page's opening figure (design.md §5.3): thirty days of the
/// theme's blocks, stacked by hour of day — the shape of a campaign rather
/// than a list of its days. Everything here derives from block rows on read;
/// there is no parallel table to drift from the ledger.
struct ThemeCampaign {
    /// One block fragment in the grid, clipped to a single day column.
    /// `task` is the row's rank in `tasks`; nil is time filed under no task.
    struct Block {
        let day: Int
        let startFraction: Double
        let endFraction: Double
        let task: Int?
    }

    struct Day {
        let tick: String        // "24"
        let active: Bool
    }

    /// One calendar week's run of columns, for the header row above the grid.
    struct Week: Identifiable {
        let firstColumn: Int
        let label: String       // "Jul 21"
        let hours: String       // "18h"

        var id: Int { firstColumn }
    }

    /// A task's row under the chart. `id` is its rank, which is also its
    /// colour: `Instrument.slots[id % count]`, biggest share first.
    struct TaskRow: Identifiable {
        let id: Int
        let name: String
        let taskID: Int64?
        let time: String
        let share: String
    }

    struct SourceRow: Identifiable {
        let name: String
        let time: String
        let fraction: Double    // of the longest bar

        var id: String { name }
    }

    /// The window, in day columns.
    static let span = 30
    /// How many tasks get a row (and with it a colour). Real themes run to
    /// dozens of sub-minute tasks; past this the rows are all "1m · 0%".
    static let roster = 12
    /// A silence this short joins two fragments of the same task: a real
    /// session is ~200 blocks of 20–60 s, and drawn one by one they are a
    /// barcode, not a band.
    private static let joinMs: Int64 = 5 * 60_000
    /// Runs shorter than this are dropped from the drawing — at 240 pt a
    /// minute is a sixth of a point, and the 2 pt floor turns it into speck
    /// noise. The totals and rows still count every second.
    private static let floorMs: Int64 = 2 * 60_000

    let days: [Day]
    let blocks: [Block]
    let weeks: [Week]
    let tasks: [TaskRow]
    /// One reading of the campaign, shown big: "16 of 30" over "days active".
    struct Stat: Identifiable {
        let value: String
        let caption: String

        var id: String { caption }
    }

    /// "…and 25 more tasks · 1h 04m" — nil when the roster holds everything.
    let moreTasks: String?
    /// The tail itself, named and timed — folded away behind `moreTasks`
    /// until the rail's "show" reveals it. None of these have a chart
    /// colour: the roster is the chart's whole legend, and the tail's
    /// blocks already draw in `Instrument.other`.
    let tailTasks: [TaskRow]
    let sources: [SourceRow]
    /// The window itself — "Jul 3 – Aug 1" — over the stats band.
    let range: String
    /// Days active, longest run, peak day: the campaign's vital signs.
    let stats: [Stat]

    static func build(
        blocks activities: [LedgerBuilder.LabeledActivity],
        related: [ThemeStore.RelatedTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ThemeCampaign {
        let todayStart = calendar.startOfDay(for: now)
        // Day boundaries, not a fixed 86 400 s: fractions must be of the
        // civil day the column draws, or every block after a DST change
        // sits a step off its hour.
        let starts: [Date] = (0...span).map {
            calendar.date(byAdding: .day, value: $0 - span + 1, to: todayStart)
                ?? todayStart
        }
        let bounds = starts.map { Int64($0.timeIntervalSince1970 * 1_000) }
        let fold = fold(activities, into: bounds)

        let total = max(fold.dayTotals.reduce(0, +), 1)
        let order = fold.taskMs.sorted { $0.value > $1.value }
        // Only the roster's tasks keep a rank; the tail's blocks draw in the
        // non-group grey, because a colour claims a row that isn't there.
        let rank = Dictionary(
            uniqueKeysWithValues: order.prefix(roster).enumerated()
                .map { ($0.element.key, $0.offset) })
        let topSource = fold.sourceMs.values.max() ?? 1
        let tail = order.dropFirst(roster)

        return ThemeCampaign(
            days: (0..<span).map { day in
                Day(tick: "\(calendar.component(.day, from: starts[day]))",
                    active: fold.dayTotals[day] > 0)
            },
            blocks: merge(fold.fragments).map { fragment in
                let length = Double(bounds[fragment.day + 1] - bounds[fragment.day])
                return Block(
                    day: fragment.day,
                    startFraction: Double(fragment.from - bounds[fragment.day]) / length,
                    endFraction: Double(fragment.to - bounds[fragment.day]) / length,
                    task: fragment.task.flatMap { rank[$0] })
            },
            weeks: weekRows(dayTotals: fold.dayTotals, starts: starts, calendar: calendar),
            tasks: order.prefix(roster).enumerated().map { offset, entry in
                taskRow(offset, entry, total: total, related: related)
            },
            moreTasks: tail.isEmpty ? nil
                : "…and \(tail.count) more task\(tail.count == 1 ? "" : "s") · "
                    + TimeBreakdown.duration(tail.reduce(0) { $0 + $1.value }),
            tailTasks: tail.enumerated().map { offset, entry in
                taskRow(roster + offset, entry, total: total, related: related)
            },
            sources: fold.sourceMs.sorted { $0.value > $1.value }.prefix(6).map {
                SourceRow(name: $0.key, time: TimeBreakdown.duration($0.value),
                          fraction: Double($0.value) / Double(topSource))
            },
            range: {
                let monthDay = Date.FormatStyle.dateTime.month(.abbreviated).day()
                return starts[0].formatted(monthDay) + " – "
                    + starts[span - 1].formatted(monthDay)
            }(),
            stats: stats(dayTotals: fold.dayTotals, starts: starts))
    }

    /// One ranked task's row, whether it lands on the roster or in the tail —
    /// `id` only carries a chart colour when it is under `roster`.
    private static func taskRow(
        _ id: Int, _ entry: (key: String, value: Int64),
        total: Int64, related: [ThemeStore.RelatedTask]
    ) -> TaskRow {
        TaskRow(
            id: id, name: entry.key,
            taskID: related.first { $0.name == entry.key }?.taskID,
            time: TimeBreakdown.duration(entry.value),
            share: "\(Int((Double(entry.value) / Double(total) * 100).rounded()))%")
    }

    /// Joins each task's near-adjacent fragments into session bands and drops
    /// what stays too short to draw. Shape only — every total above is taken
    /// before this runs.
    private static func merge(_ fragments: [Fragment]) -> [Fragment] {
        var out: [Fragment] = []
        let lanes = Dictionary(grouping: fragments) { "\($0.day)·\($0.task ?? "")" }
        for lane in lanes.values {
            var run: Fragment?
            for piece in lane.sorted(by: { $0.from < $1.from }) {
                if let open = run, piece.from - open.to <= joinMs {
                    run = Fragment(day: open.day, from: open.from,
                                   to: max(open.to, piece.to), task: open.task)
                } else {
                    if let open = run, open.to - open.from >= floorMs { out.append(open) }
                    run = piece
                }
            }
            if let open = run, open.to - open.from >= floorMs { out.append(open) }
        }
        return out.sorted { ($0.day, $0.from) < ($1.day, $1.from) }
    }

    private struct Fragment {
        let day: Int
        let from: Int64
        let to: Int64
        let task: String?
    }

    private struct Fold {
        var fragments: [Fragment] = []
        var dayTotals = [Int64](repeating: 0, count: span)
        var taskMs: [String: Int64] = [:]
        var sourceMs: [String: Int64] = [:]
    }

    /// Clips every activity to the window's day columns — a block crossing
    /// midnight becomes one fragment per day — and totals as it goes.
    private static func fold(
        _ activities: [LedgerBuilder.LabeledActivity], into bounds: [Int64]
    ) -> Fold {
        var fold = Fold()
        for activity in activities where activity.endedAt > bounds[0] {
            for day in 0..<span {
                let from = max(activity.startedAt, bounds[day])
                let to = min(activity.endedAt, bounds[day + 1])
                guard to > from else { continue }
                fold.fragments.append(
                    Fragment(day: day, from: from, to: to, task: activity.taskName))
                fold.dayTotals[day] += to - from
                if let task = activity.taskName {
                    fold.taskMs[task, default: 0] += to - from
                }
                fold.sourceMs[activity.source, default: 0] += to - from
            }
        }
        return fold
    }

    private static func weekRows(
        dayTotals: [Int64], starts: [Date], calendar: Calendar
    ) -> [Week] {
        var weeks: [Week] = []
        var weekMs: [Int64] = []
        for day in 0..<span {
            let weekStart = calendar.startOfWeek(for: starts[day])
            if weeks.isEmpty || weekStart != calendar.startOfWeek(for: starts[day - 1]) {
                weeks.append(Week(
                    firstColumn: day,
                    label: starts[day].formatted(.dateTime.month(.abbreviated).day()),
                    hours: ""))
                weekMs.append(0)
            }
            weekMs[weekMs.count - 1] += dayTotals[day]
        }
        return zip(weeks, weekMs).map {
            Week(firstColumn: $0.firstColumn, label: $0.label,
                 hours: "\(Int(($1 / 60_000 + 30) / 60))h")
        }
    }

    private static func stats(dayTotals: [Int64], starts: [Date]) -> [Stat] {
        var run = 0, best = 0, active = 0
        var peak = 0
        for day in 0..<span {
            run = dayTotals[day] > 0 ? run + 1 : 0
            best = max(best, run)
            if dayTotals[day] > 0 { active += 1 }
            if dayTotals[day] > dayTotals[peak] { peak = day }
        }
        let peakLabel = starts[peak]
            .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return [
            Stat(value: "\(active) of \(span)", caption: "days active"),
            Stat(value: "\(best) day\(best == 1 ? "" : "s")", caption: "longest run"),
            Stat(value: TimeBreakdown.duration(dayTotals[peak]),
                 caption: "peak · \(peakLabel)")
        ]
    }
}

// MARK: - The scroll-driven hero

/// The campaign as the page's opening act. It pins at full size while the
/// first stretch of scroll plays the reveal — the blocks wipe in left to
/// right, the axis fades up, the task rows rise one after another — then lets
/// go and scrolls off like anything else. Scroll position *is* the clock:
/// nothing here runs on a timer, so the reveal can be scrubbed, and Reduce
/// Motion simply pins the clock at "done".
struct CampaignHero: View {
    let campaign: ThemeCampaign
    let openTask: (Int64) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroHeight: CGFloat = 720
    /// The hovered task's rank — its blocks stay lit while the rest recede.
    @State private var litTask: Int?
    /// Whether the tail past the roster is unfolded below "…and N more".
    @State private var tasksExpanded = false

    /// The scroll space the reveal reads. Named on the page's scroll view.
    static let scrollSpace = "theme-campaign"
    /// How much scroll the pinned hero holds for — where the reveal ends.
    private static let runway: CGFloat = 700
    /// Where the last task row finishes rising.
    private static let revealEnd: CGFloat = 700
    /// The shot harness can't scroll, so it sets the reveal's clock by hand:
    /// `SHIFU_SHOT_TRAVEL` scrubs to a frame, and a plain `SHIFU_SHOTS` run
    /// films the reveal finished — the standing film should show the page,
    /// not the shrunken opening frame every capture would otherwise catch.
    private static let shotTravel: CGFloat? = {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["SHIFU_SHOT_TRAVEL"], let value = Double(raw) {
            return CGFloat(value)
        }
        return environment["SHIFU_SHOTS"] == nil ? nil : revealEnd
    }()

    var body: some View {
        let pinned = Self.shotTravel == nil && !reduceMotion
        let runway: CGFloat = pinned ? Self.runway : 0
        GeometryReader { proxy in
            let travel = Self.shotTravel
                ?? (reduceMotion
                    ? Self.revealEnd
                    : max(0, -proxy.frame(in: .named(Self.scrollSpace)).minY))
            hero(travel: travel)
                .offset(y: min(travel, runway))
        }
        .frame(height: heroHeight + runway)
        // The rail's "Tasks" target: the layout spot whose scroll position
        // leaves the reveal finished and the rows on screen. The rows live
        // inside the pinned hero, so their own frames are useless to
        // `scrollTo` — it reads layout, and the pin is an offset.
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: max(runway - 1, 0))
                Color.clear.frame(height: 1)
                    .sectionAnchor(ThemeSection.tasks.rawValue)
            }
        }
    }

    private func hero(travel: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The campaign")
                .font(Instrument.sans(30, .semibold))
                .tracking(-0.6)
                .foregroundStyle(Instrument.ink)
            Text("Thirty days of blocks, stacked by hour of day — and the "
                + "threads they belong to.")
                .font(Instrument.sans(13.5))
                .foregroundStyle(Instrument.secondary)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.top, 6)
            CampaignChart(
                campaign: campaign,
                wipe: ramp(travel, from: 60, to: 450),
                fade: ramp(travel, from: 40, to: 300),
                litTask: litTask)
                .padding(.top, 20)
            taskRows(travel: travel)
                .padding(.top, 26)
                .padding(.leading, CampaignChart.axisWidth)
        }
        .padding(.top, 26)
        .background(
            GeometryReader { inner in
                Color.clear
                    .onAppear { heroHeight = inner.size.height }
                    .onChange(of: inner.size.height) { _, new in
                        if abs(new - heroHeight) > 0.5 { heroHeight = new }
                    }
            })
    }

    private func taskRows(travel: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Tasks in this theme")
                .padding(.bottom, 5)
                .opacity(ramp(travel, from: 40, to: 300))
            ForEach(campaign.tasks) { row in
                // Stagger caps at eight steps so a long roster's tail doesn't
                // need scroll the runway never grants.
                let step = CGFloat(min(row.id, 8)) * 30
                let reveal = ramp(travel, from: 320 + step, to: 450 + step)
                taskRow(row)
                    .opacity(reveal)
                    .offset(y: 10 * (1 - reveal))
            }
            if let more = campaign.moreTasks {
                HStack(spacing: 8) {
                    Text(more)
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.ghost)
                    InlineLink(tasksExpanded ? "hide" : "show", size: 11.5) {
                        tasksExpanded.toggle()
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rule() }
                .opacity(ramp(travel, from: 590, to: 700))
                if tasksExpanded {
                    ForEach(campaign.tailTasks) { row in
                        taskRow(row)
                    }
                }
            }
        }
    }

    private func taskRow(_ row: ThemeCampaign.TaskRow) -> some View {
        let lit = litTask == nil || litTask == row.id
        let onChart = row.id < ThemeCampaign.roster
        return Button {
            if let taskID = row.taskID { openTask(taskID) }
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(onChart && lit ? Instrument.slots[row.id % Instrument.slots.count]
                                         : Instrument.quiet)
                    .frame(width: 7, height: 7)
                Text(row.name)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(lit ? Instrument.ink : Instrument.ghost)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Figure(row.time, size: 12,
                       color: lit ? Instrument.muted : Instrument.ghost)
                Figure(row.share, size: 12, color: Instrument.ghost)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(litTask == row.id ? Instrument.rowTint : .clear)
        .overlay(alignment: .top) { Rule() }
        .onHover { inside in
            // The shot harness's real cursor lands on whatever row happens to
            // be under it, which photographs as a phantom selection.
            guard Self.shotTravel == nil else { return }
            litTask = inside ? row.id : nil
        }
    }

    private func ramp(_ travel: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        min(1, max(0, (travel - from) / (to - from)))
    }
}

// MARK: - The chart

/// The campaign grid itself: one column per day, midnight at the top, each
/// block a bar at its hour wearing its task's slot colour. `wipe` clips the
/// data in from the left and `fade` raises the furniture — both are scroll
/// progress handed down by the hero, already 1 when motion is off.
struct CampaignChart: View {
    let campaign: ThemeCampaign
    let wipe: CGFloat
    let fade: CGFloat
    let litTask: Int?

    static let axisWidth: CGFloat = 30
    private static let gap: CGFloat = 3
    private static let plotHeight: CGFloat = 240
    private static let hours = [0, 6, 12, 18, 24]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            weekHeader
                .mask(alignment: .leading) { wipeMask }
            HStack(alignment: .top, spacing: 0) {
                axis
                    .frame(width: Self.axisWidth)
                    .opacity(fade)
                plot
            }
            .frame(height: Self.plotHeight)
            ticks
                .padding(.top, 5)
                .mask(alignment: .leading) { wipeMask }
        }
    }

    /// One label per calendar week, seated over its first column behind a
    /// hairline — the only horizontal scale the columns get.
    private var weekHeader: some View {
        GeometryReader { proxy in
            let step = (proxy.size.width - Self.axisWidth + Self.gap)
                / CGFloat(ThemeCampaign.span)
            ForEach(campaign.weeks) { week in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Figure(week.label, size: 10.5, color: Instrument.muted)
                    Figure(week.hours, size: 10.5, color: Instrument.ghost)
                }
                .padding(.leading, 6)
                .padding(.bottom, 5)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Instrument.edge).frame(width: 1)
                }
                .offset(x: Self.axisWidth + CGFloat(week.firstColumn) * step)
            }
        }
        .frame(height: 21)
    }

    private var axis: some View {
        GeometryReader { proxy in
            ForEach(Self.hours, id: \.self) { hour in
                Figure(String(format: "%02d", hour), size: 9.5, color: Instrument.ghost)
                    .position(
                        x: proxy.size.width - 12,
                        y: min(max(proxy.size.height * CGFloat(hour) / 24, 5),
                               proxy.size.height - 5))
            }
        }
    }

    private var plot: some View {
        ZStack {
            GeometryReader { proxy in
                ForEach(Self.hours, id: \.self) { hour in
                    Rectangle()
                        .fill(hour % 24 == 0 ? Instrument.rule : Instrument.hairline)
                        .frame(height: 1)
                        .offset(y: min(proxy.size.height * CGFloat(hour) / 24,
                                       proxy.size.height - 1))
                }
            }
            .opacity(fade)
            blocks
                .mask(alignment: .leading) { wipeMask }
        }
    }

    private var blocks: some View {
        Canvas { context, size in
            let step = (size.width + Self.gap) / CGFloat(ThemeCampaign.span)
            for block in campaign.blocks {
                let lit = litTask == nil || litTask == block.task
                let colour: Color = switch (block.task, lit) {
                case (let task?, true): Instrument.slots[task % Instrument.slots.count]
                case (nil, true): Instrument.other
                case (_, false): Instrument.quiet
                }
                let top = size.height * block.startFraction
                let rect = CGRect(
                    x: CGFloat(block.day) * step,
                    y: top,
                    width: step - Self.gap,
                    height: max(size.height * block.endFraction - top, 2))
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1), with: .color(colour))
            }
        }
    }

    private var ticks: some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(campaign.days.enumerated()), id: \.offset) { _, day in
                Figure(day.tick, size: 9,
                       color: day.active ? Instrument.muted : Instrument.other)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, Self.axisWidth)
    }

    private var wipeMask: some View {
        GeometryReader { proxy in
            Rectangle().frame(width: proxy.size.width * wipe)
        }
    }
}
