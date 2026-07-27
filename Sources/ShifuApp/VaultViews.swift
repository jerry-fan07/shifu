import ShifuCore
import SwiftUI

/// *Vault* tab (design.md §5.3), two modes behind a segmented toggle:
/// *Themes* — the broad initiatives your time clusters into — and the
/// *Task log* — today's compiled work log, recent tasks, and projects.
/// Rows navigate to full pages (ThemeDetailView / TaskDetailView).
struct VaultTabView: View {
    enum Mode: String, CaseIterable {
        case themes = "Themes"
        case log = "Task log"
    }

    @EnvironmentObject private var store: LedgerStore
    @State private var mode: Mode = .themes
    @State private var newProjectName = ""
    @State private var selectedHit: VaultSearch.Hit?

    private var isSearching: Bool {
        !store.vaultQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(.top, 10)
                switch mode {
                case .themes: ThemeListView()
                case .log: logPage
                }
            }
            .navigationDestination(for: Int64.self) { taskID in
                TaskDetailView(taskID: taskID)
            }
            .navigationDestination(for: ThemeRoute.self) { route in
                ThemeDetailView(themeID: route.id)
            }
        }
    }

    /// The filter bar is pinned above the list rather than living in the
    /// Tasks section, so it stays put while the log scrolls.
    private var logPage: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            list
        }
    }

    private var list: some View {
        List {
            Section {
                TextField("Search the vault", text: $store.vaultQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: store.vaultQuery) { _, _ in store.searchVault() }
            }

            if isSearching {
                Section("Results") {
                    if store.vaultHits.isEmpty {
                        Text("No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.vaultHits) { hit in
                        Button {
                            selectedHit = hit
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(hit.title).bold()
                                    Spacer()
                                    if let captured = hit.captured {
                                        Text(captured, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Text(hit.snippet)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Today") {
                if store.todayLogs.isEmpty {
                    Text("No work logged yet today — the analyzer compiles logs hourly.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.todayLogs) { entry in
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
            }

            Section("Tasks") {
                // Merge suggestions inline above the tasks they concern
                // (vault-features.md §5.2): one click merges, never automatic.
                ForEach(store.mergeSuggestions) { suggestion in
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
                if store.filteredTasks.isEmpty {
                    Text(store.taskFilter.narrowsResults
                        ? "No tasks match these filters."
                        : "Tasks appear once the analyzer has grouped some activity.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.filteredTasks) { overview in
                    TaskRowView(overview: overview)
                }
            }

            Section("Projects") {
                // One-tap task → project suggestions (vault-features.md §5.3).
                ForEach(store.projectSuggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                        Text("Add **\(suggestion.taskName)** to *\(suggestion.projectName)*?")
                            .font(.callout)
                        Spacer()
                        Button("Add") { store.acceptProjectSuggestion(suggestion) }
                        Button("Dismiss") { store.dismissProjectSuggestion(suggestion) }
                    }
                    .padding(.vertical, 2)
                }
                ForEach(store.projectSummaries) { summary in
                    // Row opens the compiled project note (vault-features.md §2.2).
                    Button {
                        selectedHit = store.projectNoteHit(projectName: summary.project.name)
                    } label: {
                        HStack {
                            Text(summary.project.name)
                            Spacer()
                            Text("\(summary.taskCount) tasks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(LedgerStore.hours(summary.totalMs))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    TextField("New project", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addProject)
                    Button("Add", action: addProject)
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .listStyle(.inset)
        .onAppear { store.refresh() }
        .sheet(item: $selectedHit) { hit in
            NoteReaderView(hit: hit)
        }
    }

    /// Range · sort · project, over the Tasks section only — the Today
    /// section stays the compiled day log, and the Cards deck picker keeps the
    /// full roster (LedgerStore.recentTasks). Labelled because it sits above
    /// the whole page, where an unlabelled bar would read as filtering all of it.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("Tasks")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Range", selection: $store.taskFilter.range) {
                ForEach(TaskRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("How far back the list reaches")

            Picker("Sort", selection: $store.taskFilter.sort) {
                Text("Most recent").tag(TaskStore.Sort.mostRecent)
                Text("Most time").tag(TaskStore.Sort.mostTime)
            }
            .fixedSize()
            .help("Order by when it was worked, or how much time it took")

            Picker("Project", selection: $store.taskFilter.project) {
                Text("All projects").tag(TaskStore.ProjectScope.any)
                Text("No project").tag(TaskStore.ProjectScope.unassigned)
                ForEach(store.projectSummaries) { summary in
                    if let projectID = summary.project.id {
                        Text(summary.project.name)
                            .tag(TaskStore.ProjectScope.project(id: projectID))
                    }
                }
            }
            .fixedSize()
            .help("Narrow to one project")

            if store.taskFilter.isNarrowed {
                Button("Clear") { store.taskFilter = TaskListFilter() }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: store.taskFilter) { _, _ in store.loadTasks() }
    }

    private func addProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.createProject(named: name)
        newProjectName = ""
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

/// One task row: inline rename, latest log line, project assignment, and
/// navigation to the task's full page.
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
                projectMenu
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

    private var projectMenu: some View {
        Menu(overview.projectName ?? "No project") {
            Button("No project") {
                if let taskID = overview.task.id { store.assignTask(taskID, toProject: nil) }
            }
            ForEach(store.projectSummaries) { summary in
                Button(summary.project.name) {
                    if let taskID = overview.task.id {
                        store.assignTask(taskID, toProject: summary.project.id)
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
