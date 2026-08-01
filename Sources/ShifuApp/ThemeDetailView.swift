import ShifuCore
import SwiftUI

/// The source list while a theme is open: the way back, this theme's sections,
/// its siblings, and the two things you can do to it.
struct ThemeContents: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let themeID: Int64
    @State private var editing: ThemeStore.Overview?
    @State private var confirmingDelete = false

    private var theme: ThemeStore.Overview? {
        store.themes.first { $0.id == themeID }
    }

    var body: some View {
        RailColumn {
            RailBack(title: "Themes") { router.go(to: .themes) }
            RailHeading("This theme")
            ForEach(ThemeSection.allCases) { section in
                RailRow(title: section.title) { router.scroll(to: section.rawValue) }
            }
            RailHeading("Other themes")
                .padding(.top, 14)
            ForEach(store.themes.filter { $0.id != themeID }.prefix(6)) { other in
                RailRow(title: other.name) { router.open(.theme(other.id)) }
            }
        } footer: {
            Button("Rename theme") { editing = theme }
                .buttonStyle(.plain)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.railInk)
            Button("Delete theme") { confirmingDelete = true }
                .buttonStyle(.plain)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.alert)
        }
        .sheet(item: $editing) { ThemeEditSheet(theme: $0) }
        .confirmationDialog(
            "Delete \"\(theme?.name ?? "")\"?", isPresented: $confirmingDelete
        ) {
            Button("Delete theme", role: .destructive) {
                store.deleteTheme(themeID)
                router.go(to: .themes)
            }
        } message: {
            Text("The time stays in your ledger — it just stops being filed under "
                + "this theme, and Shifu won't suggest it again.")
        }
    }
}

/// The theme page's sections, in the order they appear. The source list lists
/// these and scrolls to them; the page anchors them by the same raw value.
enum ThemeSection: String, CaseIterable, Identifiable {
    case story, history, tasks, sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: return "Story"
        case .history: return "History"
        case .tasks: return "Tasks"
        case .sources: return "Where the time went"
        }
    }
}

// MARK: - The theme page

