import Foundation
import GRDB
import ShifuCore

/// Focus Mode (design.md §4.4): a user-invoked focus contract. While active,
/// each capture is classified in near-real-time using the rules layer only —
/// no LLM on the hot path. Off-task time past a grace period triggers the
/// glow pulse, at most every `pulseSpacing`. Unknown categories are neutral,
/// never nagged. Sessions are logged for adherence stats.
@MainActor
final class FocusModeController {
    static let gracePeriod: TimeInterval = 1       // 1 s off-task before first glow
    /// ≥10 s between glows. Shared with the app, which draws the pulse against
    /// this gap during first run — "and then nothing for this long" is half of
    /// what makes the nudge tolerable, and it only reads to scale.
    static let pulseSpacing = FocusNudge.spacing

    private let database: ShifuDatabase
    private let classifier: RulesClassifier
    private let overlay = GlowOverlay()

    private var dirSource: DispatchSourceFileSystemObject?
    private var activeToken: ControlFileToken?
    private var sessionRowID: Int64?
    private var offTaskSince: Date?
    private var lastPulseAt: Date = .distantPast

    /// User-listed distracting sites (design.md §9). Focus-Mode-only on purpose:
    /// these never touch the `rules` table, so the ledger keeps its own
    /// categories — a site can be work normally and off-limits while focusing.
    /// Reloaded each time Focus Mode switches on; edits mid-session apply on the
    /// next toggle.
    private var distractingDomains: Set<String> = []

    /// Focus Mode is on when the control file exists. Tracked by identity rather
    /// than existence so a fast off→on (a double-click, or
    /// `shifu focus off && shifu focus on`) reads as a new session — see
    /// `ControlFileToken`.
    var isActive: Bool { activeToken != nil }

    init(database: ShifuDatabase, classifier: RulesClassifier) {
        self.database = database
        self.classifier = classifier
        // A previous daemon that exited while Focus Mode was on left its session
        // row open. Close it here — before anything can call `beginSession()`,
        // or the reconciliation would close the new row instead of the old one.
        if let closed = try? FocusModeSessions.closeDangling(database: database), closed > 0 {
            log("closed \(closed) focus mode session(s) left open by a previous run")
        }
    }

    func startWatching() {
        let fd = open(ShifuPaths.home.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.evaluateToggle() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
        evaluateToggle()
    }

    /// Compares file *identity*, so an off→on that completes between handler
    /// runs still ends the old session and starts a new one — with a freshly
    /// loaded site list — instead of looking like no change at all.
    private func evaluateToggle() {
        let token = ControlFileToken(at: ShifuPaths.focusModeFile)
        guard token != activeToken else { return }
        let wasOn = activeToken != nil
        activeToken = token
        offTaskSince = nil

        if wasOn { endSession() }
        if token != nil { beginSession() }
    }

    private func beginSession() {
        log("focus mode ON")
        distractingDomains = Set(
            Settings.value(SettingsCatalog.focusModeDistractingDomains, database: database))
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        sessionRowID = try? database.queue.write { db in
            try db.execute(sql: "INSERT INTO focus_mode_sessions (started_at) VALUES (?)",
                           arguments: [now])
            return db.lastInsertedRowID
        }
    }

    /// On a missed-off (fast toggle) the end time is "now" rather than the real
    /// off moment — we never observed it. Better than leaving the row open.
    private func endSession() {
        log("focus mode OFF")
        overlay.dismiss()   // an in-flight nudge shouldn't outlive the contract
        if let rowID = sessionRowID {
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            try? database.queue.write { db in
                try db.execute(sql: "UPDATE focus_mode_sessions SET ended_at = ? WHERE id = ?",
                               arguments: [now, rowID])
            }
        }
        sessionRowID = nil
    }

    /// Called by the capture engine after every capture while watching.
    func observe(appBundle: String, url: String?, excluded: Bool) {
        // Self-heal: the watcher is edge-triggered, so a toggle landing between
        // callbacks would otherwise leave this on a stale list for the whole
        // session. One `stat` per capture is nothing next to the capture itself,
        // and it makes the site list correct even if the watcher never fires.
        evaluateToggle()
        guard isActive else { return }

        let domain = Sessionizer.domain(of: url)
        // A user-listed distracting site is off-task whatever the rules layer
        // thinks — that's the point of a Focus-Mode-only list.
        if let listed = DomainMatcher.distracting(
            domain: domain, excluded: excluded, listed: distractingDomains) {
            flagOffTask(reason: listed)
            return
        }

        let block = Sessionizer.Block(
            appBundle: appBundle, domain: domain,
            startedAt: 0, endedAt: 0, observationIDs: [], titles: [], excluded: excluded
        )
        let result = classifier.classify(block: block)

        switch result.category {
        case .work, .learning:
            offTaskSince = nil
        case .unclassified, .privateTime:
            break   // neutral: never nagged, doesn't reset the clock either
        default:
            flagOffTask(reason: result.category.rawValue)
        }
    }

    /// Starts (or continues) the off-task clock, pulsing the glow once past the
    /// grace period and no more often than `pulseSpacing`.
    private func flagOffTask(reason: String) {
        let since = offTaskSince ?? Date()
        offTaskSince = since
        guard Date().timeIntervalSince(since) >= Self.gracePeriod,
              Date().timeIntervalSince(lastPulseAt) >= Self.pulseSpacing else { return }
        // Only a pulse that actually showed counts against `pulseSpacing`. A
        // skip (e.g. Mission Control up, §4.4) leaves `lastPulseAt` untouched so
        // the next off-task capture — a heartbeat away — retries, rather than
        // swallowing the nudge for a whole spacing window.
        if overlay.pulse() {
            lastPulseAt = Date()
            log("focus mode: off-task (\(reason)) — glow pulse")
        }
    }
}
