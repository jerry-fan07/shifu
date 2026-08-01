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
