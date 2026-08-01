import Foundation
import ShifuCore

/// The control-file actions (design.md §8): pause and Focus Mode are the
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

    /// Flipping the switch also starts (or stops) the stopwatch — but neither
    /// clock is kept here: `turnOn` creates the control file, and the file's
    /// birth time *is* the session start (`FocusClock`). Turning off is the one
    /// moment the app has to remember, because the end it implies is the
    /// daemon's to write down.
    func toggleFocusMode() {
        if focusModeOn {
            FocusModeFile.turnOff()
            focusEndedHere = Date()
        } else {
            try? FocusModeFile.turnOn()
        }
        refresh()
    }

    // MARK: - The two clocks the switch carries (design.md §4.4)

    /// Both clocks as of `now`. The moments they measure from are republished
    /// by `refresh()`; only `now` moves between ticks, so the ticking line can
    /// ask for this once a second without touching a file or the database.
    func focusClock(now: Date = Date()) -> FocusClock.Reading {
        FocusClock.reading(now: now, startedAt: focusStartedAt, previousEnd: focusPreviousEnd)
    }

    /// Where each clock starts, read fresh: the control file's birth time, and
    /// the end of the last real session before whichever moment this reading
    /// is about. Returned rather than assigned because the properties are
    /// `private(set)` to the store's own file, which is the right shape — this
    /// is a read, and `refresh()` is the only thing that should publish it.
    func focusMoments() -> (startedAt: Date?, previousEnd: Date?) {
        let startedAt = focusModeOn ? FocusModeFile.startedAt() : nil
        // While a session runs, "the previous session" is the one before *it*,
        // not the one before now — the running session sits in between.
        let cutoff = startedAt ?? Date()
        var previous: Date?
        if let database = try? db(),
           let logged = try? FocusModeSessions.previousEnd(
               before: Int64(cutoff.timeIntervalSince1970 * 1_000), database: database) {
            previous = Date(timeIntervalSince1970: Double(logged) / 1_000)
        }
        // What we saw ourselves, when the daemon's `ended_at` hasn't landed
        // yet — see `focusEndedHere`.
        if let ended = focusEndedHere, ended <= cutoff, previous.map({ ended > $0 }) ?? true {
            previous = ended
        }
        return (startedAt, previous)
    }
}
