import Foundation

/// The fold under `Workload.read`: blocks into per-front groups and the two
/// per-week totals, in one pass (design.md §4.6). Split out of Workload.swift
/// for length only — the thresholds and the verdict stay there.
extension Workload {
    // MARK: - Bucketing

    struct Key: Hashable {
        let taskID: Int64?
        let themeID: Int64?
    }

    struct Group {
        var name = ""
        /// Ms per theme name, so a task's theme is the one most of its time
        /// sits in (`TaskStore.dominantThemeSQL`'s rule) rather than
        /// whichever block came last.
        var themeMs: [String: Int64] = [:]
        var themeName: String? { themeMs.max { $0.value < $1.value }?.key }
        var weekly = [Int64](repeating: 0, count: weeks)
        var firstSeenAt = Int64.max
        var lastActiveAt = Int64.min
        /// The dominance vote, classified categories only — unclassified and
        /// private sit it out, the way `FocusReport` scores them, so a task
        /// whose OCR mostly came back unlabelled is still the learning it was.
        var onTaskMs: Int64 = 0
        var offTaskMs: Int64 = 0
        var blocks: [Block] = []

        var isFocused: Bool { onTaskMs > 0 && onTaskMs >= offTaskMs }

        mutating func fold(_ block: Block, spread: [(Int, Int64)], unit: Unit) {
            name = (unit == .task ? block.taskName : block.themeName) ?? name
            if unit == .task, let theme = block.themeName {
                themeMs[theme, default: 0] += block.endedAt - block.startedAt
            }
            for (week, ms) in spread { weekly[week] += ms }
            firstSeenAt = min(firstSeenAt, block.startedAt)
            lastActiveAt = max(lastActiveAt, block.endedAt)
            switch FocusReport.leaning(block.category) {
            case 1: onTaskMs += block.endedAt - block.startedAt
            case -1: offTaskMs += block.endedAt - block.startedAt
            default: break
            }
            blocks.append(block)
        }
    }

    /// Blocks folded into per-key groups and the two per-week totals, in one
    /// pass. Capacity needs each *task's* vote whatever the unit, so the task
    /// vote is always taken; the theme vote only when a theme is the front.
    struct Keyed {
        var groups: [Key: Group] = [:]
        var capacity = [Int64](repeating: 0, count: weeks)
        var tracked = [Int64](repeating: 0, count: weeks)

        init(blocks: [Block], unit: Unit, now: Int64) {
            let votes = Self.taskVotes(blocks)
            for block in blocks {
                let spread = Self.spread(block, now: now)
                guard !spread.isEmpty else { continue }
                for (week, ms) in spread { tracked[week] += ms }
                if Self.isFocused(block, votes: votes) {
                    for (week, ms) in spread { capacity[week] += ms }
                }
                guard let key = Self.key(block, unit: unit) else { continue }
                var group = groups[key] ?? Group()
                group.fold(block, spread: spread, unit: unit)
                groups[key] = group
            }
        }

        /// Every task's dominance vote, taken once up front: capacity needs
        /// it for every block, not only the ones that end up as fronts.
        private static func taskVotes(_ blocks: [Block]) -> [Int64: (on: Int64, off: Int64)] {
            var votes: [Int64: (on: Int64, off: Int64)] = [:]
            for block in blocks {
                let ms = block.endedAt - block.startedAt
                guard ms > 0, let taskID = block.taskID else { continue }
                var vote = votes[taskID] ?? (0, 0)
                switch FocusReport.leaning(block.category) {
                case 1: vote.on += ms
                case -1: vote.off += ms
                default: break
                }
                votes[taskID] = vote
            }
            return votes
        }

        /// A block of a work- or learning-dominant task, whatever its own
        /// label; an unplaced block votes for itself.
        private static func isFocused(_ block: Block, votes: [Int64: (on: Int64, off: Int64)]) -> Bool {
            if let taskID = block.taskID, let vote = votes[taskID] {
                return vote.on > 0 && vote.on >= vote.off
            }
            return FocusReport.leaning(block.category) == 1
        }

        private static func key(_ block: Block, unit: Unit) -> Key? {
            switch unit {
            case .task: return block.taskID.map { Key(taskID: $0, themeID: nil) }
            case .theme: return block.themeID.map { Key(taskID: nil, themeID: $0) }
            }
        }

        /// A block's ms per rolling week, split at the boundaries it straddles
        /// and clipped at now — a block still open as the reading is taken
        /// counts only what it has lived.
        static func spread(_ block: Block, now: Int64) -> [(Int, Int64)] {
            var out: [(Int, Int64)] = []
            for week in 0..<weeks {
                let to = now - Int64(week) * weekMs
                let from = to - weekMs
                let overlap = min(block.endedAt, to) - max(block.startedAt, from)
                if overlap > 0 { out.append((week, overlap)) }
            }
            return out
        }
    }
}
