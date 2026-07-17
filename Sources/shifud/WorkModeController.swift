import Foundation
import GRDB
import ShifuCore

/// Work Mode (design.md §4.4): a user-invoked focus contract. While active,
/// each capture is classified in near-real-time using the rules layer only —
/// no LLM on the hot path. Off-task time past a grace period triggers the
/// glow pulse, at most every `pulseSpacing`. Unknown categories are neutral,
/// never nagged. Sessions are logged for adherence stats.
@MainActor
final class WorkModeController {
    static let gracePeriod: TimeInterval = 180      // 3 min off-task before first glow
    static let pulseSpacing: TimeInterval = 240     // ≥4 min between glows

    private let database: ShifuDatabase
    private let classifier: RulesClassifier
    private let overlay = GlowOverlay()

    private var dirSource: DispatchSourceFileSystemObject?
    private var wasActive = false
    private var sessionRowID: Int64?
    private var offTaskSince: Date?
    private var lastPulseAt: Date = .distantPast

    var isActive: Bool {
        FileManager.default.fileExists(atPath: ShifuPaths.workModeFile.path)
    }

    init(database: ShifuDatabase, classifier: RulesClassifier) {
        self.database = database
        self.classifier = classifier
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

    private func evaluateToggle() {
        let active = isActive
        guard active != wasActive else { return }
        wasActive = active
        offTaskSince = nil
        if active {
            log("work mode ON")
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            sessionRowID = try? database.queue.write { db in
                try db.execute(sql: "INSERT INTO work_mode_sessions (started_at) VALUES (?)",
                               arguments: [now])
                return db.lastInsertedRowID
            }
        } else {
            log("work mode OFF")
            if let rowID = sessionRowID {
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                try? database.queue.write { db in
                    try db.execute(sql: "UPDATE work_mode_sessions SET ended_at = ? WHERE id = ?",
                                   arguments: [now, rowID])
                }
            }
            sessionRowID = nil
        }
    }

    /// Called by the capture engine after every capture while watching.
    func observe(appBundle: String, url: String?, excluded: Bool) {
        guard isActive else { return }

        let block = Sessionizer.Block(
            appBundle: appBundle, domain: Sessionizer.domain(of: url),
            startedAt: 0, endedAt: 0, observationIDs: [], titles: [], excluded: excluded
        )
        let result = classifier.classify(block: block)

        switch result.category {
        case .work, .learning:
            offTaskSince = nil
        case .unclassified, .privateTime:
            break   // neutral: never nagged, doesn't reset the clock either
        default:
            let since = offTaskSince ?? Date()
            offTaskSince = since
            if Date().timeIntervalSince(since) >= Self.gracePeriod,
               Date().timeIntervalSince(lastPulseAt) >= Self.pulseSpacing {
                lastPulseAt = Date()
                log("work mode: off-task (\(result.category.rawValue)) — glow pulse")
                overlay.pulse()
            }
        }
    }
}
