import Foundation
import ShifuCore

/// The control-file actions (design.md §8): pause and Work Mode are the
/// same two files the CLI and the daemon read, so the app toggles them by
/// writing the file, never by messaging the daemon. Split out of
/// LedgerStore.swift for length only.
@MainActor
extension LedgerStore {
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

    func toggleWorkMode() {
        try? ShifuPaths.ensureHomeExists()
        if workModeOn {
            try? FileManager.default.removeItem(at: ShifuPaths.workModeFile)
        } else {
            try? Data().write(to: ShifuPaths.workModeFile)
        }
        refresh()
    }
}
