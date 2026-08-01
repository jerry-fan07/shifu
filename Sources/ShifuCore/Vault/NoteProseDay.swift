import Foundation

/// A work note read as *a day* rather than as a document: the head the summary
/// declares, the stretches the front matter declares, and the session prose
/// laid against them.
///
/// Every value here is derived from what the file already says — nothing is
/// invented, and nothing is stored. That is the whole claim of the day view:
/// the note is the record, and the page is a reading of it.
extension NoteProse {
    /// One wall-clock stretch, as the vault writes them ("09:44", "10:39").
    public struct Span: Equatable, Sendable, Identifiable, Hashable {
        public var start: String
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }

        public var id: String { label }
        public var label: String { "\(start)–\(end)" }

        /// Minutes since local midnight. Nil when either end isn't a clock —
        /// and an end before its start is a stretch over midnight, which the
        /// vault never writes, so it is nil too rather than a negative width.
        public var minutes: Range<Int>? {
            guard let from = NoteProse.clock(start), let to = NoteProse.clock(end),
                  to >= from
            else { return nil }
            return from..<max(to, from + 1)
        }
    }

    /// Minutes since midnight for "HH:MM".
    public static func clock(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

    /// The day's outer bracket, "00:00→12:20" — when it started and when it
    /// stopped, which is a different fact from how long it ran.
    public static func bracket(_ spans: [Span]) -> String? {
        guard let first = spans.first, let last = spans.last else { return nil }
        return "\(first.start)→\(last.end)"
    }

    /// The summary line's second half, as a title.
    ///
    /// A work note's first line is "where — what": `claudefordesktop, app —
    /// researching AI harness building; developing Shifu app`. The where is a
    /// list of apps the head sets as chips, so the title is the *what*, with
    /// its semicolons opened out into the one line they always were.
    ///
    /// Empty when the line is only the where — a quiet day the classifier
    /// never named, whose "title" would otherwise be its own chips printed
    /// twice in a heavier weight.
    public static func dayTitle(_ summary: String, sources: [String] = []) -> String {
        let topics = summary.range(of: " — ").map { String(summary[$0.upperBound...]) }
            ?? summary
        if summary.range(of: " — ") == nil, !sources.isEmpty,
           topics.compare(sources.joined(separator: ", "), options: .caseInsensitive) == .orderedSame {
            return ""
        }
        let joined = topics
            .components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        guard let first = joined.first else { return summary }
        return first.uppercased() + joined.dropFirst()
    }

    /// One block of the session prose: the span it leads with, what it says,
    /// and the declared stretches that fall inside it.
    ///
    /// The count matters because the two are not the same fact: a model writes
    /// "00:00–03:27" over three separate stretches, and the note's front matter
    /// is the one that knows there were three.
    public struct SessionBlock: Equatable, Sendable, Identifiable {
        public var span: Span
        public var text: String
        public var covers: [Span]

        public var id: String { span.id }
    }

    /// The `## Sessions` prose, read as blocks against the day's declared
    /// stretches.
    public static func sessionBlocks(_ prose: String, covering spans: [Span]) -> [SessionBlock] {
        lines(prose).compactMap { line in
            guard case .session(let label) = line.kind, let span = span(label) else { return nil }
            let inside = span.minutes.map { range in
                spans.filter { stretch in
                    stretch.minutes.map {
                        $0.lowerBound >= range.lowerBound && $0.lowerBound < range.upperBound
                    } ?? false
                }
            } ?? []
            return SessionBlock(span: span, text: line.text, covers: inside)
        }
    }

    /// The span a session lead declares, read back out of its label: the first
    /// and last clock in it, so a merged label ("13:10–13:12, 14:38–14:40")
    /// still brackets the stretch it covers.
    public static func span(_ label: String) -> Span? {
        var clocks: [String] = []
        var digits = ""
        for character in label + " " {
            if character.isNumber || character == ":" {
                digits.append(character)
            } else {
                if clock(digits) != nil { clocks.append(digits) }
                digits = ""
            }
        }
        guard let first = clocks.first, let last = clocks.last, clocks.count > 1 else {
            return clocks.first.map { Span(start: $0, end: $0) }
        }
        return Span(start: first, end: last)
    }
}
