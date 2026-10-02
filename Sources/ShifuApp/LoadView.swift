import ShifuCore
import SwiftUI

/// The Ledger's *Load* place (design.md §4.6): the week's focused hours
/// across every front at once, and whether that is holding. The hero is this
/// week's capacity, the band is eight rolling weeks of it over the tracked
/// time behind it, and under the verdict come the two lists the page exists
/// for — what to give time, and what has gone quiet — before the table of
/// every front with its own eight weeks.
///
/// Reads once on appear and once per lens change, never on the store's
/// refresh: eight weeks of blocks is the one query on this page too big to
/// ride along with the menu bar.
struct LoadView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    @State private var unit: Workload.Unit = .task
    @State private var reading: Workload.Reading?
    @State private var readAt: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            head
            if let reading, !reading.fronts.isEmpty || reading.tracked.contains(where: { $0 > 0 }) {
                Band { LoadWeeksBand(reading: reading) }
            }
            PageBody {
                if let reading {
                    verdict(reading)
                    if !reading.giveTime.isEmpty {
                        list("Give time", fronts: reading.giveTime, reason: WorkloadCopy.reason)
                    }
                    if !reading.quiet.isEmpty {
                        list("Quiet — finished, or dropped?", fronts: reading.quiet) {
                            WorkloadCopy.quietReason($0, now: readAt)
                        }
                    }
                    if reading.fronts.isEmpty {
                        BlankSlate(
                            "No fronts yet. A front is a \(unit == .task ? "task" : "theme") whose "
                                + "time is mostly work or learning, with an hour or more in the "
                                + "last four weeks — the first week of days fills this in.")
                    } else {
                        table(reading)
                    }
                    unattached(reading)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: unit) { _, _ in load() }
    }

    private func load() {
        readAt = Int64(Date().timeIntervalSince1970 * 1_000)
        reading = store.workload(unit: unit, now: readAt)
    }

    // MARK: - Head

    private var head: some View {
        HeroHead(
            figure: WorkloadCopy.hours(reading?.capacity[0] ?? 0),
            caption: "focused this week"
        ) {
            SummaryLine(parts: summaryParts)
        } trailing: {
            FilterMenu(
                prefix: "By", options: [("task", Workload.Unit.task), ("theme", .theme)],
                selection: $unit)
        }
    }

    /// The figures the verdict was read from, most load-bearing first —
    /// `SummaryLine` drops from the tail when the head runs out of room.
    private var summaryParts: [(String, Color)] {
        guard let reading else { return [("reading the ledger…", Instrument.muted)] }
        var parts: [(String, Color)] = [
            (WorkloadCopy.title(reading.verdict), Self.tone(reading.verdict))
        ]
        parts.append(("on \(reading.activeFronts) front\(reading.activeFronts == 1 ? "" : "s")",
                      Instrument.muted))
        if let baseline = reading.baselineMs {
            parts.append(("baseline \(WorkloadCopy.hours(baseline))/wk", Instrument.muted))
        }
        if reading.effectiveFronts > 0 {
            parts.append((String(format: "%.1f effective", reading.effectiveFronts), Instrument.muted))
        }
        if reading.demandMsPerWeek > 0 {
            parts.append(("deadlines need \(WorkloadCopy.hours(reading.demandMsPerWeek))/wk",
                          Instrument.alert))
        }
        parts.append(("\(WorkloadCopy.hours(reading.tracked[0])) tracked", Instrument.faint))
        return parts
    }

    /// The verdict's colour: the two that ask something of you in the alert
    /// hue, the one about promises in the overdue hue, holding in the live
    /// green, and the two that say nothing in the muted ink they deserve.
    static func tone(_ verdict: Workload.Verdict) -> Color {
        switch verdict {
        case .overCommitted: return Instrument.overdue
        case .spreadThin, .slack: return Instrument.alert
        case .holding: return Instrument.live
        case .away, .tooEarly: return Instrument.muted
        }
    }

    // MARK: - Verdict

    private func verdict(_ reading: Workload.Reading) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                StatusDot(color: Self.tone(reading.verdict))
                Text(WorkloadCopy.title(reading.verdict))
                    .font(Instrument.sans(15, .semibold))
                    .foregroundStyle(Instrument.ink)
            }
            Text(WorkloadCopy.line(reading))
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: - The two lists

    private func list(
        _ title: String, fronts: [Workload.Front], reason: @escaping (Workload.Front) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("\(title) · \(fronts.count)")
                .padding(.top, 18)
                .padding(.bottom, 8)
            ForEach(fronts) { front in
                Rule()
                Button {
                    open(front)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(front.name)
                            .font(Instrument.sans(13.5, .semibold))
                            .foregroundStyle(Instrument.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(reason(front))
                            .font(Instrument.sans(12))
                            .foregroundStyle(Instrument.muted)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Table

    private func table(_ reading: Workload.Reading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Fronts by \(unit.rawValue) · \(reading.fronts.count)")
                .padding(.top, 22)
            ColumnHead {
                Text("Front").frame(maxWidth: .infinity, alignment: .leading)
                Text("This week").frame(width: 76, alignment: .trailing)
                Text("4-wk avg").frame(width: 76, alignment: .trailing)
                Text("\(Workload.weeks) weeks").frame(width: 108, alignment: .leading)
                Text("Status").frame(width: 64, alignment: .leading)
                Text("Deadline").frame(width: 190, alignment: .leading)
            }
            ForEach(reading.fronts) { front in
                row(front)
                Rule()
            }
        }
    }

    private func row(_ front: Workload.Front) -> some View {
        let dormant = front.status == .quiet
        return Button {
            open(front)
        } label: {
            HStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(front.name)
                        .font(Instrument.sans(13.5, .semibold))
                        .foregroundStyle(dormant ? Instrument.muted : Instrument.ink)
                        .lineLimit(1)
                        // The name is the row; the theme is a hint that gives
                        // way first when the column runs short.
                        .layoutPriority(1)
                    if let theme = front.themeName {
                        Eyebrow(theme, tracking: 0.6)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 150, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Figure(
                    front.thisWeekMs > 0 ? WorkloadCopy.hours(front.thisWeekMs) : "—",
                    color: front.thisWeekMs > 0 ? Instrument.ink : Instrument.ghost)
                    .frame(width: 76, alignment: .trailing)
                Figure(WorkloadCopy.hours(front.meanMs), color: Instrument.muted)
                    .frame(width: 76, alignment: .trailing)
                Sparkline(values: front.weekly.reversed().map(Double.init), dormant: dormant)
                    .frame(width: 108, alignment: .leading)
                Eyebrow(WorkloadCopy.status(front.status), color: Self.tone(front.status), tracking: 0.6)
                    .frame(width: 64, alignment: .leading)
                Group {
                    if let pace = front.pace {
                        Text(WorkloadCopy.pace(pace))
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(
                                pace.isBehind || pace.isOverdue ? Instrument.overdue : Instrument.muted)
                            .lineLimit(1)
                    } else {
                        Text("—")
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(Instrument.ghost)
                    }
                }
                .frame(width: 190, alignment: .leading)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func tone(_ status: Workload.Status) -> Color {
        switch status {
        case .slipping: return Instrument.alert
        case .rising: return Instrument.live
        case .new: return Instrument.accentText
        case .steady: return Instrument.muted
        case .quiet: return Instrument.ghost
        }
    }

    private func open(_ front: Workload.Front) {
        if let taskID = front.taskID {
            router.open(.task(taskID))
        } else if let themeID = front.themeID {
            router.open(.theme(themeID))
        }
    }

    // MARK: - Foot

    @ViewBuilder private func unattached(_ reading: Workload.Reading) -> some View {
        if !reading.unattached.isEmpty {
            let titles = reading.unattached.map(\.deadline.title).joined(separator: ", ")
            Text("Not paced — no task behind the deadline: \(titles)")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.ghost)
                .padding(.top, 14)
        }
    }
}

/// Eight rolling weeks, oldest left: focused hours as a column over the
/// tracked hours behind it, with the baseline ruled across. The gap between
/// the two heights is the week's unfocused time, and the band's whole point
/// is that the verdict can be read off that gap — slack is a short column
/// in a tall well; away is both short together.
struct LoadWeeksBand: View {
    let reading: Workload.Reading

    private static let height: CGFloat = 72
    private static let gutter: CGFloat = 44

    var body: some View {
        let weeks = (0..<Workload.weeks).reversed()
        let peak = max(1, reading.tracked.max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                Figure(scaleLabel(peak), size: 10.5, color: Instrument.faint)
                    .frame(width: Self.gutter, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(Array(weeks), id: \.self) { week in
                                column(week, peak: peak)
                            }
                        }
                        if let baseline = reading.baselineMs {
                            Rectangle()
                                .fill(Instrument.ink.opacity(0.35))
                                .frame(height: 1)
                                .offset(y: -Self.height * CGFloat(baseline) / CGFloat(peak))
                        }
                    }
                    .frame(width: proxy.size.width, height: Self.height, alignment: .bottom)
                }
                .frame(height: Self.height)
            }
            HStack(spacing: 8) {
                Spacer().frame(width: Self.gutter)
                HStack(spacing: 6) {
                    ForEach(Array(weeks), id: \.self) { week in
                        Figure(
                            week == 0 ? "this wk" : "-\(week)w", size: 10,
                            color: week == 0 ? Instrument.ink : Instrument.faint)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func column(_ week: Int, peak: Int64) -> some View {
        let tracked = CGFloat(reading.tracked[week]) / CGFloat(peak)
        let focused = CGFloat(reading.capacity[week]) / CGFloat(peak)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Instrument.well)
                .frame(height: max(2, Self.height * tracked))
            RoundedRectangle(cornerRadius: 3)
                .fill(week == 0 ? Instrument.strong : Instrument.mid)
                .frame(height: max(reading.capacity[week] > 0 ? 2 : 0, Self.height * focused))
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .help(
            "\(WorkloadCopy.hours(reading.capacity[week])) focused of "
                + "\(WorkloadCopy.hours(reading.tracked[week])) tracked")
    }

    /// The well's full height in hours, so the columns read as amounts.
    private func scaleLabel(_ peak: Int64) -> String {
        "\(peak / 3_600_000)h"
    }
}
