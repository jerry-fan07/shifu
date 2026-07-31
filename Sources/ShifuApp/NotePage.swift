import ShifuCore
import SwiftUI

/// The note page's sections, in the order they appear — the order the
/// questions actually arrive in. You read the note, then you want to know how
/// long it was and when; then what the machine saw underneath; then what else
/// that day held; then where this sits in the effort it belongs to.
enum NoteSection: String, CaseIterable, Identifiable {
    case note, stretches, underneath, related, sameDay, effort

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "The note"
        case .stretches: return "When"
        case .underneath: return "The day underneath"
        case .related: return "Captured here"
        case .sameDay: return "Also that day"
        case .effort: return "This effort"
        }
    }
}

// MARK: - A note's own contents

/// The source list while a note is open: the way back, the note's sections,
/// and the two collections it belongs to — its task and its theme, both
/// openable, because "which effort was this" is the question a remembered
/// fragment is usually a way of asking.
struct NoteContents: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let noteID: String

    @State private var dossier: VaultLibrary.Dossier?

    var body: some View {
        RailColumn {
            // Back to wherever the note was opened *from*, not always Notes:
            // the task page and the theme page both link into notes now, and
            // hardcoding the target would strand you a place you never were.
            RailBack(title: router.place.title) { router.close() }
            RailHeading("This note")
            ForEach(NoteSection.allCases) { section in
                if let badge = badge(for: section) {
                    RailRow(title: section.title, badge: badge.isEmpty ? nil : badge) {
                        router.scroll(to: section.rawValue)
                    }
                }
            }
            if let entry = dossier?.entry {
                RailHeading("Collections")
                    .padding(.top, 14)
                if let taskID = entry.taskID, let name = entry.taskName {
                    RailRow(title: name, badge: "task") { router.open(.task(taskID)) }
                }
                // A task named after its theme is the common case; listing
                // both then reads as the same row printed twice.
                if let themeName = entry.themeName, let themeKey = entry.themeKey,
                   themeName != entry.taskName {
                    RailRow(title: themeName, badge: "theme") { open(themeKey: themeKey) }
                }
                if let overview = dossier?.overview {
                    RailRow(title: "Overview", badge: "doc") {
                        router.open(.note(overview.noteID))
                    }
                }
            }
        } footer: {
            Button("Reveal in Finder") {
                guard let path = dossier?.entry.path else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [ShifuPaths.vault.appendingPathComponent(path)])
            }
            .buttonStyle(.plain)
            .font(Instrument.sans(11.5))
            .foregroundStyle(Instrument.railInk)
            Text("Notes are plain Markdown. Edit them anywhere; Shifu re-reads the file.")
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.ghost)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onChange(of: noteID) { _, _ in reload() }
    }

    private func reload() { dossier = store.dossier(noteID: noteID) }

    /// Themes route by id, and the note only knows the key.
    private func open(themeKey: String) {
        guard let theme = store.themes.first(where: { $0.key == themeKey }) else { return }
        router.open(.theme(theme.id))
    }

    /// Nil hides the row entirely: a rail that lists five empty sections is a
    /// worse map than one that lists the two this note actually has.
    private func badge(for section: NoteSection) -> String? {
        guard let dossier else { return section == .note ? "" : nil }
        switch section {
        case .note: return ""
        case .stretches: return dossier.stretches.isEmpty ? nil : "\(dossier.stretches.count)"
        case .underneath: return dossier.blocks.isEmpty ? nil : "\(dossier.blocks.count)"
        case .related: return dossier.related.isEmpty ? nil : "\(dossier.related.count)"
        case .sameDay: return dossier.sameDay.isEmpty ? nil : "\(dossier.sameDay.count)"
        case .effort: return dossier.timeline.isEmpty ? nil : "\(dossier.timeline.count)"
        }
    }
}

// MARK: - The page

