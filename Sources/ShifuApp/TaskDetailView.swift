import ShifuCore
import SwiftUI

/// One task as a full dashboard page (design.md §5.3): what the task *is*
/// (LLM gist), day-by-day history with the compiled work-note narratives
/// inline, where the time went, the knowledge notes captured under it, and
/// the raw recent activity. Rename and theme assignment live here too.
struct TaskDetailView: View {
    @EnvironmentObject private var store: LedgerStore
    let taskID: Int64

    @State private var detail: TaskStore.Detail?
    @State private var name = ""
    @State private var selectedHit: VaultSearch.Hit?
    @State private var askNewTheme = false
    @State private var newThemeName = ""

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Task not found", systemImage: "questionmark.folder",
                    description: Text("It may have been merged into another task."))
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $selectedHit) { hit in NoteReaderView(hit: hit) }
        .alert("New theme", isPresented: $askNewTheme) {
            TextField("Theme name", text: $newThemeName)
            Button("Create & Assign") {
                let trimmed = newThemeName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    store.createThemeAndAssign(taskID, themeName: trimmed)
                    reload()
                }
                newThemeName = ""
            }
            Button("Cancel", role: .cancel) { newThemeName = "" }
        }
    }

    private func reload() {
        detail = store.taskDetail(taskID)
        name = detail?.task.name ?? ""
    }

    private func content(_ detail: TaskStore.Detail) -> some View {
        List {
            Section {
                header(detail)
            }
            if !detail.days.isEmpty {
                Section("History") {
                    ForEach(detail.days) { day in
                        DayHistoryRow(day: day, taskKey: detail.task.key)
                    }
                }
            }
            if !detail.sources.isEmpty {
                Section("Where the time went") {
                    ForEach(detail.sources.prefix(8)) { share in
                        sourceRow(share)
                    }
                }
            }
            if !detail.notes.isEmpty {
                Section("Notes captured") {
                    ForEach(detail.notes) { note in
                        noteRow(note)
                    }
                }
            }
            if !detail.recent.isEmpty {
                Section("Recent activity") {
                    ForEach(detail.recent) { line in
                        activityRow(line)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(detail.task.name)
    }

    private func sourceRow(_ share: TaskStore.SourceShare) -> some View {
        HStack {
            Text(share.source)
            Spacer()
            Text(LedgerStore.hours(share.ms))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func noteRow(_ note: TaskStore.NoteLink) -> some View {
        Button {
            selectedHit = VaultSearch.Hit(
                noteID: note.noteID, path: note.path, kind: .knowledge,
                title: note.title, snippet: "",
                captured: note.captured.map {
                    Date(timeIntervalSince1970: Double($0) / 1_000)
                })
        } label: {
            HStack {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                Text(note.title)
                Spacer()
                if let captured = note.captured {
                    Text(Date(timeIntervalSince1970: Double(captured) / 1_000),
                         style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func header(_ detail: TaskStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Task name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit {
                        store.renameTask(taskID, to: name)
                        reload()
                    }
                Spacer()
                themeMenu(detail)
            }
            if let gist = detail.gist, !gist.isEmpty {
                Text(gist)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(LedgerStore.hours(detail.totalMs), systemImage: "clock")
                    .monospacedDigit()
                Label {
                    Text(Date(timeIntervalSince1970: Double(detail.task.lastActiveAt) / 1_000),
                         format: .relative(presentation: .named))
                } icon: {
                    Image(systemName: "sparkles")
                }
                Spacer()
                deckControl(detail)
                Button {
                    if let hit = store.latestWorkNote(taskID: taskID, title: detail.task.name) {
                        selectedHit = hit
                    }
                } label: {
                    Label("Latest work note", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The manual route to a deck (§5.2) — and the escape hatch from a
    /// dismissed or declined suggestion, which are otherwise permanent.
    /// Once a deck exists this becomes its live state: the card count is
    /// derived on every read, never stored, because review-time pruning would
    /// make a stored one wrong within a session.
    @ViewBuilder private func deckControl(_ detail: TaskStore.Detail) -> some View {
        if let deck = store.deck(taskKey: detail.task.key) {
            switch deck.status {
            case .ready:
                Label("Deck · \(deck.cardCount) cards", systemImage: "rectangle.stack")
            case .pending, .building:
                Label("Deck building…", systemImage: "rectangle.stack")
            }
        } else if store.hasLLMBackend {
            Button {
                store.createDeck(taskKey: detail.task.key, title: detail.task.name)
            } label: {
                Label("Create flashcard deck", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.borderless)
        } else {
            // Nothing could build the deck, and a pending one with no builder
            // would read as "Building…" forever.
            Label("Deck needs DeepSeek (Settings)", systemImage: "rectangle.stack")
        }
    }

    private func themeMenu(_ detail: TaskStore.Detail) -> some View {
        Menu(detail.themeName ?? "No theme") {
            Button("No theme") {
                store.assignTask(taskID, toTheme: nil)
                reload()
            }
            ForEach(store.themes) { theme in
                Button(theme.name) {
                    store.assignTask(taskID, toTheme: theme.key)
                    reload()
                }
            }
            Divider()
            Button("New theme…") { askNewTheme = true }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func activityRow(_ line: TaskStore.ActivityLine) -> some View {
        ActivityLineRow(line: line)
    }
}

/// One raw activity block: time · source · topic · category. Shared by the
/// task and theme detail pages.
struct ActivityLineRow: View {
    let line: TaskStore.ActivityLine

    var body: some View {
        HStack {
            Text(Date(timeIntervalSince1970: Double(line.startedAt) / 1_000),
                 format: .dateTime.day().month().hour().minute())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(line.source)
                .lineLimit(1)
            if let topic = line.topic {
                Text(topic)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(LedgerStore.hours(line.endedAt - line.startedAt))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(line.category)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

/// One history day: the compiled log line, expandable into the work note's
/// sessions and LLM narrative (vault-features.md §2.1) — the "what actually
/// happened" detail, inline instead of behind a file.
private struct DayHistoryRow: View {
    @EnvironmentObject private var store: LedgerStore
    let day: TaskStore.DayRow
    let taskKey: String

    @State private var expanded = false
    @State private var note: WorkNote?
    @State private var loaded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let note {
                VStack(alignment: .leading, spacing: 6) {
                    if !note.sessions.isEmpty {
                        Text(note.sessions.map { "\($0.start)–\($0.end)" }
                            .joined(separator: " · "))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let prose = note.sessionsProse, !prose.isEmpty {
                        ForEach(Array(prose.split(separator: "\n").enumerated()),
                                id: \.offset) { _, line in
                            Text(.init(String(line)))   // renders the **bold** bullets
                                .font(.callout)
                        }
                    } else {
                        Text("No narrative for this day.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    // The detailed tier's `## Notes` document (§2.1). Rendered
                    // through CardTextView so its `###` sub-headings are
                    // headings rather than literal hashes.
                    if let detail = note.detailProse, !detail.isEmpty {
                        Divider()
                        CardTextView(text: detail)
                    }
                }
                .padding(.leading, 4)
                .padding(.vertical, 2)
            } else if loaded {
                Text("No work note for this day.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(Date(timeIntervalSince1970: Double(day.dayStart) / 1_000),
                     format: .dateTime.weekday(.abbreviated).day().month())
                    .monospacedDigit()
                    .frame(width: 110, alignment: .leading)
                Text(day.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                Spacer()
                Text(LedgerStore.hours(day.durationMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: expanded) { _, isOpen in
            guard isOpen, !loaded else { return }
            // Deferred: this fires mid-expand, inside the backing table's
            // update pass — growing the row right here is a reentrant
            // table operation (AppKit warns, and will assert one day).
            Task { @MainActor in
                note = store.workNote(dayStart: day.dayStart, taskKey: taskKey)
                loaded = true
            }
        }
    }
}
