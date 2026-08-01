import Foundation

/// What the focus sessions add up to (design.md §4.4): each Focus Mode session
/// scored against the ledger blocks that fell inside it. This is the read side
/// of the contract `FocusModeController` enforces live, so the two must agree
/// on what counts — work and learning are on-task, unclassified and private
/// are neutral (never nagged, never scored), everything else is off-task.
///
/// Pure functions over already-read rows, like `LedgerShapes`: no database,
/// no clock, so a score can be checked in a test.
public enum FocusReport {
    private static let onTask: Set<Category> = [.work, .learning]
    private static let neutral: Set<Category> = [.privateTime, .unclassified]

    /// One session, clipped to the window it is being read in, with its
    /// classified time split for scoring.
    public struct Session: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let startedAt: Int64
        public let endedAt: Int64
        public let isLive: Bool
        public let onTaskMs: Int64
        public let offTaskMs: Int64

        public var durationMs: Int64 { endedAt - startedAt }

        public init(
            id: Int64, startedAt: Int64, endedAt: Int64, isLive: Bool,
            onTaskMs: Int64, offTaskMs: Int64
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isLive = isLive
            self.onTaskMs = onTaskMs
            self.offTaskMs = offTaskMs
        }

        /// On-task share of the session's classified time, 0…1 — nil when
        /// nothing inside it was classified either way (all neutral, or the
        /// screen went untracked), because a score with no evidence under it
        /// would just be a costume for 100%.
        public var score: Double? {
            let counted = onTaskMs + offTaskMs
            guard counted > 0 else { return nil }
            return Double(onTaskMs) / Double(counted)
        }
    }

    /// Which way a raw category string pulls a focus reading: +1 on-task,
    /// -1 off-task, 0 neutral. The one place the split is decided — `sessions`
    /// and `FocusCandles` both score through it, so they cannot drift apart.
    /// A category string the enum doesn't know is neutral too, the way the
    /// live controller treats it: never punished.
    public static func leaning(_ rawCategory: String) -> Int {
        guard let category = Category(rawValue: rawCategory),
              !neutral.contains(category)
        else { return 0 }
        return onTask.contains(category) ? 1 : -1
    }

    /// `raw` sessions scored against `activities`, both clipped to [from, to),
    /// oldest first. A session clipped to nothing drops out.
    public static func sessions(
        _ raw: [FocusModeSessions.Session],
        activities: [LedgerBuilder.LabeledActivity],
        from: Int64, to: Int64
    ) -> [Session] {
        raw.compactMap { session in
            let start = max(session.startedAt, from)
            let end = min(session.endedAt, to)
            guard end > start else { return nil }
            var onTaskMs: Int64 = 0
            var offTaskMs: Int64 = 0
            for activity in activities {
                let overlap = min(activity.endedAt, end) - max(activity.startedAt, start)
                guard overlap > 0 else { continue }
                switch leaning(activity.category) {
                case 1: onTaskMs += overlap
                case -1: offTaskMs += overlap
                default: break
                }
            }
            return Session(
                id: session.id, startedAt: start, endedAt: end, isLive: session.isLive,
                onTaskMs: onTaskMs, offTaskMs: offTaskMs)
        }
    }

    /// The window's one figure: every session's classified time pooled, so an
    /// hour of deep work outweighs a five-minute lapse — averaging the
    /// per-session scores would count them the same.
    public static func score(_ sessions: [Session]) -> Double? {
        let onTaskMs = sessions.reduce(0) { $0 + $1.onTaskMs }
        let counted = sessions.reduce(onTaskMs) { $0 + $1.offTaskMs }
        guard counted > 0 else { return nil }
        return Double(onTaskMs) / Double(counted)
    }
}
