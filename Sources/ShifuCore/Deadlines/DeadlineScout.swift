import Foundation

/// Noticing a dated commitment in screen text, and judging how much it is
/// likely to matter (design.md §4.7).
///
/// Pure: a line of text, where it was seen, and the moment it was seen go in;
/// zero or more `Hit`s come out, each with a score the caller turns into a
/// tier. Nothing here touches the database or a model — the lexicon, the
/// signals and the thresholds were set by reading two weeks of the real
/// dogfood corpus (6,660 dated lines with a trigger word, 2026-10-02) and are
/// re-earned with `shifu due scan` against a copy of it, never from fixtures.
///
/// The shape is the one design.md §12 asked for when this was last measured
/// against: an explicit dated shape, in an app that is not Shifu, proposed
/// into a queue the user accepts from — never recorded as a deadline on its
/// own. What the scorer adds is the *ranking*: the same screen shows "Late Due
/// Date: Sep 25 at 12:00PM" and "Sharpe Refectory closes dinner in 28
/// minutes", and the difference between them is a handful of signals that
/// can be named.
public enum DeadlineScout {
    /// What kind of date it is. The order is the display order and roughly
    /// the prior — an exam date matters more often than a product launch.
    public enum Category: String, CaseIterable, Codable, Sendable {
        case exam, submission, application, admin, travel, event, offer, release

        /// The scorer's prior for the kind of thing this is, before any
        /// signal from where or how it was seen.
        var prior: Int {
            switch self {
            case .exam, .submission: return 2
            case .application, .admin, .travel: return 1
            case .event: return 0
            case .offer, .release: return -2
            }
        }

        public var label: String {
            switch self {
            case .exam: return "Exam"
            case .submission: return "Due"
            case .application: return "Apply"
            case .admin: return "Admin"
            case .travel: return "Travel"
            case .event: return "Event"
            case .offer: return "Offer"
            case .release: return "Release"
            }
        }
    }

