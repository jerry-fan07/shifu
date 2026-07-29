import Foundation

/// The deterministic half of the automation radar (design.md §6.1): which of
/// the user's recurring *tasks* are substantial enough to be worth an LLM's
/// judgment, and what evidence that judgment gets to see.
///
/// **The unit of candidacy is the task, not the label.** Mining transitions
/// between domains and bundle tails is what the original miner did, and it
/// produced suggestions about websites rather than about work — "google.com
/// visited 255× → set up Google Analytics 4". Tasks already carry the user's
/// intent (`SemanticTaskGrouper` names them at goal level), their `task_logs`
/// carry recurrence, and their blocks carry the schedule, the sources and the
/// samples. So the miner ranks tasks and builds one *dossier* per candidate;
/// `Radar` then asks the model whether the workflow that dossier describes is
/// worth automating at all.
///
/// One non-task kind survives: a page glanced at many times a day for seconds
/// at a time never accrues the minutes to mint a task, yet it is the clearest
/// automation signal there is — an alerting gap (`grafana` checked 14×/day).
///
/// This file is pure: thresholds, the dossier type, and the stats helpers over
/// rows. The database loader lives in `PatternMinerEvidence.swift`.
public enum PatternMiner {
    /// Mining window. Long enough for "3 separate days" to mean a habit,
    /// short enough that the evidence is still what the user is doing now.
    public static let windowDays = 14
    /// A task earns a dossier only if it recurred on this many separate days —
    /// one long afternoon is a job, not a routine, and nothing about it repeats
    /// often enough for setup effort to pay back.
    public static let minDaysActive = 3
    /// …and only with this much time behind it in the window. Below it there
    /// is nothing to save even if the automation were free.
    public static let minTotalMinutes: Double = 20
    /// The second door in: fewer days, but enough hours that the recurrence is
    /// not really in doubt. Tuned against the dogfood ledger, where the
    /// intent-level (`sem:`) layer is by nature the *youngest* thing in the
    /// database — a task the LLM named this week cannot yet show five days,
    /// and requiring three would have meant the tab stayed empty for a
    /// fortnight after every fresh install.
    public static let substantialDaysActive = 2
    public static let substantialMinutes: Double = 60

    /// Whether a task's window is worth a dossier at all (§6.1).
    public static func qualifies(daysActive: Int, totalMinutes: Double) -> Bool {
        if daysActive >= minDaysActive, totalMinutes >= minTotalMinutes { return true }
        return daysActive >= substantialDaysActive && totalMinutes >= substantialMinutes
    }
    /// Dossiers per weekly run, ranked by observed minutes. A cap on LLM spend
    /// and on the queue the user has to read: this tab is worth more with 3
    /// good rows than with 30.
    public static let candidateLimit = 12
    /// Polling: this many visits a day to one domain, each shorter than
    /// `pollingMaxVisitMs`.
    public static let pollingVisitsPerDay: Double = 10
    public static let pollingMaxVisitMs: Int64 = 120_000
    /// Share of a domain's glances that must already belong to a task
    /// candidate before the polling reading is dropped as a duplicate of it.
    public static let pollingClaimedShare = 0.5
    /// Observations sampled per candidate, spread across the whole window.
    static let sampleCount = 8
    static let titleSampleLimit = 4
    public static let textSampleChars = 300
    /// Sources shown — in the evidence line and in the prompt.
    public static let topSourceLimit = 3
    /// Sources a dossier *keeps*. More than it shows, because the polling
    /// detector asks "is this domain already inside a named task?" and a
    /// dashboard glanced at all day is exactly the kind of source that ranks
    /// fourth in the task it belongs to.
    public static let sourceMemoryLimit = 8
    static let logSummaryLimit = 3
    /// A↔B alternation inside a task: how many bouts before it is worth a line
    /// of evidence, how short each block must be to read as copying rather
    /// than as two pieces of work, and how close together the blocks must sit
    /// for it to be one bout — without the gap, a task that alternates every
    /// morning reads as a single week-long bout instead of five.
    static let alternationMinBouts = 3
    static let alternationMaxBlockMs: Int64 = 90_000
    static let alternationMaxGapMs: Int64 = 5 * 60_000

    /// Time the user spends *not* working is not an automation opportunity,
    /// and a block nobody could classify is not evidence of anything.
    /// `communication` and `admin` deliberately stay eligible — mail triage
    /// and expense filing are exactly the chores worth handing to a tool.
    public static let leisureCategories: Set<Category> = [
        .entertainment, .social, .privateTime, .unclassified
    ]