/// One theme as a page: the running narrative the analyzer keeps, the
/// day-by-day history under it, and the two columns that say what the theme
/// was actually made of.
struct ThemePage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let themeID: Int64

    @State private var detail: ThemeStore.Detail?
    @State private var blocks: [LedgerBuilder.LabeledActivity] = []

    var body: some View {
        Group {
            if let detail {
                page(detail)
            } else {
                PageHead("Theme not found")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: themeID) { _, _ in reload() }
    }

    private func reload() {
        detail = store.themeDetail(themeID)
        blocks = store.activities(sinceWeeksAgo: ThemesView.weeks)
            .filter { $0.themeName == detail?.overview.name }
    }

    private var weekMs: Int64 {
        store.themes.first { $0.id == themeID }?.weekMs ?? 0
    }

    private func page(_ detail: ThemeStore.Detail) -> some View {
        VStack(spacing: 0) {
            header(detail)
            SectionScroll {
                PageBody {
                    story(detail)
                    history(detail)
                    columns(detail)
                }
            }
        }
    }

    private func header(_ detail: ThemeStore.Detail) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(detail.overview.name)
                    .font(Instrument.sans(21, .semibold))
                    .tracking(-0.31)
                    .foregroundStyle(Instrument.ink)
                if let gist = detail.overview.gist, !gist.isEmpty {
                    Text(gist)
                        .font(Instrument.sans(13))
                        .foregroundStyle(Instrument.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.top, 4)
                }
                HStack(spacing: 18) {
                    Figure("\(TimeBreakdown.duration(detail.overview.totalMs)) total",
                           size: 11.5, color: Instrument.muted)
                    // From the list's overview, not the detail's: the detail
                    // query doesn't fill `weekMs` in, and a theme page that
                    // silently drops the week is the one figure you came for.
                    if weekMs > 0 {
                        Figure("\(TimeBreakdown.duration(weekMs)) this week",
                               size: 11.5, color: Instrument.muted)
                    }
                    Figure("\(detail.tasks.count) task\(detail.tasks.count == 1 ? "" : "s")",
                           size: 11.5, color: Instrument.muted)
                    Figure(
                        "last active " + Date(
                            timeIntervalSince1970: Double(detail.overview.lastActiveAt) / 1_000)
                            .formatted(.relative(presentation: .numeric)),
                        size: 11.5, color: Instrument.muted)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Instrument.gutter)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Rule(weight: .section)
        }
    }

    @ViewBuilder private func story(_ detail: ThemeStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("The story so far")
                .padding(.top, 14)
                .padding(.bottom, 6)
            if let summary = detail.overview.summary, !summary.isEmpty {
                Text(summary)
                    .font(Instrument.sans(13.5))
                    .lineSpacing(4)
                    .foregroundStyle(Instrument.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: 700, alignment: .leading)
            } else {
                Text("No narrative yet — the analyzer writes one once the theme has "
                    + "a few days behind it.")
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.muted)
            }
        }
        .sectionAnchor(ThemeSection.story.rawValue)
    }

    @ViewBuilder private func history(_ detail: ThemeStore.Detail) -> some View {
        if !detail.days.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("History")
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                ForEach(detail.days) { day in
                    Rule()
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Figure(
                            Date(timeIntervalSince1970: Double(day.dayStart) / 1_000)
                                .formatted(.dateTime.weekday(.abbreviated).day().month()),
                            color: Instrument.faint)
                            .frame(width: 96, alignment: .leading)
                        // The summary's *what*, as the task page's day rows set
                        // it — the sources half names windows, not intent.
                        Text(themeDayTitle(day.summary))
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Figure(TimeBreakdown.duration(day.durationMs), color: Instrument.muted)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                }
            }
            .sectionAnchor(ThemeSection.history.rawValue)
        }
    }

    private func themeDayTitle(_ summary: String) -> String {
        let title = NoteProse.dayTitle(summary)
        return title.isEmpty ? summary : title
    }

    /// What the theme was made of, two ways: the tasks it ran through, and the
    /// apps those tasks lived in.
    private func columns(_ detail: ThemeStore.Detail) -> some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Tasks in this theme")
                    .padding(.bottom, 5)
                ForEach(detail.tasks) { task in
                    Rule()
                    Button { router.open(.task(task.taskID)) } label: {
                        HStack {
                            Text(task.name)
                                .font(Instrument.sans(12.5))
                                .foregroundStyle(Instrument.ink)
                                .lineLimit(1)
                            Spacer()
                            Figure(TimeBreakdown.duration(task.ms), color: Instrument.muted)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionAnchor(ThemeSection.tasks.rawValue)

            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Where the time went")
                    .padding(.bottom, 5)
                ForEach(sources.prefix(6), id: \.name) { source in
                    Rule()
                    HStack {
                        Text(source.name)
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.ink)
                            .lineLimit(1)
                        Spacer()
                        Figure(TimeBreakdown.duration(source.ms), color: Instrument.muted)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionAnchor(ThemeSection.sources.rawValue)
        }
        .padding(.top, 16)
    }

    /// Apps and domains this theme's blocks ran through, biggest first.
    private var sources: [(name: String, ms: Int64)] {
        var totals: [String: Int64] = [:]
        for block in blocks { totals[block.source, default: 0] += block.durationMs }
        return totals.sorted { $0.value > $1.value }.map { (name: $0.key, ms: $0.value) }
    }
}

// MARK: - Editing

/// Create a theme, or edit the name and gist of one. Both live in one sheet:
/// the fields are identical, and the only difference is whether there is a row
/// behind them to delete.
struct ThemeEditSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    /// nil when creating.
    let theme: ThemeStore.Overview?

    @State private var name: String
    @State private var gist: String

    init(theme: ThemeStore.Overview?) {
        self.theme = theme
        _name = State(initialValue: theme?.name ?? "")
        _gist = State(initialValue: theme?.gist ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(theme == nil ? "New theme" : "Edit theme")
                .font(Instrument.sans(16, .semibold))
                .foregroundStyle(Instrument.ink)
            field("Name", prompt: "Q3 pricing rework", text: $name)
            field(
                "Description (optional)",
                prompt: "Rebuilding the tiers around per-seat floors.", text: $gist)
            Text(theme == nil
                ? "Shifu will file matching time into this theme from the next "
                    + "analysis run on."
                : "Renaming keeps the theme's history — its time stays filed here.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                OutlineButton(title: "Cancel") { dismiss() }
                SolidButton(title: theme == nil ? "Create" : "Save") {
                    guard !trimmedName.isEmpty else { return }
                    if let theme {
                        store.updateTheme(theme.id, name: name, gist: gist)
                    } else {
                        store.createTheme(named: name, gist: gist)
                    }
                    dismiss()
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .background(Instrument.ground)
    }

    private func field(
        _ label: String, prompt: String, text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(Instrument.sans(13))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
        }
    }
}