    /// How much a hit seems to matter. Four steps, because the Spotted band
    /// shows two of them openly, folds one, and the fourth exists only so a
    /// dismissal is remembered against noise that recurs.
    public enum Tier: Int, Comparable, Codable, Sendable, CaseIterable {
        case low = 0, normal = 1, high = 2, critical = 3

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .critical: return "Critical"
            case .high: return "High"
            case .normal: return "Normal"
            case .low: return "Low"
            }
        }

        /// Score → tier. The cut points come from the calibration run over
        /// the dogfood copy (2026-10-02): graded submissions, exam dates and
        /// "sign up by Monday" sit at 9+; application deadlines and dated
        /// invitations at 6–8; events worth knowing about at 2–5; dated
        /// social posts, search results and opening hours at 1 and below.
        public static func of(score: Int) -> Tier {
            switch score {
            case 9...: return .critical
            case 6...8: return .high
            case 2...5: return .normal
            default: return .low
            }
        }
    }

    /// Where a line was seen — everything the scorer reads besides the words.
    public struct Source: Equatable, Sendable {
        public var appBundle: String
        public var domain: String?
        public var windowTitle: String?
        /// The task the block was filed to, when the ledger has one.
        public var taskID: Int64?
        /// Unix ms: when the text was on screen. Dates resolve against this.
        public var seenAt: Int64

        public init(
            appBundle: String, domain: String? = nil, windowTitle: String? = nil,
            taskID: Int64? = nil, seenAt: Int64
        ) {
            self.appBundle = appBundle
            self.domain = domain
            self.windowTitle = windowTitle
            self.taskID = taskID
            self.seenAt = seenAt
        }
    }

    /// One dated commitment the scout found.
    public struct Hit: Equatable, Sendable {
        /// `<due day>|<slug of the words around the date>` — the identity a
        /// repeat sighting matches on. The app is deliberately not part of
        /// it: the same RSVP line appeared under four Mail window titles.
        public var key: String
        /// The line with the date taken out of it, trimmed to a banner's
        /// width. A model may improve on it later; this is what stands if
        /// none does.
        public var title: String
        /// The window the line was read in, stripped of the browser's suffix
        /// — "Fall 2026 CSCI 1420 Dashboard" beside "Late Due Date".
        public var context: String?
        public var dueAt: Int64
        public var allDay: Bool
        public var category: Category
        public var score: Int
        /// The original line, as evidence. Capped so a wall of text stays a
        /// clause.
        public var evidence: String
        /// The named signals that made the score, for `shifu due scan` and
        /// for anyone asking why.
        public var signals: [String]

        public var tier: Tier { Tier.of(score: score) }
    }

    /// Below this a hit is not worth a row even as a remembered dismissal —
    /// it is dining hours or a dated tweet, and the next sighting will score
    /// the same.
    public static let floor = -3
    /// Lines longer than this are articles, not notices.
    static let longLine = 240
    static let titleLimit = 90
    static let evidenceLimit = 200
    static let anchorWords = 6

    // MARK: - Scanning

    /// Every hit in a block of text. Each line is read on its own; the
    /// window title is read as a line too, because a tab title is often the
    /// clearest statement of the date on the page.
    public static func scan(
        text: String?, source: Source, calendar: Calendar = .current
    ) -> [Hit] {
        guard !ScoutLexicon.isIgnoredBundle(source.appBundle) else { return [] }
        var lines: [String] = []
        if let title = source.windowTitle { lines.append(title) }
        if let text {
            lines.append(contentsOf: text.components(separatedBy: .newlines))
        }
        var seen: Set<String> = []
        var hits: [Hit] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 8, seen.insert(line).inserted else { continue }
            hits.append(contentsOf: scanLine(line, source: source, calendar: calendar))
        }
        return hits
    }

    /// One line. A line needs a date *and* a trigger word to be a hit at
    /// all; the score then says how much the two of them, where they were
    /// seen, are worth.
    static func scanLine(_ line: String, source: Source, calendar: Calendar) -> [Hit] {
        // One hit per line, on its first date: "Midterm 1: October 14.
        // Midterm 2: Nov 11" is two dates, but the second will be read on
        // its own the next time the page is on screen with a line break
        // between them — and one line that yields two rows from a single
        // sighting is how a list of dates becomes a pile of proposals.
        guard let date = SpottedDate.first(in: line, seenAt: source.seenAt, calendar: calendar) else { return [] }
        let lowered = line.lowercased()
        // A line needs a trigger word, or the date written as a bound ("by
        // Monday") — the bound is itself the commitment, whatever the line
        // is about.
        let bound = ScoutLexicon.isBound(before: date.range, in: line)
        let found = ScoutLexicon.trigger(in: lowered)
        guard found != nil || bound else { return [] }
        let trigger = found ?? ScoutLexicon.Trigger(word: "by", category: .submission, strength: 3)
        let strength = bound ? max(trigger.strength, 3) : trigger.strength
        var tally = Tally(score: strength + trigger.category.prior, signals: [
            "\(trigger.word):+\(strength)", "\(trigger.category.rawValue):\(trigger.category.prior)"
        ])
        if bound && found != nil { tally.signals.append("bound") }
        tally.addShape(of: date, seenAt: source.seenAt, calendar: calendar)
        tally.addPlace(source)
        tally.addPhrasing(line: line, lowered: lowered, date: date, seenAt: source.seenAt, calendar: calendar)
        guard tally.score > floor else { return [] }
        let stripped = removing(date.range, from: line)
        return [Hit(
            key: key(dueAt: date.dueAt, words: stripped, calendar: calendar),
            title: title(from: stripped, fallback: line),
            context: ScoutLexicon.windowContext(source.windowTitle, line: line),
            dueAt: date.dueAt, allDay: date.allDay, category: trigger.category,
            score: tally.score, evidence: String(line.prefix(evidenceLimit)), signals: tally.signals)]
    }

    /// The running score and the names of what made it. Three passes, one
    /// per kind of signal, so each stays readable as a list.
    struct Tally {
        var score: Int
        var signals: [String]

        mutating func add(_ points: Int, _ name: String) {
            guard points != 0 else { return }
            score += points
            signals.append("\(name):\(points > 0 ? "+" : "")\(points)")
        }

        /// How the date itself was written.
        mutating func addShape(of date: SpottedDate.Match, seenAt: Int64, calendar: Calendar) {
            if date.hasClock { add(1, "clock") }
            if date.hasWeekday && !date.relative { add(1, "weekday") }
            if date.relative { add(-1, "relative") }
            if date.numeric { add(-1, "numeric") }
            if DeadlineHorizon.daysUntil(dueAt: date.dueAt, now: seenAt, calendar: calendar) > 90 {
                add(-1, "far")
            }
        }

        /// Where it was seen.
        mutating func addPlace(_ source: Source) {
            if source.taskID != nil { add(1, "task") }
            if ScoutLexicon.isCommitmentApp(source.appBundle) { add(2, "app") }
            if let domain = source.domain {
                if ScoutLexicon.isCommitmentDomain(domain) { add(2, "domain") }
                if ScoutLexicon.isNoiseDomain(domain) { add(-3, "noise-domain") }
            }
            if ScoutLexicon.isDeveloperBundle(source.appBundle)
                || source.domain.map(ScoutLexicon.isDeveloperDomain) == true { add(-2, "dev") }
            if ScoutLexicon.isSearchResults(source.windowTitle) { add(-2, "search") }
        }

        /// What the words around it say.
        mutating func addPhrasing(
            line: String, lowered: String, date: SpottedDate.Match, seenAt: Int64, calendar: Calendar
        ) {
            if ScoutLexicon.addressesReader(lowered) { add(1, "you") }
            if ScoutLexicon.isHoursOfOperation(lowered, calendarDate: date.calendarDate) { add(-6, "hours") }
            let seenYear = calendar.component(.year, from: Date(timeIntervalSince1970: Double(seenAt) / 1_000))
            if ScoutLexicon.mentionsHistory(lowered, seenYear: seenYear) { add(-2, "history") }
            if ScoutLexicon.isTimestampMetadata(before: date.range, in: line) { add(-3, "metadata") }
            if ScoutLexicon.isPastTense(before: date.range, in: line) { add(-2, "past") }
            if ScoutLexicon.isDatedFilename(lowered) { add(-3, "filename") }
            if line.count > 2 * longLine { add(-2, "wall") } else if line.count > longLine { add(-1, "long") }
        }
    }

    // MARK: - Words

    /// The line without its date, tidied: OCR leaves ",." and " ." behind
    /// where the date was, and a title that starts with "by" or ":" reads as
    /// a fragment.
    static func removing(_ range: Range<String.Index>, from line: String) -> String {
        var text = line
        text.removeSubrange(range)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // "(due !)" and "()" are what a date leaves behind inside brackets.
        text = text.replacingOccurrences(of: "\\(\\s*(?:due|by|on|at)?\\s*[!?.,;:]*\\s*\\)", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\*+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*[,.;:–-]+\\s*([,.;:–-]|$)", with: "$1",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "^[\\s,.;:–-]+|[\\s,.;:–-]+$", with: "",
                                         options: .regularExpression)
        // A preposition the date left dangling: "apply by (eligible)", "due on".
        text = text.replacingOccurrences(
            of: "\\s+(?:by|on|at|before|until|till|through)(?=\\s*[(),.;:]|$)", with: "",
            options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func title(from stripped: String, fallback: String) -> String {
        let base = stripped.count >= 4 ? stripped : fallback
        guard base.count > titleLimit else { return base }
        let cut = base.prefix(titleLimit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 40 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// `2026-09-25|late-due-date`: the due *day* plus the first few words.
    public static func key(dueAt: Int64, words: String, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(dueAt) / 1_000))
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let stamp = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let slugged = TaskGrouper.slug(words).split(separator: "-")
            .filter { $0.count > 1 && Int($0) == nil }
            .prefix(anchorWords).joined(separator: "-")
        return "\(stamp)|\(slugged.isEmpty ? "date" : slugged)"
    }
}
