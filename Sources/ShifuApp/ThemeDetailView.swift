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
    case campaign, tasks, story, sources, history, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .campaign: return "The campaign"
        case .tasks: return "Tasks"
        case .story: return "Story"
        case .sources: return "Where the time went"
        case .history: return "History"
        case .recent: return "Recent activity"
        }
    }
}

// MARK: - The theme page

/// One theme as a page, opened by its campaign (design 3a): thirty days of
/// blocks as one scroll-driven chart with the theme's tasks under it, then the
/// running narrative the analyzer keeps, then where the time went.
struct ThemePage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let themeID: Int64

    @State private var detail: ThemeStore.Detail?
    @State private var campaign: ThemeCampaign?

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
        // Built once per load, not per body pass: the campaign folds weeks of
        // block rows, and the hero re-renders every frame while it reveals.
        campaign = detail.map { loaded in
            ThemeCampaign.build(
                blocks: store.activities(sinceWeeksAgo: ThemesView.weeks)
                    .filter { $0.themeName == loaded.overview.name },
                related: loaded.tasks)
        }
    }

    private var weekMs: Int64 {
        store.themes.first { $0.id == themeID }?.weekMs ?? 0
    }

    private var hasCampaign: Bool {
        !(campaign?.blocks.isEmpty ?? true)
    }

    private func page(_ detail: ThemeStore.Detail) -> some View {
        // The title screen is sized off the page, so it has to know how tall
        // the page is before the scroll view lays its content out.
        GeometryReader { proxy in
            SectionScroll {
                PageBody {
                    ThemeTitleScreen(
                        detail: detail, weekMs: weekMs, pageHeight: proxy.size.height,
                        cue: hasCampaign
                            ? "Scroll for the campaign" : "Scroll for the story")
                    if let campaign, !campaign.blocks.isEmpty {
                        CampaignHero(campaign: campaign) { router.open(.task($0)) }
                            .sectionAnchor(ThemeSection.campaign.rawValue)
                    } else {
                        BlankSlate(
                            "Nothing in the last 30 days — the campaign draws "
                                + "itself from the time the ledger files here.")
                    }
                    story(detail)
                    statsBand
                    sources
                    history(detail)
                    recent(detail)
                }
            }
            // The hero and the title screen read their own scroll position out
            // of this space; the name has to sit on the scroll view.
            .coordinateSpace(.named(CampaignHero.scrollSpace))
        }
    }

    private func story(_ detail: ThemeStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The story so far")
                .font(Instrument.sans(30, .semibold))
                .tracking(-0.6)
                .foregroundStyle(.white)
            if let summary = detail.overview.summary, !summary.isEmpty {
                Text(summary)
                    .font(Instrument.sans(14.5))
                    .lineSpacing(5.5)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.top, 12)
            } else {
                Text("No narrative yet — the analyzer writes one once the theme has "
                    + "a few days behind it.")
                    .font(Instrument.sans(13))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(20)
        // The banner's ground, so the page's two filled panels are one family
        // in both appearances.
        .background(Instrument.banner)
        .padding(.top, 44)
        .modifier(ScrollRise())
        .sectionAnchor(ThemeSection.story.rawValue)
    }

    /// The campaign's vital signs, popping in one after another on the way
    /// past: days active, longest run, the peak day.
    @ViewBuilder private var statsBand: some View {
        if let campaign, !campaign.blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(campaign.range)
                HStack(alignment: .firstTextBaseline, spacing: 56) {
                    ForEach(Array(campaign.stats.enumerated()), id: \.element.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Figure(entry.element.value, size: 28, weight: .medium)
                            Text(entry.element.caption)
                                .font(Instrument.sans(12))
                                .foregroundStyle(Instrument.muted)
                        }
                        .modifier(ScrollPop(order: entry.offset))
                    }
                }
                .padding(.top, 10)
            }
            .padding(.top, 72)
        }
    }

    /// Apps and domains the campaign's time ran through, biggest first, each
    /// against the longest bar. The bars grow in as the section scrolls up.
    @ViewBuilder private var sources: some View {
        if let campaign, !campaign.sources.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Where the time went")
                    .font(Instrument.sans(30, .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Instrument.ink)
                    .modifier(ScrollRise())
                VStack(spacing: 0) {
                    ForEach(Array(campaign.sources.enumerated()), id: \.element.id) { entry in
                        sourceRow(entry.element, order: entry.offset)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.top, 16)
            }
            .padding(.top, 96)
            .sectionAnchor(ThemeSection.sources.rawValue)
        }
    }

    /// Every day the theme has ever moved, newest first — the campaign shows
    /// the last thirty; this is the whole record.
    @ViewBuilder private func history(_ detail: ThemeStore.Detail) -> some View {
        if !detail.days.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(Instrument.sans(30, .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Instrument.ink)
                    .modifier(ScrollRise())
                VStack(spacing: 0) {
                    ForEach(detail.days) { day in
                        Rule()
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Figure(
                                Date(timeIntervalSince1970: Double(day.dayStart) / 1_000)
                                    .formatted(.dateTime.weekday(.abbreviated).day().month()),
                                color: Instrument.faint)
                                .frame(width: 96, alignment: .leading)
                            // The summary's *what*, as the task page's day rows
                            // set it — the sources half names windows, not intent.
                            Text(themeDayTitle(day.summary))
                                .font(Instrument.sans(12.5))
                                .foregroundStyle(Instrument.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Figure(TimeBreakdown.duration(day.durationMs),
                                   color: Instrument.muted)
                                .frame(width: 72, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.top, 12)
            }
            .padding(.top, 96)
            .sectionAnchor(ThemeSection.history.rawValue)
        }
    }

    private func themeDayTitle(_ summary: String) -> String {
        let title = NoteProse.dayTitle(summary)
        return title.isEmpty ? summary : title
    }

    private func sourceRow(_ row: ThemeCampaign.SourceRow, order: Int) -> some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 12) {
                Text(row.name)
                    .font(Instrument.sans(13.5))
                    .foregroundStyle(Instrument.ink)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Instrument.accent)
                        .frame(width: proxy.size.width * row.fraction, height: 5)
                        .modifier(ScrollGrow(order: order))
                }
                .frame(height: 5)
                .background(RoundedRectangle(cornerRadius: 1).fill(Instrument.well))
                Figure(row.time, size: 12.5, color: Instrument.muted)
            }
            .padding(.vertical, 7)
        }
    }

    /// The raw tail: the theme's latest blocks, one line each — deliberately
    /// more than anyone reads, so the page never runs out of bottom.
    @ViewBuilder private func recent(_ detail: ThemeStore.Detail) -> some View {
        if !detail.recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent activity")
                    .font(Instrument.sans(30, .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Instrument.ink)
                    .modifier(ScrollRise())
                VStack(spacing: 0) {
                    ForEach(detail.recent) { line in
                        Rule()
                        recentRow(line)
                    }
                }
                .padding(.top, 12)
            }
            .padding(.top, 96)
            .padding(.bottom, 120)
            .sectionAnchor(ThemeSection.recent.rawValue)
        }
    }

    private func recentRow(_ line: TaskStore.ActivityLine) -> some View {
        let started = Date(timeIntervalSince1970: Double(line.startedAt) / 1_000)
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Figure(
                started.formatted(.dateTime.weekday(.abbreviated).day().month()),
                color: Instrument.faint)
                .frame(width: 96, alignment: .leading)
            Figure(started.formatted(.dateTime.hour().minute()), color: Instrument.faint)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            Text(line.topic ?? line.source)
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure(TimeBreakdown.duration(line.endedAt - line.startedAt),
                   color: Instrument.muted)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Scroll passes

/// Design 3a's motion for the sections after the hero: rise on the way into
/// the window, dim and step back a touch on the way out. Driven by scroll
/// position, so it scrubs; skipped whole under Reduce Motion.
private struct ScrollRise: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.interactive, axis: .vertical) { effect, phase in
                let entering = max(0, phase.value)
                let leaving = max(0, -phase.value)
                return effect
                    .opacity(1 - entering - 0.75 * leaving)
                    .offset(y: 16 * entering - 14 * leaving)
                    .scaleEffect(1 - 0.03 * leaving)
            }
        }
    }
}

/// A figure that pops to size as it scrolls into the window — the stats
/// band's entrance. `order` staggers a row of them: each later figure waits
/// until a little more of the band is visible before it lands.
private struct ScrollPop: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let order: Int

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(
                .interactive.threshold(.visible(min(0.25 + 0.2 * Double(order), 0.85))),
                axis: .vertical
            ) { effect, phase in
                let entering = max(0, phase.value)
                let leaving = max(0, -phase.value)
                return effect
                    .opacity(1 - entering - 0.75 * leaving)
                    .scaleEffect(1 - 0.12 * entering, anchor: .bottomLeading)
                    .offset(y: 12 * entering - 14 * leaving)
            }
        }
    }
}

/// A meter that swipes out to its length, left to right, as it scrolls into
/// the window. `order` staggers a column of them into a cascade.
private struct ScrollGrow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let order: Int

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(
                .interactive.threshold(.visible(min(0.2 + 0.1 * Double(order), 0.8))),
                axis: .vertical
            ) { effect, phase in
                effect.scaleEffect(x: 1 - max(0, phase.value), y: 1, anchor: .leading)
            }
        }
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
