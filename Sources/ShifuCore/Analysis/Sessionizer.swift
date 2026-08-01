import Foundation

/// Folds raw observations into activity blocks (design.md §4.1):
/// same app + domain, gaps under 2 minutes, split on idle.
/// Pure function over rows — all policy testable without a database.
public enum Sessionizer {
    /// A gap of user absence longer than this splits a block.
    public static let gapThresholdMs: Int64 = 120_000

    /// One unclassified run of observations sharing an app and domain.
    ///
    /// The sessionizer's output and the classifier's input — it exists only in
    /// memory, between the two. `LedgerBuilder` turns each block into an
    /// `Activity` row; nothing persists a `Block` itself.
    ///
    /// Blocks are reproduced **deterministically** from the same observations,
    /// which is what makes the analyzer's rebuild idempotent: an unchanged
    /// stretch of the day re-sessionizes to byte-identical spans, so the
    /// rebuild can recognize it and carry derived state forward.
    public struct Block: Equatable, Sendable {
        public var appBundle: String
        /// Normalized host, or nil for non-browser blocks. Part of the block's
        /// identity: the same browser on two domains is two blocks.
        public var domain: String?
        public var startedAt: Int64
        /// Unix ms. May be extended past the last observation's `lastSeen` when
        /// the user switched away promptly — the interval up to the next
        /// block's start is credited here rather than being lost.
        public var endedAt: Int64
        /// Every observation folded in, in order. `LedgerBuilder` writes these
        /// back as `observations.session_id`.
        public var observationIDs: [Int64]
        /// Distinct non-empty window titles seen, in first-seen order. Feeds
        /// the LLM prompt and the durable block signature.
        public var titles: [String]
        /// True when every observation was exclusion-kind (no content captured).
        public var excluded: Bool

        public var durationMs: Int64 { endedAt - startedAt }

        public init(
            appBundle: String, domain: String?, startedAt: Int64, endedAt: Int64,
            observationIDs: [Int64], titles: [String], excluded: Bool
        ) {
            self.appBundle = appBundle
            self.domain = domain
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.observationIDs = observationIDs
            self.titles = titles
            self.excluded = excluded
        }
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
                // Different app/domain or an idle gap: close the block at the
                // moment the next one began, so blocks tile the timeline
                // instead of overlapping. A positive gap under the threshold
                // is a prompt switch — the user was in the old block until
                // then, so the interval is credited here. A negative gap means
                // per-window dedupe bumped this block's `last_seen` past the
                // next window's first sighting; trimming is what keeps the
                // same minute from being billed to two blocks. Only a real
                // idle gap leaves `endedAt` alone.
                if gap < gapThresholdMs {
                    block.endedAt = max(block.startedAt, obs.startedAt)
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

    /// Normalized web domain of a URL: lowercase host, `www.` stripped —
    /// http(s) only. Browser-internal schemes (`chrome://`,
    /// `chrome-extension://`, `chrome-error://`, `devtools://`) put a UI
    /// surface where the host belongs ("new-tab-page",
    /// "omnibox-popup.top-chrome", extension ids), and deriving those as
    /// domains minted junk tasks from the browser's own chrome — the dogfood
    /// ledger had 145 min filed under "contextual-tasks". A nil here just
    /// means the block keys by topic or app instead; its time is unaffected.
    public static func domain(of url: String?) -> String? {
        guard let url, let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
