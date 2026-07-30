import Foundation
import ShifuCore

/// The control-file actions (design.md §8): pause and Work Mode are the
/// same two files the CLI and the daemon read, so the app toggles them by
/// writing the file, never by messaging the daemon. Split out of
/// LedgerStore.swift for length only.
///
/// The formats themselves live in `ShifuCore/ControlFiles.swift` — the app is
/// one of three processes that agree on them, and the parse used to exist
/// here, in `shifu-cli`, and in `PauseController` separately.
@MainActor
extension LedgerStore {
    // MARK: - Pause (same control file as the CLI)

    func pause(until: Date) {
        try? PauseFile.pause(until: until)
        refresh()
    }

    func resume() {
        PauseFile.resume()
        refresh()
    }

    func toggleWorkMode() {
        if workModeOn {
            WorkModeFile.turnOff()
        } else {
            try? WorkModeFile.turnOn()
        }
        refresh()
    }
}