/// One note, with everything around it (`VaultLibrary.Dossier`).
///
/// A note on its own is a paragraph with a date on it. What turns the vault
/// into a memory is the second question, which is always the same one: *what
/// was I doing?* So the page reads the note and then keeps going — the exact
/// wall-clock stretches, the raw blocks underneath while they still exist,
/// what else that day held, and the same effort's notes before and after it.
struct NotePage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let noteID: String

    @State private var dossier: VaultLibrary.Dossier?
    @State private var loaded = false

    var body: some View {
        Group {
            if let dossier {
                page(dossier)
            } else if loaded {
                PageHead(
                    "Note not found",
                    subtitle: "The file may have been deleted or moved out of the vault.")
            } else {
                Color.clear
            }
        }
        .onAppear(perform: reload)
        .onChange(of: noteID) { _, _ in reload() }
    }

    private func reload() {
        dossier = store.dossier(noteID: noteID)
        loaded = true
    }

    private func page(_ dossier: VaultLibrary.Dossier) -> some View {
        VStack(spacing: 0) {
            header(dossier.entry)
            SectionScroll {
                PageBody {
                    note(dossier)
                    stretches(dossier)
                    related(dossier)
                    underneath(dossier)
                    sameDay(dossier)
                    effort(dossier)
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ entry: VaultLibrary.Entry) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(Instrument.sans(21, .semibold))
                    .tracking(-0.31)
                    .foregroundStyle(Instrument.ink)
                    .frame(maxWidth: 720, alignment: .leading)
                HStack(spacing: 14) {
                    Tag(entry.kindLabel)
                    if entry.depth == .trace { Tag("trace", dashed: true) }
                    if let captured = entry.captured {
                        Figure(
                            captured.formatted(
                                .dateTime.weekday(.wide).day().month(.wide).year()),
                            size: 11.5, color: Instrument.muted)
                    }
                    if let ms = entry.durationMs, ms > 0 {
                        Figure(TimeBreakdown.duration(ms), size: 11.5, color: Instrument.muted)
                    }
                    Figure("\(entry.words) words", size: 11.5, color: Instrument.faint)
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

    // MARK: - Sections

    @ViewBuilder private func note(_ dossier: VaultLibrary.Dossier) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let body = dossier.body, !body.isEmpty {
                CardTextView(text: body, baseSize: 13)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.top, 14)
            } else {
                BlankSlate(
                    "The note file is gone — it may have been moved or deleted. "
                        + "Everything below is still known from the index.")
            }
            if dossier.entry.depth == .trace {
                QuietLine {
                    Text("This is a trace: the task-day was too short, or too quiet, "
                        + "for the analyzer to write it up. The times and sources below "
                        + "are still exact.")
                }
                .frame(maxWidth: 660, alignment: .leading)
            }
        }
        .sectionAnchor(NoteSection.note.rawValue)
    }

    @ViewBuilder private func stretches(_ dossier: VaultLibrary.Dossier) -> some View {
        if !dossier.stretches.isEmpty || !dossier.sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeading("When")
                if !dossier.stretches.isEmpty {
                    // Wall clock, not timestamps: these are written into the
                    // Markdown for a human, and they outlive the raw blocks.
                    Figure(
                        dossier.stretches.map { "\($0.start)–\($0.end)" }
                            .joined(separator: "   ·   "),
                        size: 12.5, color: Instrument.body)
                }
                if !dossier.sources.isEmpty {
                    Text(dossier.sources.joined(separator: " · "))
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.muted)
                        .frame(maxWidth: 660, alignment: .leading)
                }
            }
            .padding(.bottom, 4)
            .sectionAnchor(NoteSection.stretches.rawValue)
        }
    }

    /// The blocks the note was compiled from. Empty once the day falls out of
    /// the observation retention window (design.md §3.5), which is not a
    /// fault: the note is the durable record, the blocks never were.
    @ViewBuilder private func underneath(_ dossier: VaultLibrary.Dossier) -> some View {
        if !dossier.blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading("The day underneath")
                Text("The raw blocks this was compiled from, while they last.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                    .padding(.bottom, 4)
                ForEach(dossier.blocks) { line in
                    Rule()
                    ActivityLineRow(line: line)
                }
            }
            .sectionAnchor(NoteSection.underneath.rawValue)
        }
    }

    @ViewBuilder private func related(_ dossier: VaultLibrary.Dossier) -> some View {
        if !dossier.related.isEmpty {
            linkList(
                title: dossier.entry.kind == .knowledge ? "Where this came from"
                    : "Captured here",
                caption: dossier.entry.kind == .knowledge
                    ? "The work note for the day this was captured."
                    : "The cards this day's work produced.",
                entries: dossier.related,
                anchor: NoteSection.related.rawValue)
        }
    }

    @ViewBuilder private func sameDay(_ dossier: VaultLibrary.Dossier) -> some View {
        if !dossier.sameDay.isEmpty {
            linkList(
                title: "Also that day",
                caption: "Everything else the vault kept from the same day, "
                    + "longest first.",
                entries: dossier.sameDay,
                showsDate: false,
                anchor: NoteSection.sameDay.rawValue)
        }
    }

    @ViewBuilder private func effort(_ dossier: VaultLibrary.Dossier) -> some View {
        if !dossier.timeline.isEmpty {
            linkList(
                title: "This effort",
                caption: effortCaption(dossier),
                entries: dossier.timeline,
                anchor: NoteSection.effort.rawValue)
        }
    }

    private func effortCaption(_ dossier: VaultLibrary.Dossier) -> String {
        let name = dossier.entry.taskName ?? "this task"
        guard dossier.taskDayCount > 0 else { return "The rest of \(name)." }
        return "\(name) — \(TimeBreakdown.duration(dossier.taskTotalMs)) across "
            + "\(dossier.taskDayCount) day\(dossier.taskDayCount == 1 ? "" : "s")."
    }

    private func linkList(
        title: String, caption: String, entries: [VaultLibrary.Entry],
        showsDate: Bool = true, anchor: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title)
            Text(caption)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.ghost)
                .padding(.bottom, 4)
            ForEach(entries) { entry in
                Rule()
                NoteLinkRow(entry: entry, showsDate: showsDate) {
                    router.open(.note(entry.noteID))
                }
            }
        }
        .sectionAnchor(anchor)
    }
}

// MARK: - Pieces

/// A section's name on a detail page — the eyebrow with the spacing that keeps
/// sections from running into each other.
struct SectionHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Eyebrow(text)
            .padding(.top, 20)
            .padding(.bottom, 5)
    }
}

/// One note as a link from another note: enough to decide whether to follow
/// it, and no more.
struct NoteLinkRow: View {
    let entry: VaultLibrary.Entry
    /// Off for a list that is already one day — a column of the same date
    /// eleven times says nothing.
    var showsDate = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if showsDate {
                    Figure(dateLabel, size: 11.5, color: Instrument.faint)
                        .frame(width: 76, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.ink)
                        .lineLimit(1)
                    if !entry.summary.isEmpty, entry.summary != entry.title {
                        Text(entry.summary)
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(Instrument.ghost)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.kindLabel)
                    .font(Instrument.sans(11))
                    .foregroundStyle(Instrument.muted)
                    .frame(width: 74, alignment: .trailing)
                Figure(
                    entry.durationMs.map { TimeBreakdown.duration($0) } ?? "",
                    size: 11.5, color: Instrument.muted)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dateLabel: String {
        entry.captured?.formatted(.dateTime.day().month(.abbreviated)) ?? "—"
    }
}