    /// Search engines are navigation, not polling: they are visited briefly
    /// and constantly by definition, which is what made the old miner rank
    /// "google.com" above everything the user actually did. Grounded in the
    /// dogfood ledger rather than exhaustive — a missed engine costs one junk
    /// candidate, so add it here when one shows up.
    public static let searchDomains: Set<String> = [
        "bing.com", "duckduckgo.com", "search.brave.com", "search.yahoo.com",
        "ecosia.org", "startpage.com", "baidu.com", "yandex.com", "perplexity.ai"
    ]

    /// True for search engines, including every Google country domain
    /// (`google.com`, `google.co.uk`) without enumerating them.
    public static func isSearchDomain(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return host.hasPrefix("google.") || searchDomains.contains(host)
    }

    /// A page on the internet, as opposed to a piece of the browser. Chrome's
    /// internal UI arrives through the same `url` field as everything else —
    /// `chrome://new-tab-page`, `chrome://contextual-tasks`, the
    /// `*.top-chrome` WebUI hosts — and the dogfood ledger's second-busiest
    /// "site" was `omnibox-popup.top-chrome`, i.e. the address bar's own
    /// dropdown. None of it is a place the user went.
    public static func isRealSite(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return host.contains(".") && !host.hasSuffix("-chrome")
    }

    /// True for task keys whose *name* says what the user was doing: `sem:`
    /// (the LLM's goal-level title) and `topic:` (the classifier's short
    /// description of the ongoing task).
    ///
    /// `app:` and `domain:` are the two namespaces that mean "nothing ever
    /// learned what this was" — they name a container ("ghostty", "finder",
    /// "new-tab-page"), and the dogfood ledger ranks them at the top because
    /// containers hold every kind of work at once. A suggestion about a
    /// container is the altitude bug this rewrite exists to fix, however good
    /// the model is, so they never become task candidates. Domains keep one
    /// honest route in: the polling detector, whose whole claim is the modest
    /// "you keep checking this page".
    public static func namesIntent(taskKey: String) -> Bool {
        taskKey.hasPrefix(SemanticTaskGrouper.keyPrefix) || taskKey.hasPrefix("topic:")
    }

    public static func isLeisure(_ category: Category) -> Bool {
        leisureCategories.contains(category)
    }

    // MARK: - The dossier

    public enum Kind: String, Sendable {
        /// A recurring, substantial task — the primary kind.
        case task
        /// A domain glanced at all day: the alerting gap.
        case polling
    }

    /// Everything the describer is shown about one automation candidate.
    /// In-memory only: a dossier is rebuilt from the ledger every weekly run,
    /// so an undescribed row simply gets a fresh one next week and nothing
    /// about it needs persisting beyond the `suggestions` row itself.
    public struct Candidate: Equatable, Sendable {
        /// Stable identity across mining runs and the unique key on
        /// `suggestions` — `"task:<task_key>"` or `"freq:<domain>"`. This is
        /// what keeps a dismissed candidate dismissed when it is mined again.
        public var key: String
        public var kind: Kind
        /// What the user would call this: the task's name, or the domain.
        public var name: String
        public var gist: String?
        public var daysActive: Int
        public var totalMinutes: Double
        /// What "it recurred" means for this kind, and what a dismissal
        /// remembers: days active for a task, visits for a polling domain.
        /// The resurface rule ("returns when this doubles") therefore reads as
        /// "the habit doubled", not "the clock ran twice as long".
        public var occurrences: Int
        /// "weekday mornings, usually 9–11" — see `scheduleLine`.
        public var schedule: String
        /// Where the time went, most first.
        public var sources: [Source]
        /// Derived observations that don't fit a column: the alternation
        /// signature, the polling cadence. Evidence, never a suggestion of
        /// their own.
        public var signals: [String]
        /// The task's own recent day-log lines.
        public var logSummaries: [String]
        public var titles: [String]
        public var textSample: String

        public init(
            key: String, kind: Kind, name: String, gist: String? = nil,
            daysActive: Int, totalMinutes: Double, occurrences: Int,
            schedule: String, sources: [Source] = [], signals: [String] = [],
            logSummaries: [String] = [], titles: [String] = [], textSample: String = ""
        ) {
            self.key = key
            self.kind = kind
            self.name = name
            self.gist = gist
            self.daysActive = daysActive
            self.totalMinutes = totalMinutes
            self.occurrences = occurrences
            self.schedule = schedule
            self.sources = sources
            self.signals = signals
            self.logSummaries = logSummaries
            self.titles = titles
            self.textSample = textSample
        }

        /// Minutes per occurrence — per day for a task, per visit for a
        /// polling domain. Derived, because it is `totalMinutes` over the
        /// recurrence by definition in both kinds.
        public var avgMinutes: Double {
            totalMinutes / Double(max(1, occurrences))
        }

