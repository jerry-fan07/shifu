import ShifuCore
import SwiftUI

/// Navigation value for pushing a theme page — distinct from the bare Int64
/// used for task pages, so one NavigationStack can route both.
struct ThemeRoute: Hashable {
    let id: Int64
}

/// The Vault tab's *Themes* mode (design.md §5.3): the user's broad ongoing
/// initiatives, most recently active first, laid out as a grid of cards
/// rather than a vertical list.
///
/// Every theme here is one the user made — by hand, or by accepting one of the
/// clusterer's proposals, which sit in their own section *below* the grid.
/// Nothing crosses that line on its own.
struct ThemeListView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var editing: ThemeStore.Overview?
    @State private var isCreating = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your themes")
                    .font(.headline)
                Spacer()
                Button("New Theme", systemImage: "plus") { isCreating = true }
                    .help("Themes are yours to create — Shifu only files time into them")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            grid
        }
        .background(Dojo.paper)
        .navigationTitle("Themes")
        .sheet(isPresented: $isCreating) { ThemeEditSheet(theme: nil) }
        .sheet(item: $editing) { ThemeEditSheet(theme: $0) }
        .onAppear { store.refresh() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.themes) { theme in
                    themeCell(theme)
                }
            }
            .padding(16)
            if !store.themeProposals.isEmpty {
                Divider()
                suggested
            }
        }
        // Overlaid rather than placed inside the grid so it centers in the
        // full content area instead of hugging the top-leading corner.
        .overlay {
            if store.themes.isEmpty && store.themeProposals.isEmpty {
                SenseiEmptyState(
                    "No themes yet",
                    message: "Themes are the broad initiatives you want your time "
                        + "grouped under — \"YC Startup School\", \"Travel\". Name the "
                        + "ones you care about; I will file your hours into them, and "
                        + "suggest others I notice."
                ) {
                    Button("New Theme") { isCreating = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// The card, plus its edit button layered *over* the navigation link
    /// rather than inside it — a button nested in a NavigationLink's label
    /// doesn't reliably get the click on macOS. Deleting lives one level in,
    /// in the edit sheet, so there is a single confirmed path to it.
    private func themeCell(_ theme: ThemeStore.Overview) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: ThemeRoute(id: theme.id)) {
                ThemeCardView(theme: theme)
            }
            .buttonStyle(.plain)
            Button {
                editing = theme
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename, describe, or delete this theme")
            .padding(6)
        }
    }

    /// The clusterer's proposals (design.md §5.3). Deliberately below the
    /// grid, visually distinct, and never counted as themes: this is the
    /// model's opinion of what the user is up to, waiting for a yes.
    private var suggested: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggested themes · \(store.themeProposals.count)")
                    .font(.headline)
                Spacer()
                Button("Dismiss all", action: store.dismissAllThemeProposals)
                    .buttonStyle(.link)
                    .help("Clears these for good — a dismissed suggestion never comes back")
            }
            Text("Initiatives Shifu noticed in your time. Adding one creates the theme "
                + "and files the blocks behind it; nothing is added on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.themeProposals) { proposal in
                    ProposalCardView(proposal: proposal)
                }
            }
        }
        .padding(16)
    }
}

/// One theme as a rectangular card in the Themes grid: name, gist, and
/// time footer, uniform height so the grid reads as tiles.
private struct ThemeCardView: View {
    let theme: ThemeStore.Overview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(theme.name)
                .font(.headline)
                .lineLimit(2)
                // Room for the edit menu sitting in the corner above.
                .padding(.trailing, 20)
            if let gist = theme.gist, !gist.isEmpty {
                Text(gist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(LedgerStore.hours(theme.totalMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                if theme.weekMs > 0 {
                    Text("\(LedgerStore.hours(theme.weekMs)) this week")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .dojoCard(padding: 12)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// One suggestion, shaped like a theme card so the two read as the same kind
/// of thing — but dashed and unfilled, because it isn't one yet. The evidence
/// line is the whole argument for saying yes: how much time is already behind
/// this idea.
private struct ProposalCardView: View {
    @EnvironmentObject private var store: LedgerStore
    let proposal: ThemeProposals.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proposal.name)
                .font(.headline)
                .lineLimit(2)
            if let gist = proposal.gist, !gist.isEmpty {
                Text(gist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Text("\(LedgerStore.hours(proposal.totalMs)) across "
                + "\(proposal.blockCount) block\(proposal.blockCount == 1 ? "" : "s")")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            HStack {
                Button("Add") { store.acceptThemeProposal(proposal) }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { store.dismissThemeProposal(proposal) }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Dojo.accent.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

/// Create a theme, or edit the name and gist of one. Both live in one sheet:
/// the fields are identical, and the only difference is whether there is a
/// row behind them to delete.
struct ThemeEditSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    /// nil when creating.
    let theme: ThemeStore.Overview?

    @State private var name: String
    @State private var gist: String
    @State private var confirmingDelete = false

    init(theme: ThemeStore.Overview?) {
        self.theme = theme
        _name = State(initialValue: theme?.name ?? "")
        _gist = State(initialValue: theme?.gist ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(theme == nil ? "New theme" : "Edit theme")
                .font(.title3)
                .bold()
            field("Name", prompt: "YC Startup School", text: $name)
            field("Description (optional)", prompt: "Program sessions, applications, "
                + "and everything around them.", text: $gist)
            Text(theme == nil
                ? "Shifu will file matching time into this theme from the next "
                    + "analysis run on."
                : "Renaming keeps the theme's history — its time stays filed here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            footer
        }
        .padding(20)
        .frame(minWidth: 420)
        .confirmationDialog(
            "Delete \"\(theme?.name ?? "")\"?", isPresented: $confirmingDelete
        ) {
            Button("Delete theme", role: .destructive) {
                if let theme { store.deleteTheme(theme.id) }
                dismiss()
            }
        } message: {
            Text("The time stays in your ledger — it just stops being filed under "
                + "this theme, and Shifu won't suggest it again.")
        }
    }

    private func field(
        _ label: String, prompt: String, text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack {
            if theme != nil {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(theme == nil ? "Create" : "Save") {
                if let theme {
                    store.updateTheme(theme.id, name: name, gist: gist)
                } else {
                    store.createTheme(named: name, gist: gist)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(trimmedName.isEmpty)
        }
    }
}

/// One theme as a full page: the running narrative, day-by-day history,
/// the tasks the theme's time flowed through (each links to its task page),
/// and recent raw activity.
struct ThemeDetailView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let themeID: Int64

    @State private var detail: ThemeStore.Detail?
    @State private var name = ""
    @State private var editing: ThemeStore.Overview?

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else {
                ContentUnavailableView("Theme not found", systemImage: "questionmark.square")
            }
        }
        .sheet(item: $editing, onDismiss: reload) { ThemeEditSheet(theme: $0) }
        .onAppear(perform: reload)
    }

    private func reload() {
        detail = store.themeDetail(themeID)
        name = detail?.overview.name ?? ""
        // Deleted from the edit sheet: there is no page left to stand on.
        if detail == nil { dismiss() }
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
        .toolbar {
            Button("Edit", systemImage: "pencil") { editing = detail.overview }
        }
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
