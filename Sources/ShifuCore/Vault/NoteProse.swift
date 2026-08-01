import Foundation

/// The shape a note body is written in (vault-features.md §2.1), read back out
/// of its Markdown so the UI can *draw* the structure instead of printing it.
///
/// The compiler asks the model for three things — `**HH:MM–HH:MM** — …` session
/// leads, `###` sub-headings, and `-` bullets under them — and a renderer that
/// only knows inline bold shows all three as one grey wall with stray hyphens
/// down the left. Parsing lives here, beside `CardMarkup`, so it stays testable
/// without SwiftUI.
///
/// Line-level rather than block-level on purpose: the inline pass
/// (`CardMarkup.segments`) runs first and can cut one line into several runs,
/// so a line has to be able to stay open across them.
public enum NoteProse {
    /// What a line *is*. Five shapes; anything else is prose.
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        /// A list item, with the marker to set beside it — "•", or the author's
        /// own "3." when the list was numbered, because a renumbered list is a
        /// different claim than the one that was written.
        case bullet(marker: String)
        /// A session lead: the wall-clock span the rest of the line accounts for.
        case session(span: String)
        /// A dated lead: the calendar span the rest of the line accounts for —
        /// the shape a task overview's `## Timeline` is written in
        /// (`**2026-07-19 to 2026-07-27** — …`). Its own kind for the same
        /// reason a session is: the span is a *place on a timeline*, not a
        /// bold word, and the page hangs it in the margin accordingly.
        case dated(span: String)
        /// A line that is nothing but a wiki link — the `## Captured` list.
        /// Its own kind because it is a pointer, not a sentence: the page it
        /// points at is somewhere the reader can go.
        case link(target: String)
    }

    public struct Line: Equatable, Sendable {
        public var kind: Kind
        public var text: String
        /// This line finishes the caller's open line rather than starting one
        /// — see `lines(_:continuing:)`.
        public var continuesPrevious: Bool

        public init(
            kind: Kind = .paragraph, text: String, continuesPrevious: Bool = false
        ) {
            self.kind = kind
            self.text = text
            self.continuesPrevious = continuesPrevious
        }
    }

    /// Splits one plain-text run into logical lines.
    ///
    /// `continuing` says the run picks up mid-line: the caller has already cut
    /// inline code and math out, so "fixed the `agy` retry" arrives as three
    /// runs, and only the first of them starts at a line start. Markers are
    /// read at line starts only — that is what keeps "- 3" in the tail of a
    /// sentence from becoming a bullet.
    ///
    /// A blank line closes the open line; an unmarked line under an open one is
    /// folded into it, so a hard-wrapped bullet stays one bullet.
    public static func lines(_ text: String, continuing: Bool = false) -> [Line] {
        var lines: [Line] = []
        var isOpen = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            if index == 0, continuing {
                // Mid-line, so the leading whitespace is a real space between
                // two words and a leading "-" is a hyphen.
                if !raw.isEmpty { lines.append(Line(text: raw, continuesPrevious: true)) }
                isOpen = !raw.isEmpty
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Leading whitespace is indentation and goes; the *trailing* space
            // is a word gap and stays, because the caller cut this run at an
            // inline span — "Started a `claude-code` upgrade" came back as
            // "Started aclaude-code upgrade" while it was being trimmed.
            let tail = raw.last == " " && !line.isEmpty ? " " : ""
            if line.isEmpty {
                isOpen = false
            } else if let marked = marked(line, tail: tail) {
                lines.append(marked.line)
                isOpen = marked.isOpen
            } else if isOpen, var last = lines.last {
                last.text += "\n" + line + tail
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(text: line + tail))
                isOpen = true
            }
        }
        return lines
    }

    /// The line as one of the marked kinds, nil when it is prose the caller
    /// folds or opens itself. `isOpen` says whether the kind can still absorb
    /// a continuation: a heading closes its line (the one under it is a new
    /// paragraph), and a pointer has no continuation.
    private static func marked(_ line: String, tail: String) -> (line: Line, isOpen: Bool)? {
        if let heading = heading(line) {
            return (Line(kind: .heading(level: heading.level), text: heading.text), false)
        }
        if let session = session(line) {
            return (Line(kind: .session(span: session.span), text: session.text + tail), true)
        }
        if let dated = dated(line) {
            return (Line(kind: .dated(span: dated.span), text: dated.text + tail), true)
        }
        if let bullet = bullet(line) {
            guard let target = wikiLink(bullet.text) else {
                return (Line(kind: .bullet(marker: bullet.marker),
                             text: bullet.text + tail), true)
            }
            return (Line(kind: .link(target: target), text: target), false)
        }
        if tail == " ", let marker = bareMarker(line) {
            // "- `code` …" arrives cut at the backtick, so this run is the
            // marker alone with its content in the next one. The trailing
            // space is the tell: "- " opens a bullet, a line that is just
            // "-" does not.
            return (Line(kind: .bullet(marker: marker), text: ""), true)
        }
        if let target = wikiLink(line) {
            return (Line(kind: .link(target: target), text: target), false)
        }
        return nil
    }

    // MARK: - The markers

    /// `## Title` → ("Title", 2), for `#` through `###`. A `#` with no space
    /// after it is not a heading — `#1` and `#swift` are ordinary text.
    public static func heading(_ line: String) -> (text: String, level: Int)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (title, level)
    }

    /// A list marker with nothing after it — the shape `lines` sees when an
    /// inline span cut the run right after the marker. Normalized the same way
    /// `bullet` normalizes: dash-family to "•", "3)" to "3.".
    private static func bareMarker(_ line: String) -> String? {
        if line.count == 1, let first = line.first, "-*•".contains(first) { return "•" }
        let number = line.prefix(while: \.isNumber)
        guard (1...2).contains(number.count), line.count == number.count + 1,
              let punctuation = line.last, punctuation == "." || punctuation == ")"
        else { return nil }
        return number + "."
    }

    /// `- item`, `* item`, `• item`, `1. item`, `2) item`.
    public static func bullet(_ line: String) -> (marker: String, text: String)? {
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("•", text)
        }
        let number = line.prefix(while: \.isNumber)
        guard (1...2).contains(number.count) else { return nil }
        let rest = line.dropFirst(number.count)
        guard let punctuation = rest.first, punctuation == "." || punctuation == ")",
              rest.dropFirst().first == " "
        else { return nil }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number + ".", text)
    }

    /// `**09:44–10:39** — what happened`, the shape `WorkNoteNarrative` asks
    /// for, with an optional list marker in front of it (models add one) and
    /// the dash that joins the span to the sentence taken off.
    ///
    /// The bold run has to be clock times and nothing else: `**Note:** …` is a
    /// bold lead-in, not a session.
    public static func session(_ line: String) -> (span: String, text: String)? {
        guard let lead = boldLead(line), isClockSpan(lead.lead) else { return nil }
        return (lead.lead, lead.text)
    }

    /// `**2026-07-19 to 2026-07-27** — what happened`, the shape
    /// `TaskOverviewCompiler`'s `## Timeline` bullets come back in. Same
    /// grammar as a session with days for clocks, and the same rule: the bold
    /// run has to be dates and their joiners — or a title that *ends* in a
    /// parenthetical of them, `**Capture daemon debugging (July 20–25)**`,
    /// the other way models write a dated phase. The dates go to the margin
    /// either way; a title stays bold at the head of the prose.
    public static func dated(_ line: String) -> (span: String, text: String)? {
        guard let lead = boldLead(line) else { return nil }
        // Pure dates in either form — "2026-07-28", "July 17–26" — go to the
        // margin as they are.
        if isDateSpan(lead.lead) || !monthDayDates(lead.lead).isEmpty {
            return (lead.lead, lead.text)
        }
        guard lead.lead.hasSuffix(")"),
              let open = lead.lead.range(of: "(", options: .backwards)
        else { return nil }
        let span = String(lead.lead[open.upperBound...].dropLast())
        let title = lead.lead[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, isDateSpan(span) || !monthDayDates(span).isEmpty
        else { return nil }
        // Re-bolded so the title renders as written; the parenthetical alone
        // moves out of the sentence and into the margin.
        return (span, lead.text.isEmpty ? "**\(title)**" : "**\(title)** — \(lead.text)")
    }

    /// The `**lead** — text` shape both timeline kinds share, with an optional
    /// list marker in front (models add one) and the dash that joins the lead
    /// to the sentence taken off.
    private static func boldLead(_ line: String) -> (lead: String, text: String)? {
        var head = Substring(line)
        if let first = head.first, "-*•".contains(first), head.dropFirst().first == " " {
            head = head.dropFirst(2)
        }
        guard head.hasPrefix("**") else { return nil }
        let rest = head.dropFirst(2)
        guard let close = rest.range(of: "**") else { return nil }
        let lead = rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        var text = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
        for dash in ["—", "–", "-", ":"] where text.hasPrefix(dash) {
            text = String(text.dropFirst(dash.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return (lead, text)
    }

    /// "09:44–10:39", and the comma-joined pair a model writes when it merges
    /// two stretches into one lead.
    private static let spanCharacters = Set("0123456789:–—-, ")

    static func isClockSpan(_ text: String) -> Bool {
        guard text.first?.isNumber == true, text.contains(":") else { return false }
        return text.allSatisfy { spanCharacters.contains($0) }
    }

    /// `[[Some note]]`, and nothing else on the line.
    public static func wikiLink(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]"), trimmed.count > 4
        else { return nil }
        let target = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        return target.isEmpty || target.contains("[[") ? nil : target
    }

    // MARK: - What a list is

    /// What a run of list items *is*, read from the items' own grammar rather
    /// than from the heading above them. The vault's lists are written by a
    /// model against a prompt that asks for *shapes* — "bullets pairing what
    /// went wrong with what fixed it", "bullets, each with the reason behind
    /// it" — so the shape is in the sentences, and a heading is only what one
    /// model called them that day.
    public enum ListShape: Equatable, Sendable {
        /// Sentences. A bullet and a hanging indent.
        case plain
        /// Two halves across an arrow: `problem → fix`.
        case pairs
        /// Claims long enough to carry their own reason.
        case claims
    }

    /// The heading over a list settles its shape before the grammar is asked:
    /// "Problems → fixes" and "Learned / decided" are the §2.1 contract, the
    /// prompt asks for those shapes by name, and one bullet whose clause break
    /// the splitter misses should degrade *that row*, not knock the whole
    /// section back to a column of hyphens. Grammar still decides for every
    /// other list, where a heading is only what one model called it that day.
    public static func shape(of items: [String], under heading: String? = nil) -> ListShape {
        guard !items.isEmpty else { return .plain }
        if let named = heading.flatMap({ declared($0, items: items) }) { return named }
        guard items.count > 1 else { return .plain }
        if items.allSatisfy({ pairBreak($0) != nil }) { return .pairs }
        if items.allSatisfy({ claimBreak($0) != nil }) { return .claims }
        return .plain
    }

    /// The shape a §2.1 heading declares — held to lists that bear it out at
    /// least once, so a section the model filled with something else entirely
    /// still falls back to what the sentences say.
    ///
    /// "Timeline" is here for the bullets that *stay* bullets under it: a
    /// dated lead already left the list for the rail, so what remains is the
    /// titled, dateless kind — a countable sequence of phases, which is
    /// exactly what the claims table is for.
    private static func declared(_ heading: String, items: [String]) -> ListShape? {
        let name = heading.lowercased()
        if name.contains("problem"), name.contains("fix") {
            return items.contains { pairBreak($0) != nil } ? .pairs : nil
        }
        if name.contains("learned") || name.contains("decided") { return .claims }
        if name.contains("timeline") { return .claims }
        return nil
    }

    /// Where one item comes apart, in characters: what the first half ends at,
    /// what the second half starts at, and the word the split ate and has to
    /// put back ("…, so X" reads as "so X", not as "X").
    ///
    /// Offsets rather than two strings because the caller is holding styled
    /// text by then — an item can carry inline code — and slicing it is the
    /// only way to keep that styling through the split.
    public struct Break: Equatable, Sendable {
        public var head: Int
        public var tail: Int
        public var lead: String

        public init(head: Int, tail: Int, lead: String = "") {
            self.head = head
            self.tail = tail
            self.lead = lead
        }
    }

    /// `problem → fix`. Also accepts the ASCII arrow a model sometimes types.
    public static func pairBreak(_ text: String) -> Break? {
        let characters = Array(text)
        for arrow in ["→", "->"] {
            guard let at = index(of: Array(arrow), in: characters, after: 0) else { continue }
            let head = trimmedEnd(characters, before: at)
            let tail = trimmedStart(characters, from: at + arrow.count)
            guard head > 0, tail < characters.count else { continue }
            return Break(head: head, tail: tail)
        }
        return nil
    }

    /// `Label: sentence` — a titled item's own seam, the shape overview
    /// timelines and knowledge lists are written in. The colon has to come
    /// early to be a label's (past ~64 characters it is punctuation inside a
    /// sentence) and the label can't already contain a finished sentence.
    public static func labelBreak(_ text: String) -> Break? {
        let characters = Array(text)
        var best: Break?
        for mark in [": ", " — "] {
            guard let at = index(of: Array(mark), in: characters, after: 0),
                  (1...64).contains(at), best.map({ at < $0.head }) ?? true,
                  !text.prefix(at).contains(". ")
            else { continue }
            best = Break(head: at, tail: at + mark.count)
        }
        guard let best, best.tail < characters.count else { return nil }
        return best
    }

    /// The first clause break past the claim — the item's own grammar, not a
    /// heading's promise. Held to items long enough to *have* two halves: a
    /// short bullet split in two reads as a stutter, not as a reason.
    public static func claimBreak(_ text: String) -> Break? {
        let characters = Array(text)
        guard characters.count > 48 else { return nil }
        var best: Break?
        for (mark, lead) in [(", so ", "so "), (" because ", "because "),
                             ("; ", ""), (" — ", "")] {
            // The mark's *first* occurrence has to be past the claim: a
            // sentence that breaks at character 6 was never two halves.
            guard let at = index(of: Array(mark), in: characters, after: 0), at > 24,
                  best.map({ at < $0.head }) ?? true
            else { continue }
            best = Break(head: at, tail: at + mark.count, lead: lead)
        }
        guard let best, best.tail < characters.count else { return nil }
        return best
    }

    private static func index(
        of needle: [Character], in haystack: [Character], after start: Int
    ) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for at in start...(haystack.count - needle.count)
        where Array(haystack[at..<(at + needle.count)]) == needle {
            return at
        }
        return nil
    }

    private static func trimmedEnd(_ characters: [Character], before index: Int) -> Int {
        var end = index
        while end > 0, characters[end - 1] == " " { end -= 1 }
        return end
    }

    private static func trimmedStart(_ characters: [Character], from index: Int) -> Int {
        var start = index
        while start < characters.count, characters[start] == " " { start += 1 }
        return start
    }

    // MARK: - Inline text

    /// Text on its way to an inline-Markdown parser, with the two shapes that
    /// parser reads as syntax and the vault means literally taken out:
    ///
    /// - A lone `~` means "about" — and a line with two of them ("~3.8 GB
    ///   instead of ~10 GB") came out with everything between them struck
    ///   through, which is the one formatting a reader trusts as a *claim*.
    /// - `[[wiki-link]]`: the brackets are the vault's file scaffolding. The
    ///   pages that can actually follow a link list them as rows instead.
    ///
    /// A real `~~strikethrough~~` needs its pair of doubles, so both survive.
    public static func inlineSafe(_ text: String) -> String {
        let unlinked = text
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
        guard unlinked.contains("~") else { return unlinked }
        let characters = Array(unlinked)
        let keepsPairs = tildeRuns(characters).filter { $0 >= 2 }.count >= 2
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "~" else {
                result.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end] == "~" { end += 1 }
            let length = end - index
            result += keepsPairs && length >= 2
                ? String(repeating: "~", count: length)
                : String(repeating: "\\~", count: length)
            index = end
        }
        return result
    }

    /// The lengths of the runs of consecutive `~`, in order.
    private static func tildeRuns(_ characters: [Character]) -> [Int] {
        var runs: [Int] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "~" else { index += 1; continue }
            var end = index
            while end < characters.count, characters[end] == "~" { end += 1 }
            runs.append(end - index)
            index = end
        }
        return runs
    }
}
