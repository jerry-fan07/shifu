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
    @Published private(set) var recentTasks: [TaskStore.Overview] = []
    @Published private(set) var todayLogs: [TaskStore.DayLogEntry] = []
    @Published private(set) var projectSummaries: [TaskStore.ProjectSummary] = []
    @Published var reviewDeck: ReviewDeck = .all
    @Published var vaultQuery = ""
    @Published private(set) var vaultHits: [VaultSearch.Hit] = []
    @Published private(set) var lastError: String?

    private var vault: VaultStore { VaultStore(database: try? db()) }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    private var database: ShifuDatabase?

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
            todayLogs = (try? TaskStore.logs(dayStart: dayStart, database: database)) ?? []
            projectSummaries = (try? TaskStore.projects(database: database)) ?? []
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

    func activities(from: Date, to: Date) -> [Activity] {
        (try? db().queue.read { sqlite in
            try Activity
                .filter(sql: "ended_at > ? AND started_at < ?", arguments: [
                    Int64(from.timeIntervalSince1970 * 1_000),
                    Int64(to.timeIntervalSince1970 * 1_000)
                ])
                .order(sql: "started_at")
                .fetchAll(sqlite)
        }) ?? []
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
        vaultHits = (try? VaultSearch.search(vaultQuery, database: database)) ?? []
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

    // MARK: - Tasks & projects (design.md §5.3)

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
