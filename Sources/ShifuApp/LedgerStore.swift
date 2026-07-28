import Combine
import Foundation
import ShifuCore

/// Read-side model for the menu bar and dashboard. The app owns nothing
/// critical (design.md §2.2) — it reads the same DB and control files the
/// daemon writes.
/// Note: ObservableObject rather than @Observable — the @Observable macro's
/// expansion references the `Observation` *module*, which our `Observation`
/// model type shadows.
@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var todayTotals: [ShifuCore.Category: Int64] = [:]
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var workModeOn = false
    @Published private(set) var inboxNotes: [Note] = []
    @Published private(set) var dueNotes: [Note] = []
    @Published private(set) var suggestions: [Suggestion] = []
    /// The unfiltered task roster. The Cards tab's deck picker reads this, so
    /// narrowing the Vault tab's list must never touch it — hence the separate
    /// `filteredTasks` below.
    @Published private(set) var recentTasks: [TaskStore.Overview] = []
    /// The Task log's list, narrowed by `taskFilter` and capped at
    /// `taskListLimit`.
    @Published private(set) var filteredTasks: [TaskStore.Overview] = []
    /// How many tasks the filter admits before that cap — see `taskCountLabel`.
    @Published private(set) var matchingTaskCount = 0
    @Published var taskFilter = TaskListFilter()

    /// Rows the Task log renders at once. Every row carries an editable name
    /// field and a project menu, so this is a rendering budget, not a data one.
    static let taskListLimit = 50
    @Published private(set) var mergeSuggestions: [TaskMerges.Pending] = []
    @Published private(set) var projectSuggestions: [TaskMerges.PendingProject] = []

    /// Created once; nil when the OS has no sentence model (search stays
    /// bm25-only, silently — vault-features.md §4).
    private let embedder = SentenceEmbedder()
    @Published private(set) var todayLogs: [TaskStore.DayLogEntry] = []
    @Published private(set) var projectSummaries: [TaskStore.ProjectSummary] = []
    @Published private(set) var themes: [ThemeStore.Overview] = []
    @Published var reviewDeck: ReviewDeck = .all
    @Published var vaultQuery = ""
    @Published private(set) var vaultHits: [VaultSearch.Hit] = []
    @Published private(set) var lastError: String?

    private var vault: VaultStore { VaultStore(database: try? db()) }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    private var database: ShifuDatabase?
    private var analyzerProcess: Process?
    private var lastAnalyzerRun = Date.distantPast

    private func db() throws -> ShifuDatabase {
        if let database { return database }
        try ShifuPaths.ensureHomeExists()
        let opened = try ShifuDatabase.open(at: ShifuPaths.database)
        database = opened
        return opened
    }

    func refresh() {
        if let raw = try? String(contentsOf: ShifuPaths.pauseFile, encoding: .utf8),
           let expiry = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           Date(timeIntervalSince1970: expiry) > Date() {
            pausedUntil = Date(timeIntervalSince1970: expiry)
        } else {
            pausedUntil = nil
        }
        workModeOn = FileManager.default.fileExists(atPath: ShifuPaths.workModeFile.path)
        inboxNotes = (try? vault.inbox()) ?? []
        dueNotes = (try? vault.due()) ?? []
        suggestions = (try? db()).flatMap { try? Radar.active(database: $0) } ?? []
        if let database = try? db() {
            let dayStart = Int64(
                Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
            recentTasks = (try? TaskStore.recentTasks(database: database)) ?? []
            loadTasks()
            mergeSuggestions = (try? TaskMerges.pending(database: database)) ?? []
            projectSuggestions = (try? TaskMerges.pendingProjects(database: database)) ?? []
            todayLogs = (try? TaskStore.logs(dayStart: dayStart, database: database)) ?? []
            projectSummaries = (try? TaskStore.projects(database: database)) ?? []
            themes = (try? ThemeStore.overviews(database: database)) ?? []
        }
        do {
            let start = Calendar.current.startOfDay(for: Date())
            todayTotals = try LedgerBuilder.totals(
                database: db(),
                from: Int64(start.timeIntervalSince1970 * 1_000),
                to: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// Kicks shifu-analyzer on demand so the summary covers up to right now,
    /// then refreshes once it exits. Throttled so reopening the menu doesn't
    /// stack runs; concurrent with shifud's hourly run is fine (idempotent).
    func runAnalysis() {
        if let existing = analyzerProcess, existing.isRunning { return }
        guard Date().timeIntervalSince(lastAnalyzerRun) > 60 else { return }
        let analyzerURL = ShifuPaths.home
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("shifu-analyzer")
        guard FileManager.default.isExecutableFile(atPath: analyzerURL.path) else { return }
        let process = Process()
        process.executableURL = analyzerURL
        process.arguments = ["--force"]  // user-initiated: don't skip on battery
        process.qualityOfService = .utility
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        do {
            try process.run()
            analyzerProcess = process
            lastAnalyzerRun = Date()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Time-tab rows with task/theme names resolved for the breakdown lenses.
    func labeledActivities(from: Date, to: Date) -> [LedgerBuilder.LabeledActivity] {
        guard let database = try? db() else { return [] }
        return (try? LedgerBuilder.labeledActivities(
            database: database,
            from: Int64(from.timeIntervalSince1970 * 1_000),
            to: Int64(to.timeIntervalSince1970 * 1_000))) ?? []
    }

    // MARK: - Pause (same control file as the CLI)

    func pause(until: Date) {
        try? ShifuPaths.ensureHomeExists()
        try? String(Int(until.timeIntervalSince1970))
            .write(to: ShifuPaths.pauseFile, atomically: true, encoding: .utf8)
        refresh()
    }

    func resume() {
        try? FileManager.default.removeItem(at: ShifuPaths.pauseFile)
        refresh()
    }

    // MARK: - Vault (triage + review)

    func keep(_ note: Note) {
        try? vault.keep(note)
        refresh()
    }

    func discard(_ note: Note) {
        try? vault.discard(note)
        refresh()
    }

    func review(_ note: Note, grade: FSRS.Grade) {
        _ = try? vault.review(note, grade: grade)
        refresh()
    }

    // MARK: - Vault search (vault-features.md §4)

    func searchVault() {
        guard let database = try? db(),
              !vaultQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            vaultHits = []
            return
        }
        vaultHits = (try? VaultSearch.search(
            vaultQuery, database: database, embedder: embedder)) ?? []
    }

    /// The note file behind a search hit, split for display. Nil if the file
    /// vanished since indexing (next reconcile cleans the row up).
    func noteDocument(for hit: VaultSearch.Hit) -> FrontMatter.Document? {
        let file = ShifuPaths.vault.appendingPathComponent(hit.path)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return FrontMatter.parse(text)
    }

    func noteFileURL(for hit: VaultSearch.Hit) -> URL {
        ShifuPaths.vault.appendingPathComponent(hit.path)
    }

    /// The task's most recent work note (vault-features.md §2.1) as a search
    /// hit, so the Vault tab's rows open in the same note reader.
    func latestWorkNote(taskID: Int64, title: String) -> VaultSearch.Hit? {
        guard let database = try? db() else { return nil }
        return (try? VaultSearch.latest(
            kind: .work, taskID: taskID, title: title, database: database)) ?? nil
    }

    // MARK: - Tasks & projects (design.md §5.3)

    /// Re-runs just the Task log's list. Cheap enough to call on every filter
    /// change — `refresh()` would re-read the whole dashboard for nothing.
    /// `since` is recomputed here rather than stored, so a window left open
    /// past midnight rolls over with the day.
    func loadTasks() {
        guard let database = try? db() else { return }
        let filter = taskFilter.core(limit: Self.taskListLimit)
        filteredTasks = (try? TaskStore.recentTasks(
            database: database, filter: filter)) ?? []
        matchingTaskCount = (try? TaskStore.matchingTaskCount(
            database: database, filter: filter)) ?? filteredTasks.count
    }

    /// "12 tasks", or "50 of 364" when the cap is hiding the rest — without
    /// this a capped, recency-sorted list looks the same under every range.
    var taskCountLabel: String {
        // Before the first load both are 0; say nothing rather than "0 tasks".
        if matchingTaskCount == 0 && filteredTasks.isEmpty { return "" }
        return matchingTaskCount > filteredTasks.count
            ? "\(filteredTasks.count) of \(matchingTaskCount)"
            : "\(matchingTaskCount) task\(matchingTaskCount == 1 ? "" : "s")"
    }

    /// Everything the task detail page shows, in one read.
    func taskDetail(_ taskID: Int64) -> TaskStore.Detail? {
        guard let database = try? db() else { return nil }
        return (try? TaskStore.detail(taskID: taskID, database: database)) ?? nil
    }

    /// The compiled work note for one (task, local day) — the detail page
    /// expands each history day into its narrative inline.
    func workNote(dayStart: Int64, taskKey: String) -> WorkNote? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date(timeIntervalSince1970: Double(dayStart) / 1_000))
        return vault.workNote(day: day, taskKey: taskKey)
    }

    // MARK: - Themes (design.md §5.3, the high-level mode)

    func themeDetail(_ themeID: Int64) -> ThemeStore.Detail? {
        guard let database = try? db() else { return nil }
        return (try? ThemeStore.detail(themeID: themeID, database: database)) ?? nil
    }

    func renameTheme(_ themeID: Int64, to name: String) {
        if let database = try? db() {
            try? ThemeStore.rename(themeID: themeID, to: name, database: database)
        }
        refresh()
    }

    func createProjectAndAssign(_ taskID: Int64, projectName: String) {
        guard let database = try? db(),
              let project = try? TaskStore.createProject(named: projectName, database: database),
              let projectID = project.id else { return }
        try? TaskStore.assign(taskID: taskID, projectID: projectID, database: database)
        refresh()
    }

    func renameTask(_ taskID: Int64, to name: String) {
        if let database = try? db() {
            try? TaskStore.rename(taskID: taskID, to: name, database: database)
        }
        refresh()
    }

    func assignTask(_ taskID: Int64, toProject projectID: Int64?) {
        if let database = try? db() {
            try? TaskStore.assign(taskID: taskID, projectID: projectID, database: database)
        }
        refresh()
    }

    func createProject(named name: String) {
        if let database = try? db() {
            _ = try? TaskStore.createProject(named: name, database: database)
        }
        refresh()
    }

    // MARK: - Merge suggestions (vault-features.md §5.2 — user-confirmed)

    func acceptMerge(_ suggestion: TaskMerges.Pending) {
        if let database = try? db() {
            try? TaskMerges.merge(suggestion, database: database, vault: vault)
        }
        refresh()
    }

    func dismissMerge(_ suggestion: TaskMerges.Pending) {
        if let database = try? db() {
            try? TaskMerges.dismiss(suggestionID: suggestion.id, database: database)
        }
        refresh()
    }

    // MARK: - Project suggestions (vault-features.md §5.3 — one-tap)

    func acceptProjectSuggestion(_ suggestion: TaskMerges.PendingProject) {
        if let database = try? db() {
            try? TaskMerges.acceptProject(suggestion, database: database, vault: vault)
        }
        refresh()
    }

    func dismissProjectSuggestion(_ suggestion: TaskMerges.PendingProject) {
        if let database = try? db() {
            try? TaskMerges.dismissProject(suggestionID: suggestion.id, database: database)
        }
        refresh()
    }

    /// The project's compiled note as a hit for the shared note reader.
    func projectNoteHit(projectName: String) -> VaultSearch.Hit? {
        let slug = TaskGrouper.slug(projectName)
        let vault = self.vault
        guard let text = try? String(
            contentsOf: vault.projectNoteURL(slug: slug), encoding: .utf8),
              let doc = FrontMatter.parse(text), let noteID = doc.fields["id"]
        else { return nil }
        return VaultSearch.Hit(
            noteID: noteID, path: "projects/\(slug.prefix(60)).md", kind: .project,
            title: projectName, snippet: "", captured: nil)
    }

    // MARK: - Review decks (design.md §5.2)

    /// Due notes in the selected deck; the review session draws from this.
    var deckDueNotes: [Note] { due(in: reviewDeck) }

    func due(in deck: ReviewDeck) -> [Note] {
        switch deck {
        case .all:
            return dueNotes
        case .task(let key, _):
            return dueNotes.filter { TaskStore.matches(note: $0, taskKey: key) }
        case .project(let projectID, _):
            let keys = (try? db()).flatMap {
                try? TaskStore.taskKeys(projectID: projectID, database: $0)
            } ?? []
            return dueNotes.filter { note in
                keys.contains { TaskStore.matches(note: note, taskKey: $0) }
            }
        }
    }

    // MARK: - Radar

    func dismiss(_ suggestion: Suggestion) {
        if let database = try? db() { try? Radar.dismiss(suggestion, database: database) }
        refresh()
    }

    func snooze(_ suggestion: Suggestion) {
        if let database = try? db() { try? Radar.snooze(suggestion, database: database) }
        refresh()
    }

    func toggleWorkMode() {
        try? ShifuPaths.ensureHomeExists()
        if workModeOn {
            try? FileManager.default.removeItem(at: ShifuPaths.workModeFile)
        } else {
            try? Data().write(to: ShifuPaths.workModeFile)
        }
        refresh()
    }

    /// "4.2 h work · 1.1 h learning" — top categories, menu bar line (§7).
    var todaySummaryLine: String {
        let top = todayTotals
            .filter { $0.key != .unclassified && $0.value >= 60_000 }
            .sorted { $0.value > $1.value }
            .prefix(3)
        guard !top.isEmpty else { return "Today: nothing yet" }
        let parts = top.map { "\(Self.hours($0.value)) \($0.key.rawValue)" }
        return "Today: " + parts.joined(separator: " · ")
    }

    static func hours(_ ms: Int64) -> String {
        let hrs = Double(ms) / 3_600_000
        return hrs >= 1 ? String(format: "%.1f h", hrs) : "\(ms / 60_000) min"
    }
}

/// How far back the Task log's list reaches. Held as a range rather than a
/// timestamp so the cutoff is recomputed per query (see `LedgerStore.loadTasks`).
enum TaskRange: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case week = "Last 7 days"
    case month = "Last 30 days"
    case all = "All time"

    var id: String { rawValue }

    /// Unix ms cutoff, 0 for all time. Day-aligned for `today` so it means
    /// "since midnight", not "in the last 24 hours".
    func since(now: Date = Date(), calendar: Calendar = .current) -> Int64 {
        let start: Date
        switch self {
        case .today: start = calendar.startOfDay(for: now)
        case .week: start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .all: return 0
        }
        return Int64(start.timeIntervalSince1970 * 1_000)
    }
}

/// The floor on time spent, which is what makes a real roster readable: the
/// grouper mints a task per subject, so most of them are a stray minute.
enum TaskMinimum: String, CaseIterable, Identifiable, Hashable {
    case any = "Any length"
    case oneMinute = "1 min+"
    case fiveMinutes = "5 min+"
    case halfHour = "30 min+"

    var id: String { rawValue }

    var ms: Int64 {
        switch self {
        case .any: return 0
        case .oneMinute: return 60_000
        case .fiveMinutes: return 300_000
        case .halfHour: return 1_800_000
        }
    }
}

/// The Task log's filter bar (design.md §5.3): how far back, how long, how to
/// order, which project. Session state — deliberately not persisted, so
/// reopening the window always shows the unfiltered list.
struct TaskListFilter: Equatable {
    var range: TaskRange = .all
    /// Defaults to a floor rather than `.any`: an unfiltered roster is mostly
    /// stray minutes, and the header's "N of M" keeps the exclusion visible
    /// rather than silent.
    var minimum: TaskMinimum = .fiveMinutes
    var sort: TaskStore.Sort = .mostRecent
    var project: TaskStore.ProjectScope = .any

    /// Whether the list is showing fewer tasks than exist. Sort reorders
    /// rather than narrows, so it stays out of this — an empty list under a
    /// non-default sort means no data, not an over-tight filter.
    var narrowsResults: Bool { range != .all || minimum != .any || project != .any }

    /// Whether anything differs from the default — drives the "clear"
    /// affordance, which should also undo a non-default sort.
    var isNarrowed: Bool { self != TaskListFilter() }

    func core(now: Date = Date(), calendar: Calendar = .current, limit: Int)
        -> TaskStore.TaskFilter {
        TaskStore.TaskFilter(
            since: range.since(now: now, calendar: calendar),
            minimumMs: minimum.ms,
            projectScope: project, sort: sort, limit: limit)
    }
}

/// What the review session pulls cards from (design.md §5.2): everything, one
/// project's tasks, or a single task.
enum ReviewDeck: Hashable {
    case all
    case project(id: Int64, name: String)
    case task(key: String, name: String)

    var label: String {
        switch self {
        case .all: return "All notes"
        case .project(_, let name): return name
        case .task(_, let name): return name
        }
    }
}