        /// The `tasks.key` behind a task candidate — `key` minus its
        /// namespace. Empty for a polling domain, which has no task row.
        public var taskKey: String {
            kind == .task ? String(key.dropFirst("task:".count)) : ""
        }

        /// Observed minutes a week. Pre-describe this is what
        /// `est_minutes_saved_weekly` holds — *time at stake*, not time saved;
        /// the describer overwrites it with a grounded estimate before any of
        /// it reaches the user (see `Suggestion.estMinutesSavedWeekly`).
        public var weeklyMinutes: Double {
            totalMinutes / Double(windowDays) * 7
        }

        /// The one line stored on the row and shown under the title. What
        /// counts as the headline fact differs by kind — hours for a task,
        /// cadence for a polling loop, whose whole point is that its hours are
        /// negligible:
        ///
        ///     4.2h over 7 days · weekday mornings, usually 9–11 · github.com, Xcode
        ///     168 visits over 14 days, avg 0.5 min · weekday afternoons, usually 14–16
        public var evidenceLine: String {
            let days = "\(daysActive) day\(daysActive == 1 ? "" : "s")"
            switch kind {
            case .task:
                var parts = ["\(SemanticTaskGrouper.durationLabel(minutes: Int(totalMinutes)))"
                    + " over \(days)", schedule]
                if !sources.isEmpty {
                    parts.append(sources.prefix(topSourceLimit).map(\.label)
                        .joined(separator: ", "))
                }
                return parts.joined(separator: " · ")
            case .polling:
                // The domain *is* the name here, so a source list would just
                // repeat the title; the cadence is the fact.
                return "\(occurrences) visits over \(days), avg "
                    + String(format: "%.1f", avgMinutes) + " min · " + schedule
            }
        }
    }

    /// One place a candidate's time went.
    public struct Source: Equatable, Sendable {
        public var label: String        // domain, else the app's short name
        public var minutes: Double

        public init(label: String, minutes: Double) {
            self.label = label
            self.minutes = minutes
        }
    }

    /// One activity block reduced to what the pure stats need.
    public struct Block: Equatable, Sendable {
        public var startedAt: Int64
        public var durationMs: Int64
        /// Domain when the block has one, else the app's short name — what a
        /// human would say they were in.
        public var label: String
        public var category: Category

        public init(startedAt: Int64, durationMs: Int64, label: String, category: Category) {
            self.startedAt = startedAt
            self.durationMs = durationMs
            self.label = label
            self.category = category
        }
    }

    // MARK: - Stats over blocks (pure, testable)

    /// The category a candidate's *time* is in, not the one most of its blocks
    /// are: a two-hour work block outweighs six one-minute detours, which is
    /// the whole reason the leisure filter is time-weighted.
    public static func dominantCategory(_ blocks: [Block]) -> Category? {
        var msByCategory: [Category: Int64] = [:]
        for block in blocks { msByCategory[block.category, default: 0] += block.durationMs }
        return msByCategory.max { lhs, rhs in
            (lhs.value, lhs.key.rawValue) < (rhs.value, rhs.key.rawValue)
        }?.key
    }

    /// Where the time went, most first.
    public static func topSources(_ blocks: [Block], limit: Int = topSourceLimit) -> [Source] {
        var msByLabel: [String: Int64] = [:]
        for block in blocks { msByLabel[block.label, default: 0] += block.durationMs }
        return msByLabel
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map { Source(label: $0.key, minutes: Double($0.value) / 60_000) }
    }

