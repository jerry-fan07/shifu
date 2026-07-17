import Foundation

/// Folds raw observations into activity blocks (design.md §4.1):
/// same app + domain, gaps under 2 minutes, split on idle.
/// Pure function over rows — all policy testable without a database.
public enum Sessionizer {
    /// A gap of user absence longer than this splits a block.
    public static let gapThresholdMs: Int64 = 120_000

    public struct Block: Equatable, Sendable {
        public var appBundle: String
        public var domain: String?
        public var startedAt: Int64
        public var endedAt: Int64
        public var observationIDs: [Int64]
        public var titles: [String]
        /// True when every observation was exclusion-kind (no content captured).
        public var excluded: Bool

        public var durationMs: Int64 { endedAt - startedAt }
    }

    /// Observations must be sorted by `startedAt` (the analyzer queries them so).
    public static func sessionize(_ observations: [Observation]) -> [Block] {
        var blocks: [Block] = []
        var current: Block?

        for obs in observations {
            let domain = Self.domain(of: obs.url)
            let key = (obs.appBundle, domain)

            if var block = current {
                let sameKey = block.appBundle == key.0 && block.domain == key.1
                let gap = obs.startedAt - block.endedAt
                if sameKey && gap < gapThresholdMs {
                    // Extend the current block.
                    block.endedAt = max(block.endedAt, obs.lastSeen)
                    if let id = obs.id { block.observationIDs.append(id) }
                    if let title = obs.windowTitle, !title.isEmpty, !block.titles.contains(title) {
                        block.titles.append(title)
                    }
                    block.excluded = block.excluded && obs.captureKind == .excluded
                    current = block
                    continue
                }
                // Different app/domain or an idle gap: close the block. If the
                // switch happened promptly, the user was in the old block until
                // the new one began — credit the interval to the old block.
                if gap >= 0 && gap < gapThresholdMs {
                    block.endedAt = obs.startedAt
                }
                blocks.append(block)
            }

            current = Block(
                appBundle: obs.appBundle,
                domain: domain,
                startedAt: obs.startedAt,
                endedAt: max(obs.lastSeen, obs.startedAt),
                observationIDs: obs.id.map { [$0] } ?? [],
                titles: (obs.windowTitle?.isEmpty == false) ? [obs.windowTitle!] : [],
                excluded: obs.captureKind == .excluded
            )
        }
        if let block = current {
            blocks.append(block)
        }
        return blocks
    }

    /// Normalized domain of a URL: lowercase host, `www.` stripped.
    public static func domain(of url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
