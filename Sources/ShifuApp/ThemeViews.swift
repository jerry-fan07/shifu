import ShifuCore
import SwiftUI

/// Navigation value for pushing a theme page — distinct from the bare Int64
/// used for task pages, so one NavigationStack can route both.
struct ThemeRoute: Hashable {
    let id: Int64
}

/// The Vault tab's *Themes* mode (design.md §5.3): the user's broad ongoing
/// initiatives, most recently active first.
struct ThemeListView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        List {
            ForEach(store.themes) { theme in
                NavigationLink(value: ThemeRoute(id: theme.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(theme.name).bold()
                            Spacer()
                            if theme.weekMs > 0 {
                                Text("\(LedgerStore.hours(theme.weekMs)) this week")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(LedgerStore.hours(theme.totalMs))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if let gist = theme.gist, !gist.isEmpty {
                            Text(gist)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
        // Overlaid rather than placed as a list row so it centers in the
        // full content area instead of hugging the top-leading corner.
        .overlay {
            if store.themes.isEmpty {
                ContentUnavailableView(
                    "No themes yet", systemImage: "square.stack.3d.up",
                    description: Text("Themes are the broad initiatives your time "
                        + "clusters into — they appear after the next analysis run "
                        + "with an AI backend configured in Settings."))
            }
        }
        .onAppear { store.refresh() }
    }
}

/// One theme as a full page: the running narrative, day-by-day history,
/// the tasks the theme's time flowed through (each links to its task page),
/// and recent raw activity.
struct ThemeDetailView: View {
    @EnvironmentObject private var store: LedgerStore
    let themeID: Int64

    @State private var detail: ThemeStore.Detail?
    @State private var name = ""

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                ContentUnavailableView("Theme not found", systemImage: "questionmark.square")
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        detail = store.themeDetail(themeID)
        name = detail?.overview.name ?? ""
    }

    private func content(_ detail: ThemeStore.Detail) -> some View {
        List {
            Section {
                header(detail)
            }
            if let summary = detail.overview.summary, !summary.isEmpty {
                Section("The story so far") {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if !detail.days.isEmpty {
                Section("History") {
                    ForEach(detail.days) { day in
                        dayRow(day)
                    }
                }
            }
            if !detail.tasks.isEmpty {
                Section("Tasks in this theme") {
                    ForEach(detail.tasks) { task in
                        NavigationLink(value: task.taskID) {
                            HStack {
                                Text(task.name)
                                Spacer()
                                Text(LedgerStore.hours(task.ms))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !detail.recent.isEmpty {
                Section("Recent activity") {
                    ForEach(detail.recent) { line in
                        ActivityLineRow(line: line)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(detail.overview.name)
    }

    @ViewBuilder private func header(_ detail: ThemeStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Theme name", text: $name)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .onSubmit {
                    store.renameTheme(themeID, to: name)
                    reload()
                }
            if let gist = detail.overview.gist, !gist.isEmpty {
                Text(gist)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(LedgerStore.hours(detail.overview.totalMs), systemImage: "clock")
                    .monospacedDigit()
                Label {
                    Text(Date(timeIntervalSince1970:
                            Double(detail.overview.lastActiveAt) / 1_000),
                         format: .relative(presentation: .named))
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func dayRow(_ day: ThemeStore.DayEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Date(timeIntervalSince1970: Double(day.dayStart) / 1_000),
                 format: .dateTime.weekday(.abbreviated).day().month())
                .monospacedDigit()
                .frame(width: 110, alignment: .leading)
            Text(day.summary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Text(LedgerStore.hours(day.durationMs))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
