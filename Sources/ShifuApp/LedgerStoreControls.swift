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

    /// The running session's minutes the analyzer hasn't folded yet, read
    /// straight from `observations` and classified by the rules tier
    /// (`ObservationTail`) — so the Focus line and score move with the app in
    /// front of you, not with the hourly fold. Callers re-ask on every store
    /// publish, which the window's poll drives once a minute — the line's own
    /// resolution.
    ///
    /// It outlives the switch by exactly one session: while Focus Mode runs
    /// the tail ends at `now`, and after this app turns it off the tail ends
    /// where the session did, until the analyzer's fold reaches past it. The
    /// alternative is a score that collapses to "nothing classified" the
    /// instant you stop focusing and stays there for the rest of the hour —
    /// the one moment the reading is most worth having. Older history still
    /// waits for the fold it deserves: nothing stands in for a session this
    /// process didn't watch end.
    func focusTailBlocks(now: Date = Date()) -> [LedgerBuilder.LabeledActivity] {
        let end: Date? = focusStartedAt != nil ? now : focusEndedHere
        guard let end, let database = try? db() else { return [] }
        // The fold's high-water mark, floored by the session's own start while
        // one is running.
        var after = todayActivities.map(\.endedAt).max() ?? 0
        if let started = focusStartedAt {
            after = max(after, Int64(started.timeIntervalSince1970 * 1_000))
        } else {
            // A session that already ended has no start on hand. It needs none
            // to be scored — the score clips every block to the session it is
            // scoring — but it does need a floor: with nothing folded yet the
            // high-water mark is zero, and an unfloored read walks the whole
            // observations table. The day is the tail's outer limit anyway.
            after = max(after, Int64(
                Calendar.current.startOfDay(for: end).timeIntervalSince1970 * 1_000))
        }
        let classifier = (try? RulesClassifier(database: database)) ?? RulesClassifier()
        return (try? ObservationTail.activities(
            after: after, to: Int64(end.timeIntervalSince1970 * 1_000),
            database: database, classifier: classifier)) ?? []
    }

    // MARK: - The sessions themselves

    /// The window's Focus Mode sessions, ends resolved — the Focus view's
    /// rows. An open row counts, running to now, only while Focus Mode really
    /// is on; otherwise it is a crashed daemon's leftover and the next daemon
    /// launch will repair it (`FocusModeSessions.closeDangling`).
    ///
    /// Reports rather than swallowing: this read depends on the *schema*, and
    /// a bare `try?` turns "that table isn't there" into "you had no
    /// sessions", which is indistinguishable from a genuinely quiet week. It
    /// is not hypothetical — the sessions table was renamed under this branch
    /// by another workspace's migration, and the page read as empty for a day
    /// instead of saying so.
    func focusSessions(from: Date, to: Date) -> [FocusModeSessions.Session] {
        guard let database = try? db() else { return [] }
        let liveEnd = FocusModeFile.isOn()
            ? Int64(Date().timeIntervalSince1970 * 1_000) : nil
        do {
            let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
            let toMs = Int64(to.timeIntervalSince1970 * 1_000)
            // The stand-in covers the gap between the flip and the daemon's
            // own row landing (`addingStandIn`) — without it a toggle made
            // from this very window reads as nothing having happened.
            return FocusModeSessions.addingStandIn(
                try FocusModeSessions.overlapping(
                    from: fromMs, to: toMs, liveEnd: liveEnd,
                    // The mirror of the stand-in, at the other end: the switch
                    // has gone off here but the daemon's `ended_at` hasn't
                    // landed, so the row it left open is closed at the moment
                    // we flipped it (`endedHere`) rather than dropped.
                    endedHere: focusEndedHere
                        .map { Int64($0.timeIntervalSince1970 * 1_000) },
                    database: database),
                liveEnd: liveEnd,
                startedAt: FocusModeFile.startedAt()
                    .map { Int64($0.timeIntervalSince1970 * 1_000) },
                from: fromMs, to: toMs)
        } catch {
            report(error)
            return []
        }
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
