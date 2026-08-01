import ShifuCore
import SwiftUI

/// The line under the Focus Mode switch: how long this session has been
/// running, and how long it had been since the last one (design.md §4.4).
///
/// It goes wherever the switch goes — the rail's foot, the menu bar panel —
/// because a stopwatch you have to navigate to is one you stop reading. Both
/// readings come from `LedgerStore`'s two published moments, so the tick costs
/// no file read and no query; what it costs is one `Text` re-laying out a
/// second, which is why the ticking is scoped to the label and nothing above it.
struct FocusTimerLine: View {
    @EnvironmentObject private var store: LedgerStore
    var size: CGFloat = 10.5

    var body: some View {
        // With nothing running and nothing behind it there is no schedule at
        // all: a fresh install shouldn't spend a wake-up a second on a line
        // that says nothing.
        FocusTick(active: store.focusStartedAt != nil || store.focusPreviousEnd != nil) { now in
            let reading = store.focusClock(now: now)
            if let elapsed = reading.elapsed {
                HStack(spacing: 6) {
                    StatusDot(color: Instrument.live, size: 5)
                    Figure(
                        FocusClock.stopwatch(elapsed), size: size,
                        weight: .medium, color: Instrument.live)
                    if let away = reading.away {
                        // The gap that *preceded* this session, frozen — the
                        // one number here that isn't about right now, so it
                        // gets the quietest ink on the row, and yields first:
                        // a ten-hour session after a day away is two long
                        // readings in a 182 pt rail, and the stopwatch is the
                        // one that must survive whole.
                        Figure(
                            "after \(FocusClock.since(away)) away",
                            size: size, color: Instrument.ghost)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("In focus \(FocusClock.stopwatch(elapsed))")
            } else if let away = reading.away {
                Figure("last focus \(FocusClock.since(away)) ago",
                       size: size, color: Instrument.ghost)
            }
            // Focus Mode off and never used: nothing to time, so nothing is
            // said. A blank line is the honest reading, and the row keeps the
            // height it has always had.
        }
    }
}

/// The menu bar item's second hand (design.md §7).
///
/// The item can't use `FocusTick` the way every on-screen surface does. A
/// `MenuBarExtra` label is built once and never re-proposed on a schedule of
/// its own: the `TimelineView` inside it fires and nothing redraws, so the
/// reading freezes at whatever it read when the item was made. What *does*
/// move it is an object it observes — so the tick lives here, as a published
/// value, and the label is an ordinary view of it.
///
/// Kept off `LedgerStore` on purpose, though the store owns one: a published
/// value there re-runs every body in the app that reads the store, once a
/// second, and the window has tables a hand's breadth away that must not.
///
/// The timer runs only while a session does — an idle Shifu keeps none.
@MainActor
final class FocusStopwatch: ObservableObject {
    /// How long the running session has been going, or nil when Focus Mode is
    /// off. The whole published surface: the item wears one number.
    @Published private(set) var elapsed: TimeInterval?

    private var startedAt: Date?
    private var timer: Timer?

    /// Points the stopwatch at a session, or stops it with nil. Idempotent:
    /// `refresh()` republishes the same start many times a minute, and each
    /// one must not restart the second hand mid-second.
    func follow(startedAt: Date?) {
        guard startedAt != self.startedAt else { return }
        self.startedAt = startedAt
        timer?.invalidate()
        timer = nil
        read()
        guard startedAt != nil else { return }
        let ticking = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        // Nothing is being timed to the quarter-second here, and the slack is
        // what lets macOS coalesce this wake-up with whatever else is due.
        ticking.tolerance = 0.25
        // `.common`, not the default mode: a stopwatch that stopped while a
        // menu was open would be frozen exactly when it is being read.
        RunLoop.main.add(ticking, forMode: .common)
        timer = ticking
    }

    /// One reading, through the same arithmetic every other surface uses — the
    /// bar and the panel must never disagree about a number they both draw.
    private func read() {
        elapsed = FocusClock.reading(
            now: Date(), startedAt: startedAt, previousEnd: nil).elapsed
    }
}

/// Re-renders its content once a second while `active`, and never otherwise.
///
/// Both clocks tick — the running session by construction, and the gap since
/// the last one because it is measured against now. The gap only changes its
/// string once a minute past the first minute, but a schedule that slowed down
/// to match would have to change cadence mid-flight; one second is cheap enough
/// that it isn't worth being clever about.
///
/// Wrap the label, never the row: whatever is inside this is what re-lays out
/// every second, and the rail's foot and the Focus table both have measured
/// text a hand's breadth away that must not.
struct FocusTick<Content: View>: View {
    /// False parks the view on one fixed reading — for a line with no clock
    /// on it, which would otherwise cost a wake-up a second to say nothing.
    var active = true
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}
