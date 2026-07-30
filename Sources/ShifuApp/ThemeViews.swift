import ShifuCore
import SwiftUI

/// The Vault's *Themes* place (design.md §5.3): the few long arcs the user's
/// work belongs to, as one table — total, this week, eight weeks of shape, and
/// how many tasks sit in each.
///
/// Every theme here is one the user made, by hand or by accepting a proposal.
/// The clusterer's proposals sit below the table and are never counted as
/// themes; nothing crosses that line on its own.
struct ThemesView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    @State private var sort: Sort = .week
    @State private var isCreating = false
    @State private var editing: ThemeStore.Overview?
    /// Eight weeks of blocks, read once on appear: the sparklines, the task
    /// counts, and the unfiled-time line all come out of this one query.
    @State private var blocks: [LedgerBuilder.LabeledActivity] = []

    enum Sort: String, CaseIterable, Hashable {
        case week = "this week"
        case total = "all time"
        case recent = "last touched"
    }

    /// How far back a sparkline reaches, and therefore what "Tasks" counts.
    static let weeks = 8
    /// A theme with nothing in it this long reads as dormant rather than slow.
    private static let quietDays = 7

    var body: some View {
        VStack(spacing: 0) {
            PageHead("Themes", subtitle: subtitle) {
                HStack(spacing: 6) {
                    FilterMenu(
                        prefix: "Sort", options: Sort.allCases.map { ($0.rawValue, $0) },
                        selection: $sort)
                    SolidButton(title: "New theme") { isCreating = true }
                }
            }
            PageBody {
                if store.themes.isEmpty {
                    BlankSlate(
                        "No themes yet. A theme is a broad initiative you want your hours "
                            + "grouped under — \"Q3 pricing\", \"Travel\". Name the ones you "
                            + "care about; I file time into them and suggest others I notice.")
                } else {
                    table
                }
                proposals
                unfiled
            }
        }
        .sheet(isPresented: $isCreating) { ThemeEditSheet(theme: nil) }
        .sheet(item: $editing) { ThemeEditSheet(theme: $0) }
        .onAppear {
            store.refresh()
            blocks = store.activities(sinceWeeksAgo: Self.weeks)
        }
    }

    private var subtitle: String {
        let moved = store.themes.filter { $0.weekMs > 0 }.count
        guard !store.themes.isEmpty else {
            return "The initiatives your time clusters into."
        }
        return "\(store.themes.count) initiative\(store.themes.count == 1 ? "" : "s") "
            + "your time clusters into · \(moved) moved this week"
    }

    // MARK: - Table

    private var table: some View {
        let runs = LedgerShapes.weeklyTotals(blocks, weeks: Self.weeks) { $0.themeName }
        let taskCounts = tasksPerTheme()
        return VStack(alignment: .leading, spacing: 0) {
            ColumnHead {
                Text("Theme").frame(maxWidth: .infinity, alignment: .leading)
                Text("Total").frame(width: 84, alignment: .trailing)
                Text("This week").frame(width: 84, alignment: .trailing)
                Text("\(Self.weeks) weeks").frame(width: 108, alignment: .leading)
                Text("Tasks").frame(width: 48, alignment: .trailing)
            }
            ForEach(sorted) { theme in
                row(
                    theme,
                    run: runs[theme.name] ?? Array(repeating: 0, count: Self.weeks),
                    tasks: taskCounts[theme.name] ?? 0)
            }
        }
    }

    private var sorted: [ThemeStore.Overview] {
        switch sort {
        case .week: return store.themes.sorted { $0.weekMs > $1.weekMs }
        case .total: return store.themes.sorted { $0.totalMs > $1.totalMs }
        case .recent: return store.themes.sorted { $0.lastActiveAt > $1.lastActiveAt }
        }
    }

    private func row(
        _ theme: ThemeStore.Overview, run: [Double], tasks: Int
    ) -> some View {
        let quiet = quietFor(theme)
        return Button {
            router.open(.theme(theme.id))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(theme.name)
                            .font(Instrument.sans(13.5, .semibold))
                            .foregroundStyle(quiet == nil ? Instrument.ink : Instrument.muted)
                            .lineLimit(1)
                        if let quiet {
                            Eyebrow(quiet, tracking: 0.6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Figure(
                        TimeBreakdown.duration(theme.totalMs),
                        color: quiet == nil ? Instrument.ink : Instrument.muted)
                        .frame(width: 84, alignment: .trailing)
                    Figure(
                        theme.weekMs > 0 ? TimeBreakdown.duration(theme.weekMs) : "—",
                        color: theme.weekMs > 0 ? Instrument.ink : Instrument.ghost)
                        .frame(width: 84, alignment: .trailing)
                    Sparkline(values: run, dormant: quiet != nil)
                        .frame(width: 108, alignment: .leading)
                    Figure("\(tasks)", color: Instrument.muted)
                        .frame(width: 48, alignment: .trailing)
                }
                if let gist = theme.gist, !gist.isEmpty {
                    Text(gist)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 470, alignment: .leading)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rule() }
    }

    /// "QUIET 9 DAYS" — nil while the theme is still moving. A theme going
    /// quiet is the most useful thing this table can tell you, and it is
    /// invisible in a total.
    private func quietFor(_ theme: ThemeStore.Overview) -> String? {
        let last = Date(timeIntervalSince1970: Double(theme.lastActiveAt) / 1_000)
        let days = Calendar.current.dateComponents(
            [.day], from: last, to: Date()).day ?? 0
        guard days >= Self.quietDays else { return nil }
        return days >= 21 ? "quiet \(days / 7) weeks" : "quiet \(days) days"
    }

    /// Distinct tasks each theme's blocks passed through in the sparkline's
    /// window — the same eight weeks the shape beside it covers, so the two
    /// numbers in a row are answers to the same question.
    private func tasksPerTheme() -> [String: Int] {
        var names: [String: Set<String>] = [:]
        for block in blocks {
            guard let theme = block.themeName, let task = block.taskName else { continue }
            names[theme, default: []].insert(task)
        }
        return names.mapValues(\.count)
    }

    // MARK: - Below the table

    /// What the clusterer thinks you are up to, waiting for a yes. Below the
    /// table, in a quieter register, and never counted in the theme total.
    @ViewBuilder private var proposals: some View {
        if !store.themeProposals.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Eyebrow("Noticed · \(store.themeProposals.count)")
                    Text("not themes yet")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.ghost)
                    Spacer()
                    InlineLink("Dismiss all", action: store.dismissAllThemeProposals)
                }
                .padding(.top, 18)
                .padding(.bottom, 8)
                ForEach(store.themeProposals) { proposal in
                    Rule()
                    proposalRow(proposal)
                }
            }
        }
    }

    private func proposalRow(_ proposal: ThemeProposals.Pending) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(proposal.name)
                    .font(Instrument.sans(13.5, .semibold))
                    .foregroundStyle(Instrument.ink)
                Spacer(minLength: 0)
                Figure(
                    "\(TimeBreakdown.duration(proposal.totalMs)) · "
                        + "\(proposal.blockCount) block\(proposal.blockCount == 1 ? "" : "s")",
                    size: 11, color: Instrument.muted)
            }
            if let gist = proposal.gist, !gist.isEmpty {
                Text(gist)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 470, alignment: .leading)
            }
            HStack(spacing: 10) {
                SolidButton(title: "Add") { store.acceptThemeProposal(proposal) }
                OutlineButton(title: "Dismiss") { store.dismissThemeProposal(proposal) }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 10)
    }

    /// The line that closes the page: hours this week that belong to nothing.
    /// It is the only place in the app that number appears, and it is the
    /// reason to open the Tasks list.
    @ViewBuilder private var unfiled: some View {
        let calendar = Calendar.current
        let weekStart = calendar.startOfWeek(for: Date())
        let loose = blocks
            .filter {
                $0.themeName == nil
                    && $0.startedAt >= Int64(weekStart.timeIntervalSince1970 * 1_000)
            }
            .reduce(0) { $0 + $1.durationMs }
        if loose > 60_000 {
            QuietLine {
                HStack(spacing: 4) {
                    Text("\(TimeBreakdown.duration(loose)) this week sits in no theme —")
                    InlineLink("file it", size: 12.5) {
                        store.taskFilter.theme = .unassigned
                        store.loadTasksSoon()
                        router.go(to: .tasks)
                    }
                }
            }
        }
    }
}
