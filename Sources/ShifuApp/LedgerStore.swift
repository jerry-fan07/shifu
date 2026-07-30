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
    /// Today's blocks, labelled — read once per refresh and shared by the
    /// source list's counts, the Breakdown table, and the Timeline. The Time
    /// pages used to open this query on every body pass.
    @Published private(set) var todayActivities: [LedgerBuilder.LabeledActivity] = []
    /// Tracked ms since Monday — the Week row's figure, from a SQL aggregate
    /// rather than a second block read.
    @Published private(set) var weekMs: Int64 = 0
    /// Everything in the vault, cards or not — the Notes row's count.
    @Published private(set) var noteCount = 0
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var workModeOn = false
    @Published private(set) var dueNotes: [Note] = []
    /// Every kept, reviewable card (Q/A present), most urgent first.
    @Published private(set) var allCards: [Note] = []
    /// Start-of-day → number of reviews done that day (heatmap, §5.2).
    @Published private(set) var reviewsByDay: [Date: Int] = [:]
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
    /// field and a theme menu, so this is a rendering budget, not a data one.
    static let taskListLimit = 50
    /// Merge suggestions shown *inline* at once. A bulk semantic regroup can
    /// mint hundreds of open suggestions, and rendering them all buries the
    /// task list they sit above — the filter bar then reads as dead because
    /// its effect is off screen. The query orders strongest-first, so acting
    /// on (or dismissing) one surfaces the next, and the rest live one tap
    /// away in MergeReviewView.
    static let suggestionLimit = 5
    /// The full open queues. The Task log renders `suggestionLimit` merge
    /// suggestions; the Merge review screen renders both queues in full.
    @Published private(set) var allMergeSuggestions: [TaskMerges.Pending] = []
    @Published private(set) var allThemeSuggestions: [TaskMerges.PendingTheme] = []

    var mergeSuggestions: [TaskMerges.Pending] {
        Array(allMergeSuggestions.prefix(Self.suggestionLimit))
    }

    /// Open suggestions the inline list isn't showing — the count behind
    /// the "Review all" link. Theme assignments live only on the Merge
    /// review screen now, so all of them count as hidden.
    var hiddenSuggestionCount: Int {
        (allMergeSuggestions.count - mergeSuggestions.count)
            + allThemeSuggestions.count
    }

    /// Created once; nil when the OS has no sentence model (search stays
    /// bm25-only, silently — vault-features.md §4).
    private let embedder = SentenceEmbedder()
    @Published private(set) var todayLogs: [TaskStore.DayLogEntry] = []

    /// The Today day log, scoped by the two filter dimensions that mean
    /// something for a single day's log: the minimum-time floor and the
    /// theme. Range and sort deliberately don't apply — the log is already
    /// one day, and its most-recent-first order is part of what makes it read
    /// as a log rather than a task list. Derived, not @Published: it reads
    /// `todayLogs` and `taskFilter`, both @Published, so SwiftUI recomputes it
    /// whenever either changes — no `loadTasks()` round trip needed.
    var filteredTodayLogs: [TaskStore.DayLogEntry] {
        let floor = taskFilter.minimum.ms
        return todayLogs.filter { entry in
            guard entry.durationMs >= floor else { return false }
            switch taskFilter.theme {
            case .any: return true
            case .theme(let key): return entry.themeKey == key
            case .unassigned: return entry.themeKey == nil
            }
        }
    }
    @Published private(set) var themes: [ThemeStore.Overview] = []
    /// Initiatives the clusterer wants to found, shown below the Themes grid.
    /// Nothing here is a theme until the user says so (design.md §5.3).
    @Published private(set) var themeProposals: [ThemeProposals.Pending] = []
    /// Decks the user has asked for (§5.2), newest first — the picker's own
    /// group, and the "Building…" rows on the Cards screen.
    @Published private(set) var decks: [DeckStore.Deck] = []
    /// Deck proposals waiting for Create/Dismiss.
    @Published private(set) var deckSuggestions: [DeckStore.PendingSuggestion] = []
    /// Whether an LLM backend is configured at all. Building a deck needs one,
    /// and a deck requested without one would sit "Building…" forever — so the
    /// actions that mint decks are gated on this rather than failing later.
    @Published private(set) var hasLLMBackend = false
    @Published var reviewDeck: ReviewDeck = .all
    @Published var vaultQuery = ""
    @Published private(set) var vaultHits: [VaultSearch.Hit] = []
    @Published private(set) var lastError: String?

    /// Surfaces a failure on the UI's error line. Internal (and a method
    /// rather than a settable property) so the extensions split out of this
    /// file for length can report too.
    func report(_ error: any Error) { lastError = "\(error)" }

    var vault: VaultStore { VaultStore(database: try? db()) }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    private var database: ShifuDatabase?
    private var analyzerProcess: Process?
    /// Held separately from `analyzerProcess` so a deck build and the
    /// on-demand full analysis never cancel each other out of the "already
    /// running" check. Stored here because extensions can't hold state.
    var deckBuildProcess: Process?
    private var lastAnalyzerRun = Date.distantPast

    /// Internal, not private: the store's actions are split across files
    /// (LedgerStoreThemes.swift, LedgerStoreDecks.swift, …), and they all open
    /// the DB through here.
    func db() throws -> ShifuDatabase {
        if let database { return database }
        try ShifuPaths.ensureHomeExists()
        let opened = try ShifuDatabase.open(at: ShifuPaths.database)
        database = opened
        return opened
    }

    func refresh() {
        pausedUntil = PauseFile.expiry()
        workModeOn = WorkModeFile.isOn()
        refreshVaultNotes()
        suggestions = (try? db()).flatMap { try? Radar.active(database: $0) } ?? []
        if let database = try? db() {
            let dayStart = Int64(
                Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
            recentTasks = (try? TaskStore.recentTasks(database: database)) ?? []
            loadTasks()
            allMergeSuggestions = (try? TaskMerges.pending(database: database)) ?? []
            allThemeSuggestions = (try? TaskMerges.pendingThemes(database: database)) ?? []
            todayLogs = (try? TaskStore.logs(dayStart: dayStart, database: database)) ?? []
            themes = (try? ThemeStore.overviews(database: database)) ?? []
            themeProposals = (try? ThemeProposals.pending(database: database)) ?? []
            decks = (try? DeckStore.decks(database: database)) ?? []
            deckSuggestions = (try? DeckStore.pendingSuggestions(database: database)) ?? []
            hasLLMBackend = ((try? Settings.llmAPIKey(database: database)) ?? nil) != nil
        }
        do {
            let now = Date()
            let start = Calendar.current.startOfDay(for: now)
            todayTotals = try LedgerBuilder.totals(
                database: db(),
                from: Int64(start.timeIntervalSince1970 * 1_000),
                to: Int64(now.timeIntervalSince1970 * 1_000)
            )
            todayActivities = labeledActivities(from: start, to: now)
            weekMs = try LedgerBuilder.totals(
                database: db(),
                from: Int64(Calendar.current.startOfWeek(for: now)
                    .timeIntervalSince1970 * 1_000),
                to: Int64(now.timeIntervalSince1970 * 1_000)
            ).values.reduce(0, +)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// refresh(), one runloop turn later. Controls embedded in List rows
    /// (rename fields, theme menus, Merge/Keep/Dismiss buttons) fire while
    /// AppKit is still inside the backing NSTableView's delegate callback;
    /// republishing the list's own data there is a reentrant table operation
    /// (AppKit warns today, will assert eventually). Every store action a row
    /// can trigger goes through this; menu-bar actions stay synchronous.
    func refreshSoon() {
        Task { @MainActor [weak self] in self?.refresh() }
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

    // MARK: - Tasks & themes (design.md §5.3)

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

    /// loadTasks(), one runloop turn later. The filter bar's `onChange` fires
    /// inside SwiftUI's action-dispatch phase; republishing `filteredTasks`
    /// there deletes List rows whose NavigationLink activation attributes that
    /// same phase is still dispatching — AttributeGraph then reads a dead
    /// attribute and crashes (EXC_BAD_ACCESS in
    /// NavigationLinkListActivationModifier, macOS 26).
    func loadTasksSoon() {
        Task { @MainActor [weak self] in self?.loadTasks() }
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

    // Theme reads and edits live in LedgerStoreThemes.swift.

    func renameTask(_ taskID: Int64, to name: String) {
        if let database = try? db() {
            try? TaskStore.rename(taskID: taskID, to: name, database: database)
        }
        refreshSoon()
    }

    func assignTask(_ taskID: Int64, toTheme themeKey: String?) {
        if let database = try? db() {
            try? TaskStore.assignTheme(taskID: taskID, themeKey: themeKey, database: database)
        }
        refreshSoon()
    }

    // MARK: - Merge suggestions (vault-features.md §5.2)

    func acceptMerge(_ suggestion: TaskMerges.Pending) {
        if let database = try? db() {
            try? TaskMerges.merge(suggestion, database: database, vault: vault)
        }
        refreshSoon()
    }

    func dismissMerge(_ suggestion: TaskMerges.Pending) {
        if let database = try? db() {
            try? TaskMerges.dismiss(suggestionID: suggestion.id, database: database)
        }
        refreshSoon()
    }

    /// "None of these are duplicates" — clears the open merge queue.
    func dismissAllMerges() {
        if let database = try? db() {
            _ = try? TaskMerges.dismissAll(database: database)
        }
        refreshSoon()
    }

    // MARK: - Theme suggestions (vault-features.md §5.3 — one-tap)

    func acceptThemeSuggestion(_ suggestion: TaskMerges.PendingTheme) {
        if let database = try? db() {
            try? TaskMerges.acceptTheme(suggestion, database: database)
        }
        refreshSoon()
    }

    func dismissThemeSuggestion(_ suggestion: TaskMerges.PendingTheme) {
        if let database = try? db() {
            try? TaskMerges.dismissTheme(suggestionID: suggestion.id, database: database)
        }
        refreshSoon()
    }

    func dismissAllThemeSuggestions() {
        if let database = try? db() {
            _ = try? TaskMerges.dismissAllThemes(database: database)
        }
        refreshSoon()
    }

    // MARK: - Review decks (design.md §5.2)

    /// Due notes in the selected deck; the review session draws from this.
    var deckDueNotes: [Note] { due(in: reviewDeck) }

    func due(in deck: ReviewDeck) -> [Note] {
        switch deck {
        case .all:
            return dueNotes
        case .deck(let key, _):
            return dueNotes.filter { $0.deck == key }
        case .task(let key, _):
            return dueNotes.filter { TaskStore.matches(note: $0, taskKey: key) }
        case .theme(let themeKey, _):
            let keys = (try? db()).flatMap {
                try? ThemeStore.taskKeys(themeKey: themeKey, database: $0)
            } ?? []
            return dueNotes.filter { note in
                keys.contains { TaskStore.matches(note: note, taskKey: $0) }
            }
        }
    }

    // MARK: - Radar

    func dismiss(_ suggestion: Suggestion) {
        if let database = try? db() { try? Radar.dismiss(suggestion, database: database) }
        refreshSoon()
    }

    func snooze(_ suggestion: Suggestion) {
        if let database = try? db() { try? Radar.snooze(suggestion, database: database) }
        refreshSoon()
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

    /// Republishes every vault-derived queue. The walk itself lives in the
    /// vault extension; only the assignment is here, because these properties
    /// are `private(set)` and an extension in another file can't write them.
    private func refreshVaultNotes() {
        let snapshot = vaultSnapshot()
        allCards = snapshot.cards
        dueNotes = snapshot.due
        reviewsByDay = snapshot.reviewsByDay
        noteCount = snapshot.total
    }
}