    /// Distinct local days the blocks touch.
    public static func daysActive(_ starts: [Int64], calendar: Calendar = .current) -> Int {
        Set(starts.map {
            calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0) / 1_000))
        }).count
    }

    // MARK: - Schedule

    /// Named parts of the day. The gaps are deliberate: 23:00–05:00 is one
    /// bucket ("late nights") handled by `dayPart`.
    static let dayParts: [(name: String, range: Range<Int>)] = [
        ("mornings", 5..<12), ("afternoons", 12..<18), ("evenings", 18..<23)
    ]

    static func dayPart(ofHour hour: Int) -> String {
        dayParts.first { $0.range.contains(hour) }?.name ?? "late nights"
    }

    /// "weekday mornings, usually 9–11" — when this work actually happens, in
    /// the words a person would use. Regularity is itself an automation signal
    /// (a thing that happens every weekday at 9 can be *scheduled*), and it is
    /// the part of the evidence a model cannot infer from totals.
    ///
    /// Deliberately hedged: a shape is only named when the mass is genuinely
    /// concentrated, otherwise this says "spread across the day" rather than
    /// inventing a routine out of noise.
    public static func scheduleLine(starts: [Int64], calendar: Calendar = .current) -> String {
        guard !starts.isEmpty else { return "no regular time" }
        var hours: [Int] = []
        var weekdayCount = 0
        for ms in starts {
            let date = Date(timeIntervalSince1970: Double(ms) / 1_000)
            hours.append(calendar.component(.hour, from: date))
            if !calendar.isDateInWeekend(date) { weekdayCount += 1 }
        }
        let weekdayShare = Double(weekdayCount) / Double(starts.count)
        let dayShape = weekdayShare >= 0.85 ? "weekday"
            : (weekdayShare <= 0.35 ? "weekend" : "most days")

        let counts = Dictionary(grouping: hours) { dayPart(ofHour: $0) }
        let days = dayShape == "most days" ? "most days" : "\(dayShape)s"
        guard let part = counts.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              Double(part.value.count) / Double(hours.count) >= 0.6 else {
            return "\(days), spread across the day"
        }
        // The late-night bucket wraps midnight, so 23:00 and 00:30 sort to
        // opposite ends of a numeric list and the range reads "0–23". Shift
        // the small hours past midnight before taking the spread, and shift
        // back for display.
        let inPart = part.value.map { $0 < 5 ? $0 + 24 : $0 }.sorted()
        let low = inPart[inPart.count / 5] % 24
        let high = inPart[inPart.count - 1 - inPart.count / 5] % 24
        let when = low == high ? "usually around \(low):00" : "usually \(low)–\(high)"
        let shape = dayShape == "most days" ? "most days, \(part.key)" : "\(dayShape) \(part.key)"
        return "\(shape), \(when)"
    }

    // MARK: - Signals

    /// Rapid A↔B alternation with copy-adjacent dwell times — §6.1's
    /// manual-transfer signature, **demoted from a suggestion of its own to a
    /// line of evidence** on the task it happens inside. On its own it only
    /// ever said "you switched between Chrome and Terminal a lot", which is
    /// not a workflow; attached to a task it says *what* the user was moving
    /// by hand, and the describer can name the transfer.
    public static func alternationSignal(_ blocks: [Block]) -> String? {
        let sorted = blocks.sorted { $0.startedAt < $1.startedAt }
        var bouts: [String: (count: Int, totalMs: Int64)] = [:]
        var index = 0
        while index + 3 < sorted.count {
            let labelA = sorted[index].label
            let labelB = sorted[index + 1].label
            guard labelA != labelB,
                  sorted[index].durationMs < alternationMaxBlockMs,
                  sorted[index + 1].durationMs < alternationMaxBlockMs,
                  adjacent(sorted[index], sorted[index + 1]) else {
                index += 1
                continue
            }

            // Extend a maximal a,b,a,b… run (each block matches two back).
            // A long block *ends* the bout rather than disqualifying it — a
            // settled stretch of work after four quick hops is still four
            // quick hops, and vetoing the whole run threw the bout away.
            var end = index + 1
            while end + 1 < sorted.count, sorted[end + 1].label == sorted[end - 1].label,
                  sorted[end + 1].durationMs < alternationMaxBlockMs,
                  adjacent(sorted[end], sorted[end + 1]) {
                end += 1
            }
            if end - index + 1 >= 4 {
                let pair = [labelA, labelB].sorted().joined(separator: " ↔ ")
                let ms = sorted[index...end].reduce(Int64(0)) { $0 + $1.durationMs }
                bouts[pair, default: (0, 0)].count += 1
                bouts[pair]!.totalMs += ms
                index = end + 1
            } else {
                index += 1
            }
        }
        guard let top = bouts.filter({ $0.value.count >= alternationMinBouts })
            .max(by: { $0.value.count < $1.value.count }) else { return nil }
        let avgMinutes = Double(top.value.totalMs) / Double(top.value.count) / 60_000
        return "rapid back-and-forth \(top.key) — \(top.value.count) bouts, "
            + "avg \(String(format: "%.1f", avgMinutes)) min each "
            + "(looks like moving something by hand)"
    }

    /// Two blocks close enough in time to belong to the same bout.
    private static func adjacent(_ first: Block, _ second: Block) -> Bool {
        second.startedAt - (first.startedAt + first.durationMs) <= alternationMaxGapMs
    }

    /// Ranked by time observed and capped: the describer's spend and the
    /// user's attention are both bounded by this.
    public static func ranked(_ candidates: [Candidate], limit: Int = candidateLimit) -> [Candidate] {
        Array(candidates.sorted { ($0.totalMinutes, $1.key) > ($1.totalMinutes, $0.key) }
            .prefix(limit))
    }
}
