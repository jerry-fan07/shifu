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
    @Published private(set) var lastError: String?

    private var vault: VaultStore { VaultStore(database: try? db()) }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    private var database: ShifuDatabase?

    private func db() throws -> ShifuDatabase {
        if let database { return database }
        try ShifuPaths.ensureHomeExists()
        let opened = try ShifuDatabase(at: ShifuPaths.database)
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
                    Int64(to.timeIntervalSince1970 * 1_000),
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
