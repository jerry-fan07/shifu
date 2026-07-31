import ShifuCore
import SwiftUI

/// The Breakdown's Focus place (design.md §4.4): the Focus Mode sessions the
/// daemon has been logging all along, finally read back. The hero figure is
/// the window's focus score — the on-task share of the classified time inside
/// sessions, by `FocusReport`'s arithmetic — the band shows *when* the
/// sessions ran, gold over the day's tracked time receded to grey, and the
/// table gives each session its own score.
///
/// Gold on purpose: every other hue in the ledger's bands is a series, and a
/// focus session is not one — it is a contract laid *over* whatever was going
/// on. The warm slot is the one colour that reads against all of them.
struct FocusPage<Controls: View>: View {
    let blocks: [LedgerBuilder.LabeledActivity]
    /// The window's sessions as read, unscored — scoring against `blocks`
    /// happens here so the page recomputes when the store republishes them.
    let raw: [FocusModeSessions.Session]
    let window: (from: Date, to: Date)
    let isWeek: Bool
    @ViewBuilder var controls: Controls

    var body: some View {
        let sessions = FocusReport.sessions(
            raw, activities: blocks,
            from: Int64(window.from.timeIntervalSince1970 * 1_000),
            to: Int64(window.to.timeIntervalSince1970 * 1_000))
        VStack(spacing: 0) {
            head(sessions)
            if !sessions.isEmpty {
                Band {
                    if isWeek {
                        FocusWeekBand(sessions: sessions, blocks: blocks, window: window)
                    } else {
                        dayBand(sessions)
                    }
                }
            }
            PageBody {
                if sessions.isEmpty {
                    BlankSlate(
                        "No focus session \(isWeek ? "this week" : "today") yet. "
                            + "Flip Focus Mode on — the switch at the rail's foot — and "
                            + "the session it logs lands here, scored.")
                } else {
                    table(sessions)
                }
            }
        }
    }

    // MARK: - Head

    private func head(_ sessions: [FocusReport.Session]) -> some View {
        HeroHead(
            figure: Self.percent(FocusReport.score(sessions)),
            caption: isWeek ? "focus score this week" : "focus score today"
        ) {
            SummaryLine(parts: summaryParts(sessions))
        } trailing: {
            controls
        }
    }

    /// The facts under the score, most load-bearing first — SummaryLine drops
    /// them from the tail when the head runs out of room.
    private func summaryParts(_ sessions: [FocusReport.Session]) -> [(String, Color)] {
        guard !sessions.isEmpty else {
            return [("no sessions logged", Instrument.muted)]
        }
        let total = sessions.reduce(0) { $0 + $1.durationMs }
        var parts: [(String, Color)] = [(
            "\(TimeBreakdown.duration(total)) in "
                + "\(sessions.count) session\(sessions.count == 1 ? "" : "s")",
            Instrument.muted)]
        if sessions.contains(where: \.isLive) {
            parts.append(("in focus now", Instrument.live))
        }
        if sessions.count > 1, let longest = sessions.map(\.durationMs).max() {
            parts.append(("longest \(TimeBreakdown.duration(longest))", Instrument.muted))
        }
        let offTask = sessions.reduce(0) { $0 + $1.offTaskMs }
        if offTask > 0 {
            parts.append(("\(TimeBreakdown.duration(offTask)) off-task", Instrument.faint))
        }
        return parts
    }

    // MARK: - Band

    /// Midnight to midnight, on `Clock.day` like the Breakdown's own day rail
    /// — a session's place in the day is most of what this band says, and a
    /// rail cut to the hours that happened to hold sessions would move that
    /// place every time the day's shape changed.
    private func dayBand(_ sessions: [FocusReport.Session]) -> some View {
        let rail = LedgerShapes.Clock.day.on(window.from)
        return VStack(spacing: 0) {
            Ribbon(segments: LedgerShapes.focusRibbon(
                sessions: sessions, activities: blocks, from: rail.from, to: rail.to))
            RibbonAxis(ticks: LedgerShapes.ticks(.day))
        }
    }

    // MARK: - Table

    private func table(_ sessions: [FocusReport.Session]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHead {
                Text("Session").frame(maxWidth: .infinity, alignment: .leading)
                Text("Time").frame(width: 76, alignment: .trailing)
                Text("Score").frame(width: 54, alignment: .trailing)
                Text("On-task").frame(width: 148, alignment: .leading)
            }
            ForEach(sessions.sorted { $0.startedAt > $1.startedAt }) { session in
                row(session)
                Rule()
            }
        }
    }

    private func row(_ session: FocusReport.Session) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                if session.isLive { StatusDot(color: Instrument.live, size: 6) }
                Figure(label(session))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Figure(TimeBreakdown.duration(session.durationMs), color: Instrument.ink)
                .frame(width: 76, alignment: .trailing)
            Figure(Self.percent(session.score), color: Instrument.muted)
                .frame(width: 54, alignment: .trailing)
            Group {
                if let score = session.score {
                    // The meter wears the verdict — the accent at full marks,
                    // fading as the score falls. The meter only: the ramp's
                    // low end is too pale to print the percent in.
                    Meter(share: score, color: Instrument.verdict(score))
                } else {
                    // The session ran, but nothing inside it was classified
                    // either way — an honest blank, not a zero.
                    Text("nothing classified")
                        .font(Instrument.sans(11))
                        .foregroundStyle(Instrument.ghost)
                }
            }
            .frame(width: 148, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    /// "10:05 – 11:40 AM", with the weekday in front when the table spans one.
    private func label(_ session: FocusReport.Session) -> String {
        let span = LedgerShapes.span(session)
        guard isWeek else { return span }
        let day = Date(timeIntervalSince1970: Double(session.startedAt) / 1_000)
        return day.formatted(.dateTime.weekday(.abbreviated)) + " " + span
    }

    /// "86%", or the dash that says there is nothing to read.
    private static func percent(_ score: Double?) -> String {
        score.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

/// The week's sessions, one rail per elapsed day on a shared clock — the same
/// frame as the Breakdown's week band, minus the rhythm layer, which belongs
/// to the categories it was fitted on.
private struct FocusWeekBand: View {
    let sessions: [FocusReport.Session]
    let blocks: [LedgerBuilder.LabeledActivity]
    let window: (from: Date, to: Date)

    /// The weekday gutter and its air, matching `WeekRails` so flipping the
    /// picker between Focus and a lens doesn't shift the rails sideways.
    private static let gutter: CGFloat = 34
    private static let air: CGFloat = 8

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let clock = LedgerShapes.clock(
            blocks, plus: sessions.map { ($0.startedAt, $0.endedAt) },
            from: window.from, to: window.to)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<7, id: \.self) { offset in
                if let day = calendar.date(byAdding: .day, value: offset, to: window.from),
                   day <= today {
                    let rail = clock.on(day)
                    HStack(spacing: Self.air) {
                        Figure(
                            day.formatted(.dateTime.weekday(.abbreviated)), size: 10.5,
                            color: day == today ? Instrument.ink : Instrument.faint)
                            .frame(width: Self.gutter, alignment: .leading)
                        Ribbon(
                            segments: LedgerShapes.focusRibbon(
                                sessions: sessions, activities: blocks,
                                from: rail.from, to: rail.to),
                            height: 15, corner: 3)
                    }
                }
            }
            RibbonAxis(ticks: LedgerShapes.ticks(clock), leading: Self.gutter + Self.air)
        }
    }
}
