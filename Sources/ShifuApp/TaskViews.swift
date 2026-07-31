import ShifuCore
import SwiftUI

/// The Vault's *Tasks* place (design.md §5.3): every task the ledger has
/// named, narrowed by the filter row in the header and opened by clicking a
/// row. The filters live beside the title rather than in a bar of their own —
/// they *are* the title, in the sense that "Tasks, last 14 days, over 15m" is
/// what you are actually looking at.
struct TasksView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(spacing: 0) {
            header
            PageBody {
                if !store.mergeBannerClosed { mergeBanner }
                if store.filteredTasks.isEmpty {
                    BlankSlate(
                        store.taskFilter.narrowsResults
                            ? "No tasks match these filters."
                            : "Tasks appear once the analyzer has grouped some activity. "
                                + "It passes hourly.")
                } else {
                    ForEach(store.filteredTasks, id: \.rowID) { overview in
                        row(overview)
                        Rule()
                    }
                }
            }
        }
        .onAppear { store.refresh() }
        .onChange(of: store.taskFilter) { _, _ in store.loadTasksSoon() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tasks")
                    .font(Instrument.sans(18, .semibold))
                    .tracking(-0.18)
                    .foregroundStyle(Instrument.ink)
                    .padding(.trailing, 6)
                FilterMenu(
                    options: TaskRange.allCases.map { ($0.rawValue, $0) },
                    selection: $store.taskFilter.range)
                    .help("How far back the list reaches")
                FilterMenu(
                    options: TaskMinimum.allCases.map { ($0.rawValue, $0) },
                    selection: $store.taskFilter.minimum)
                    .help("Hide tasks you spent barely any time on")
                FilterMenu(
                    options: [("Most recent", TaskStore.Sort.mostRecent),
                              ("Most time", TaskStore.Sort.mostTime)],
                    selection: $store.taskFilter.sort)
                    .help("Order by when it was worked, or how much time it took")
                FilterMenu(
                    options: [("All themes", TaskStore.ThemeScope.any),
                              ("No theme", TaskStore.ThemeScope.unassigned)]
                        + store.themes.map { ($0.name, TaskStore.ThemeScope.theme(key: $0.key)) },
                    selection: $store.taskFilter.theme)
                    .help("Narrow to the tasks whose time sits in one theme")
                if store.taskFilter.isNarrowed {
                    InlineLink("Clear") { store.taskFilter = TaskListFilter() }
                }
                Spacer(minLength: 0)
                Figure(store.taskCountLabel, size: 11, color: Instrument.faint)
            }
            .padding(.horizontal, Instrument.gutter)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Rule(weight: .section)
        }
    }

    /// The strongest open merge, above the rows it concerns. One at a time:
    /// a weekly pass can open more pairs than the list has rows, and inline
    /// they would push the actual task list off the screen. It sits *inside*
    /// the scrolling body rather than pinned under the header — a suggestion
    /// is worth a first screen, not a permanent band — and closes for the
    /// launch, because reading down the log shouldn't cost an answer.
    @ViewBuilder private var mergeBanner: some View {
        if let suggestion = store.mergeSuggestions.first {
            HStack(spacing: 10) {
                Text("**\(suggestion.nameA)** and **\(suggestion.nameB)** look like one task.")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.railInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SolidButton(title: "Merge") { store.acceptMerge(suggestion) }
                OutlineButton(title: "Not a duplicate") { store.dismissMerge(suggestion) }
                if store.hiddenSuggestionCount > 0 {
                    InlineLink("\(store.hiddenSuggestionCount) more") {
                        router.open(.merges)
                    }
                }
                closeMark
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Instrument.warm.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Instrument.alert.opacity(0.3), lineWidth: 1)
            }
            .padding(.top, 12)
        }
    }

    /// Puts the banner away without answering it. Deliberately not the same
    /// act as "Not a duplicate", which answers *this pair* for good in the
    /// database — this one only clears the page, and every pair is still
    /// waiting on the Suggestions screen.
    private var closeMark: some View {
        Button { store.mergeBannerClosed = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Instrument.faint)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide these until the next launch")
    }

    // MARK: - Rows

    private func row(_ overview: TaskStore.Overview) -> some View {
        Button {
            if let taskID = overview.task.id { router.open(.task(taskID)) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(overview.task.name)
                            .font(Instrument.sans(13.5, .semibold))
                            .foregroundStyle(Instrument.ink)
                            .lineLimit(1)
                        Tag(
                            overview.themeName ?? "No theme",
                            dashed: overview.themeName == nil)
                    }
                    Spacer(minLength: 0)
                    Figure(TimeBreakdown.duration(overview.totalMs))
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(overview.latestSummary ?? "No log line yet.")
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Figure(
                        Date(timeIntervalSince1970: Double(overview.task.lastActiveAt) / 1_000)
                            .formatted(.relative(presentation: .numeric)),
                        size: 10.5, color: Instrument.ghost)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The full suggestion queue

/// Every open suggestion, off the Tasks page (vault-features.md §5.2). The
/// list shows one merge at a time; this is where the rest live, with a bulk
/// dismiss per queue so a backlog nobody cares about goes in one action.
struct MergeReviewView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                "Suggestions",
                subtitle: "Shifu already merges near-identical tasks on its own. These "
                    + "are the less certain ones.")
            PageBody {
                if store.allMergeSuggestions.isEmpty && store.allThemeSuggestions.isEmpty {
                    BlankSlate(
                        "Nothing to review. Suggestions appear when the weekly analysis "
                            + "finds tasks that look like the same work.")
                }
                queue(
                    "Possible duplicate tasks", count: store.allMergeSuggestions.count,
                    dismissAll: store.dismissAllMerges
                ) {
                    ForEach(store.allMergeSuggestions, id: \.rowID) { suggestion in
                        Rule()
                        row(
                            text: Self.markdown(
                                "**\(suggestion.nameA)** and **\(suggestion.nameB)** "
                                    + "look alike"),
                            confidence: suggestion.cosine, accept: "Merge",
                            onAccept: { store.acceptMerge(suggestion) },
                            onDismiss: { store.dismissMerge(suggestion) })
                    }
                }
                queue(
                    "Suggested theme assignments", count: store.allThemeSuggestions.count,
                    dismissAll: store.dismissAllThemeSuggestions
                ) {
                    ForEach(store.allThemeSuggestions, id: \.rowID) { suggestion in
                        Rule()
                        row(
                            text: Self.markdown(
                                "Add **\(suggestion.taskName)** to "
                                    + "*\(suggestion.themeName)*"),
                            confidence: suggestion.cosine, accept: "Add",
                            onAccept: { store.acceptThemeSuggestion(suggestion) },
                            onDismiss: { store.dismissThemeSuggestion(suggestion) })
                    }
                }
            }
        }
        .onAppear { store.refresh() }
    }

    @ViewBuilder private func queue<Content: View>(
        _ title: String, count: Int, dismissAll: @escaping () -> Void,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Eyebrow("\(title) · \(count)")
                    Spacer()
                    InlineLink("Dismiss all", action: dismissAll)
                }
                .padding(.top, 16)
                .padding(.bottom, 6)
                rows()
            }
        }
    }

    /// Task names are runtime strings, so the emphasis around them can't ride
    /// on `Text`'s literal markdown — it is parsed here instead. Falls back to
    /// the raw text if the names themselves contain markdown punctuation.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// The score is the whole reason a pair is here rather than merged
    /// already; showing it makes "why am I being asked about this?" answerable.
    private func row(
        text: AttributedString, confidence: Double, accept: String,
        onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(text)
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure(String(format: "%.2f", confidence), size: 11, color: Instrument.ghost)
            SolidButton(title: accept, action: onAccept)
            OutlineButton(title: "Dismiss", action: onDismiss)
        }
        .padding(.vertical, 8)
    }
}
