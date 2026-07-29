import ShifuCore
import SwiftUI

/// The *Task log* page (design.md §5.3): today's compiled work log and the
/// recent-task roster, with the filter bar pinned above the list so it stays
/// put while the log scrolls. Rows navigate to full task pages; vault search
/// lives on the Scrolls page, themes on their own page.
struct TaskLogView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        PageScaffold(destination: .tasks) {
            Eyebrow(store.taskCountLabel)
        } content: {
            VStack(spacing: 0) {
                filterBar
                Divider()
                list
            }
        }
    }

    private var list: some View {
        List {
            Section {
                if store.todayLogs.isEmpty {
                    Text("No work logged yet today — the analyzer compiles logs hourly.")
                        .foregroundStyle(.secondary)
                } else if store.filteredTodayLogs.isEmpty {
                    Text("Nothing today matches these filters.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.filteredTodayLogs, id: \.rowID) { entry in
                    // Opens the task's full page (design.md §5.3).
                    NavigationLink(value: entry.taskID) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.taskName).bold()
                                Text(entry.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(LedgerStore.hours(entry.durationMs))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Eyebrow("today")
            }

            Section {
                // The strongest few merge suggestions inline, above the tasks
                // they concern (vault-features.md §5.2). The certain ones were
                // already merged by the analyzer; the rest of the queue is one
                // tap away rather than pushing the task list off screen.
                ForEach(store.mergeSuggestions, id: \.rowID) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(.secondary)
                        Text("**\(suggestion.nameA)** and **\(suggestion.nameB)** look like one task")
                            .font(.callout)
                        Spacer()
                        Button("Merge") { store.acceptMerge(suggestion) }
                        Button("Dismiss") { store.dismissMerge(suggestion) }
                    }
                    .padding(.vertical, 2)
                }
                if store.hiddenSuggestionCount > 0 {
                    NavigationLink(value: SuggestionsRoute()) {
                        Text("Review \(store.hiddenSuggestionCount) more suggestion"
                            + "\(store.hiddenSuggestionCount == 1 ? "" : "s")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.filteredTasks.isEmpty {
                    Text(store.taskFilter.narrowsResults
                        ? "No tasks match these filters."
                        : "Tasks appear once the analyzer has grouped some activity.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.filteredTasks, id: \.rowID) { overview in
                    TaskRowView(overview: overview)
                }
            } header: {
                Eyebrow("tasks")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onAppear { store.refresh() }
    }

    /// Range · minimum · sort · theme. Minimum and theme also scope the
    /// *Today* day log (see `LedgerStore.filteredTodayLogs`); range and sort
    /// don't — that log is already one day, and its recency order is what makes
    /// it a log. The Cards deck picker keeps the full roster
    /// (LedgerStore.recentTasks). Labelled because it sits above the whole page,
    /// where an unlabelled bar would read as filtering all of it.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Eyebrow("filter")

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
                Button("Clear") { store.taskFilter = TaskListFilter() }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .onChange(of: store.taskFilter) { _, _ in store.loadTasksSoon() }
    }
}

/// Read-only view of one vault note from a search hit (vault-features.md §4).
/// Editing happens in the user's editor of choice — hence Reveal in Finder.
/// Shared with TaskDetailView, which presents notes from the task page.
struct NoteReaderView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let hit: VaultSearch.Hit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.title).font(.title3).bold()
                Spacer()
                if let captured = hit.captured {
                    Text(captured, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            if let doc = store.noteDocument(for: hit) {
                ScrollView {
                    Text(doc.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text("The note file is gone — it may have been moved or deleted.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.noteFileURL(for: hit)])
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 340)
    }
}

/// One task row: inline rename, latest log line, theme assignment, and
/// navigation to the task's full page.
/// One filter dimension as a pull-down. A `Menu` of buttons rather than a
/// menu-style `Picker`: on macOS 26 the Picker's menu neither commits a
/// clicked item to the binding nor tracks it afterwards, so the filter bar
/// read as dead — plain menu buttons use the same NSMenu machinery as the
/// menu bar items, which do fire.
private struct FilterMenu<Option: Hashable>: View {
    let options: [(label: String, value: Option)]
    @Binding var selection: Option

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Text(options.first { $0.value == selection }?.label ?? "")
        }
        .fixedSize()
    }
}

private struct TaskRowView: View {
    @EnvironmentObject private var store: LedgerStore
    let overview: TaskStore.Overview
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("Task name", text: $name)
                    .textFieldStyle(.plain)
                    .bold()
                    .onSubmit {
                        if let taskID = overview.task.id { store.renameTask(taskID, to: name) }
                    }
                Spacer()
                if let taskID = overview.task.id {
                    NavigationLink(value: taskID) {
                        Image(systemName: "chevron.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the task page")
                }
                Text(LedgerStore.hours(overview.totalMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                themeMenu
            }
            if let summary = overview.latestSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .onAppear { name = overview.task.name }
        .onChange(of: overview.task.name) { _, updated in name = updated }
    }

    /// The task's theme, and the menu to move it. What it shows is the theme
    /// its time mostly sits in — picking one here files *all* of the task's
    /// blocks there, so the label always matches what was chosen.
    private var themeMenu: some View {
        Menu(overview.themeName ?? "No theme") {
            Button("No theme") {
                if let taskID = overview.task.id { store.assignTask(taskID, toTheme: nil) }
            }
            ForEach(store.themes) { theme in
                Button(theme.name) {
                    if let taskID = overview.task.id {
                        store.assignTask(taskID, toTheme: theme.key)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// The *Practice* page (home screen, inbox, review session) lives in
// PracticeView.swift / ReviewView.swift / CardEditSheet.swift.
