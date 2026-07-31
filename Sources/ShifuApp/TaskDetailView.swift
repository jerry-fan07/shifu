import ShifuCore
import SwiftUI

/// The task page's sections, in the order they appear. The source list lists
/// these and scrolls to them; the page anchors them by the same raw value.
enum TaskSection: String, CaseIterable, Identifiable {
    case history, sources, notes, raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .sources: return "Where the time went"
        case .notes: return "Notes"
        case .raw: return "Raw activity"
        }
    }
}

// MARK: - A task's own contents

/// The source list while a task is open: the way back, the task's sections,
/// the theme its time is filed under (changeable here, because this is the one
/// screen where you know enough to change it), and the two things you can do
/// to the task itself.
struct TaskContents: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let taskID: Int64

    @State private var detail: TaskStore.Detail?
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        RailColumn {
            RailBack(title: "Tasks") { router.go(to: .tasks) }
            RailHeading("This task")
            ForEach(TaskSection.allCases) { section in
                RailRow(title: section.title, badge: badge(for: section)) {
                    router.scroll(to: section.rawValue)
                }
            }
            RailHeading("Theme")
                .padding(.top, 14)
            themeMenu
            if let detail {
                Text("All \(TimeBreakdown.duration(detail.totalMs)) of this task's time "
                    + "is filed \(detail.themeName == nil ? "nowhere" : "here").")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.top, 4)
            }
        } footer: {
            Button("Rename task") {
                draftName = detail?.task.name ?? ""
                renaming = true
            }
            .buttonStyle(.plain)
            .font(Instrument.sans(11.5))
            .foregroundStyle(Instrument.railInk)
            deckControl
        }
        .onAppear(perform: reload)
        .onChange(of: taskID) { _, _ in reload() }
        .alert("Rename task", isPresented: $renaming) {
            TextField("Task name", text: $draftName)
            Button("Rename") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    store.renameTask(taskID, to: trimmed)
                    reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func reload() { detail = store.taskDetail(taskID) }

    private func badge(for section: TaskSection) -> String? {
        switch section {
        case .notes:
            let count = detail?.notes.count ?? 0
            return count > 0 ? "\(count)" : nil
        default:
            return nil
        }
    }

    /// The task's theme, and the menu to move it. What it shows is where the
    /// task's time mostly sits — picking one here files *all* of its blocks
    /// there, so the label always matches what was chosen.
    private var themeMenu: some View {
        DropdownButton(
            label: detail?.themeName ?? "No theme",
            bordered: false,
            font: Instrument.sans(13),
            color: Instrument.ink,
            entries: themeEntries)
            // The rail's own indent, applied outside the control so the panel
            // still hangs off the word rather than the whole row.
            .padding(.horizontal, 22)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var themeEntries: [DropdownEntry] {
        let current = detail?.themeName
        return [DropdownEntry("No theme", isOn: current == nil) {
            store.assignTask(taskID, toTheme: nil)
            reload()
        }] + store.themes.map { theme in
            DropdownEntry(theme.name, isOn: theme.name == current) {
                store.assignTask(taskID, toTheme: theme.key)
                reload()
            }
        }
    }

    /// The manual route to a deck (§5.2), and the escape hatch from a
    /// dismissed suggestion, which is otherwise permanent. The task page is
    /// the only screen that knows enough to offer it.
    @ViewBuilder private var deckControl: some View {
        if let detail {
            if let deck = store.deck(taskKey: detail.task.key) {
                Text(deck.status == .ready
                    ? "Deck · \(deck.cardCount) cards"
                    : "Deck building…")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
            } else if store.hasLLMBackend {
                Button("Make a deck from this") {
                    store.createDeck(taskKey: detail.task.key, title: detail.task.name)
                }
                .buttonStyle(.plain)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.accentText)
            } else {
                // Nothing could build the deck, and a pending one with no
                // builder would read as "Building…" forever.
                Text("A deck needs DeepSeek (Settings)")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The task page

/// One task as a page (design.md §5.3): what it is, then the day-by-day
/// history with the most recent day's narrative already open, then what the
/// time was made of and what it left behind.
struct TaskPage: View {
    @EnvironmentObject private var store: LedgerStore
    let taskID: Int64

    @State private var detail: TaskStore.Detail?
    @State private var reading: VaultSearch.Hit?

    var body: some View {
        Group {
            if let detail {
                page(detail)
            } else {
                PageHead(
                    "Task not found",
                    subtitle: "It may have been merged into another task.")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: taskID) { _, _ in reload() }
        .sheet(item: $reading) { hit in NoteReaderView(hit: hit) }
    }

    private func reload() { detail = store.taskDetail(taskID) }

    private func page(_ detail: TaskStore.Detail) -> some View {
        VStack(spacing: 0) {
            header(detail)
            SectionScroll {
                PageBody {
                    history(detail)
                    columns(detail)
                    raw(detail)
                }
            }
        }
    }

    private func header(_ detail: TaskStore.Detail) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(detail.task.name)
                        .font(Instrument.sans(21, .semibold))
                        .tracking(-0.31)
                        .foregroundStyle(Instrument.ink)
                    Spacer(minLength: 0)
                    InlineLink("Latest work note") {
                        reading = store.latestWorkNote(
                            taskID: taskID, title: detail.task.name)
                    }
                }
                if let gist = detail.gist, !gist.isEmpty {
                    Text(gist)
                        .font(Instrument.sans(13))
                        .foregroundStyle(Instrument.secondary)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.top, 4)
                }
                HStack(spacing: 18) {
                    Figure("\(TimeBreakdown.duration(detail.totalMs)) total",
                           size: 11.5, color: Instrument.muted)
                    if let today = detail.days.first, isToday(today.dayStart) {
                        Figure("\(TimeBreakdown.duration(today.durationMs)) today",
                               size: 11.5, color: Instrument.muted)
                    }
                    Figure("\(detail.days.count) day\(detail.days.count == 1 ? "" : "s")",
                           size: 11.5, color: Instrument.muted)
                    Figure(
                        "last active " + Date(
                            timeIntervalSince1970: Double(detail.task.lastActiveAt) / 1_000)
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

    private func isToday(_ dayStart: Int64) -> Bool {
        Calendar.current.isDateInToday(
            Date(timeIntervalSince1970: Double(dayStart) / 1_000))
    }

    // MARK: - History

    @ViewBuilder private func history(_ detail: TaskStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("History")
                .padding(.top, 14)
                .padding(.bottom, 6)
            if detail.days.isEmpty {
                BlankSlate("No day has been compiled for this task yet.")
            } else {
                ForEach(Array(detail.days.enumerated()), id: \.element.id) { index, day in
                    Rule()
                    DayHistoryRow(
                        day: day, taskKey: detail.task.key,
                        // The newest day is the reason the page was opened;
                        // it opens with it already unrolled.
                        startsOpen: index == 0)
                }
            }
        }
        .sectionAnchor(TaskSection.history.rawValue)
    }

    // MARK: - What it was made of

    private func columns(_ detail: TaskStore.Detail) -> some View {
        HStack(alignment: .top, spacing: 40) {
            sourcesColumn(detail)
            notesColumn(detail)
        }
        .padding(.top, 16)
    }

    private func sourcesColumn(_ detail: TaskStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Where the time went")
                .padding(.bottom, 5)
            ForEach(detail.sources.prefix(6)) { share in
                Rule()
                HStack {
                    Text(share.source)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.ink)
                        .lineLimit(1)
                    Spacer()
                    Figure(TimeBreakdown.duration(share.ms), color: Instrument.muted)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionAnchor(TaskSection.sources.rawValue)
    }

    private func notesColumn(_ detail: TaskStore.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Notes captured")
                .padding(.bottom, 5)
            if detail.notes.isEmpty {
                Text("Nothing kept from this task yet.")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
                    .padding(.vertical, 4)
            }
            ForEach(detail.notes.prefix(6)) { note in
                Rule()
                noteRow(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionAnchor(TaskSection.notes.rawValue)
    }

    private func noteRow(_ note: TaskStore.NoteLink) -> some View {
        Button {
            reading = VaultSearch.Hit(
                noteID: note.noteID, path: note.path, kind: .knowledge,
                title: note.title, snippet: "",
                captured: note.captured.map {
                    Date(timeIntervalSince1970: Double($0) / 1_000)
                })
        } label: {
            HStack {
                Text(note.title)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.ink)
                    .lineLimit(1)
                Spacer()
                if let captured = note.captured {
                    Figure(
                        Date(timeIntervalSince1970: Double(captured) / 1_000)
                            .formatted(.dateTime.day().month(.abbreviated)),
                        size: 11, color: Instrument.faint)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Raw activity

    @ViewBuilder private func raw(_ detail: TaskStore.Detail) -> some View {
        if !detail.recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Raw activity")
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                ForEach(detail.recent) { line in
                    Rule()
                    ActivityLineRow(line: line)
                }
            }
            .sectionAnchor(TaskSection.raw.rawValue)
        }
    }
}

/// One raw block: when, where, what, and under which category. Shared by the
/// task and theme pages.
struct ActivityLineRow: View {
    let line: TaskStore.ActivityLine

    /// "Jul 30 10:11 AM". Built from two formats rather than one: the single
    /// combined style renders as "Jul 30 at 10:11 AM", which wraps the column.
    private var when: String {
        let date = Date(timeIntervalSince1970: Double(line.startedAt) / 1_000)
        return date.formatted(.dateTime.month(.abbreviated).day())
            + " " + date.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        HStack(spacing: 12) {
            Figure(when, size: 11.5, color: Instrument.faint)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            Text(line.topic.map { "\(line.source) — \($0)" } ?? line.source)
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure(TimeBreakdown.duration(line.endedAt - line.startedAt),
                   color: Instrument.muted)
                .frame(width: 72, alignment: .trailing)
            Text(line.category)
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.muted)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

/// One history day: the compiled log line, unrolled into the work note's
/// sessions and narrative (vault-features.md §2.1). The narrative is the point
/// of the page, so it is inline rather than behind a file.
private struct DayHistoryRow: View {
    @EnvironmentObject private var store: LedgerStore
    let day: TaskStore.DayRow
    let taskKey: String
    var startsOpen = false

    @State private var expanded = false
    @State private var note: WorkNote?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Figure(
                        Date(timeIntervalSince1970: Double(day.dayStart) / 1_000)
                            .formatted(.dateTime.weekday(.abbreviated).day().month()),
                        color: Instrument.faint)
                        .frame(width: 96, alignment: .leading)
                    Text(day.summary)
                        .font(Instrument.sans(12.5, expanded ? .medium : .regular))
                        .foregroundStyle(expanded ? Instrument.ink : Instrument.body)
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Figure(TimeBreakdown.duration(day.durationMs), color: Instrument.muted)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Only once the note has been read: an expanded row with nothing
            // in it yet is a blank gap the eye reads as a rendering fault.
            if expanded, loaded { narrative }
        }
        .onAppear {
            guard startsOpen, !expanded else { return }
            expanded = true
        }
        .onChange(of: expanded) { _, isOpen in
            guard isOpen, !loaded else { return }
            // Deferred: this can fire mid-layout, and loading the note here
            // republishes state the enclosing stack is still laying out.
            Task { @MainActor in
                note = store.workNote(dayStart: day.dayStart, taskKey: taskKey)
                loaded = true
            }
        }
    }

    @ViewBuilder private var narrative: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let note {
                if !note.sessions.isEmpty {
                    Figure(
                        note.sessions.map { "\($0.start)–\($0.end)" }
                            .joined(separator: " · "),
                        size: 11, color: Instrument.faint)
                }
                if let prose = note.sessionsProse, !prose.isEmpty {
                    ForEach(Array(prose.split(separator: "\n").enumerated()),
                            id: \.offset) { _, line in
                        Text(.init(String(line)))   // renders the **bold** lead-ins
                            .font(Instrument.sans(12.5))
                            .lineSpacing(3)
                            .foregroundStyle(Instrument.body)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                }
                if let extra = note.detailProse, !extra.isEmpty {
                    CardTextView(text: extra, baseSize: 12.5)
                        .frame(maxWidth: 620, alignment: .leading)
                        .padding(.top, 2)
                }
            } else if loaded {
                Text("No work note for this day.")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.ghost)
            }
        }
        .padding(.leading, 110)
        .padding(.bottom, 8)
    }
}
