import ShifuCore
import SwiftUI

/// *Vault* tab (design.md §5.3): today's compiled work log, the most recent
/// tasks (renameable, assignable to projects), and projects with time spent.
struct VaultTabView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var newProjectName = ""
    @State private var selectedHit: VaultSearch.Hit?

    private var isSearching: Bool {
        !store.vaultQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
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
                    // Opens the task's latest work note (vault-features.md §2.1).
                    Button {
                        selectedHit = store.latestWorkNote(
                            taskID: entry.taskID, title: entry.taskName)
                    } label: {
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
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }

            Section("Recent tasks") {
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
                if store.recentTasks.isEmpty {
                    Text("Tasks appear once the analyzer has grouped some activity.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.recentTasks) { overview in
                    TaskRowView(overview: overview) {
                        if let taskID = overview.task.id {
                            selectedHit = store.latestWorkNote(
                                taskID: taskID, title: overview.task.name)
                        }
                    }
                }
            }

            Section("Projects") {
                ForEach(store.projectSummaries) { summary in
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

    private func addProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.createProject(named: name)
        newProjectName = ""
    }
}

/// Read-only view of one vault note from a search hit (vault-features.md §4).
/// Editing happens in the user's editor of choice — hence Reveal in Finder.
private struct NoteReaderView: View {
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

/// One task row: inline rename, latest log line, project assignment, and a
/// button opening the task's latest work note.
private struct TaskRowView: View {
    @EnvironmentObject private var store: LedgerStore
    let overview: TaskStore.Overview
    var openNote: () -> Void
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
                Button(action: openNote) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Open the latest work note")
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

/// *Cards* tab — the spaced-repetition screen (design.md §5.2): pick a deck
/// (everything, a project, or a task), start a session, and triage the inbox.
struct CardsTabView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Deck", selection: $store.reviewDeck) {
                    Text("All notes").tag(ReviewDeck.all)
                    ForEach(store.projectSummaries) { summary in
                        if let projectID = summary.project.id {
                            Text("Project · \(summary.project.name)")
                                .tag(ReviewDeck.project(id: projectID, name: summary.project.name))
                        }
                    }
                    ForEach(store.recentTasks) { overview in
                        Text("Task · \(overview.task.name)")
                            .tag(ReviewDeck.task(key: overview.task.key, name: overview.task.name))
                    }
                }
                .frame(maxWidth: 340)
                Spacer()
                Button("Review · \(store.deckDueNotes.count) due") {
                    openWindow(id: "review")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.deckDueNotes.isEmpty)
            }

            Divider()

            if store.inboxNotes.isEmpty {
                ContentUnavailableView(
                    "Inbox empty", systemImage: "tray",
                    description: Text("New knowledge candidates appear here after analysis.")
                )
            } else {
                Text("Inbox — K keeps, D discards the first card")
                    .font(.headline)
                List(store.inboxNotes, id: \.id) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(note.topic).bold()
                            Spacer()
                            Button("Keep") { store.keep(note) }
                            Button("Discard") { store.discard(note) }
                        }
                        Text(note.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .onAppear { store.refresh() }
        // Single-keystroke triage of the top card (§5.1).
        .background {
            Group {
                Button("") { if let first = store.inboxNotes.first { store.keep(first) } }
                    .keyboardShortcut("k", modifiers: [])
                Button("") { if let first = store.inboxNotes.first { store.discard(first) } }
                    .keyboardShortcut("d", modifiers: [])
            }
            .opacity(0)
        }
    }
}

/// Minimal card session (design.md §5.2): question, reveal, grade 1–4.
/// Draws from the deck selected on the Cards tab.
struct ReviewSessionView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var revealed = false
    @State private var reviewedCount = 0

    var body: some View {
        VStack(spacing: 24) {
            if store.reviewDeck != .all {
                Text("Deck: \(store.reviewDeck.label)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let note = store.deckDueNotes.first, let qa = note.questionAnswer {
                Text(note.topic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(qa.question)
                    .font(.title3)
                    .multilineTextAlignment(.center)

                if revealed {
                    Divider().frame(width: 160)
                    Text(qa.answer)
                        .font(.body)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        gradeButton("Again", .again, "1")
                        gradeButton("Hard", .hard, "2")
                        gradeButton("Good", .good, "3")
                        gradeButton("Easy", .easy, "4")
                    }
                } else {
                    Button("Reveal") { revealed = true }
                        .keyboardShortcut(.space, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
                Text("\(store.deckDueNotes.count) left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView(
                    reviewedCount > 0 ? "Done — \(reviewedCount) reviewed" : "Nothing due",
                    systemImage: "checkmark.circle",
                    description: Text("Come back when notes are due.")
                )
            }
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { store.refresh() }
    }

    private func gradeButton(_ label: String, _ grade: FSRS.Grade, _ key: Character) -> some View {
        Button(label) {
            if let note = store.deckDueNotes.first {
                store.review(note, grade: grade)
                reviewedCount += 1
                revealed = false
            }
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }
}
