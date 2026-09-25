import Foundation

/// Turning text extracted from a laid-out document back into prose
/// (voice.md §2.2).
///
/// This exists because of what the metrics do downstream. A PDF's text layer
/// comes out one string per *visual line*, carrying everything the typesetter
/// added and the author never wrote: page numbers, running heads, hyphens
/// splitting words across line ends, and a line break every sixty characters.
/// Fed in raw, `VoiceMetrics` measures all of it **as style** — twenty page
/// numbers in a twenty-page document are twenty one-word "sentences", and the
/// median sentence length is the single number the drafting prompt tells the
/// model to aim at. A repeated running head becomes the author's most
/// characteristic vocabulary. "migra-\ntion" becomes two words they never used.
///
/// So the cleanup is load-bearing, not cosmetic, and it is pure string work
/// living here rather than beside the extractor so it can be tested against
/// fixed input. **Only document extraction calls it.** Pasted text and
/// `.txt`/`.md` files are already prose, and reflowing them would destroy line
/// breaks the author meant.
public enum VoiceImportText {
    /// One page's extracted text per element. Pages rather than one string
    /// because running heads and feet can only be found by their repetition
    /// *across* pages.
    public static func prose(pages: [String]) -> String {
        // NFKC first: typeset documents are full of ﬁ/ﬂ/ﬀ ligatures, and
        // "ﬁnished" is a different word from "finished" to every lexical
        // measure downstream. Em dashes and curly apostrophes have no
        // compatibility decomposition, so the two habits that matter most
        // survive this untouched.
        let perPage = pages
            .map { $0.precomposedStringWithCompatibilityMapping }
            .map { split($0) }
        let running = runningLines(perPage)
        // Flattened, so a sentence broken across a page break rejoins: the
        // running head that sat between its halves is already gone.
        let kept = perPage.flatMap { page in
            page.filter { line in
                line.isEmpty || (!running.contains(line) && !isPageArtifact(line))
            }
        }
        return reflow(kept)
    }

    // MARK: - Lines

    /// Trimmed lines, with runs of blanks collapsed to one. Blanks are kept:
    /// they are the one paragraph boundary the document states outright.
    static func split(_ page: String) -> [String] {
        var result: [String] = []
        let raw = page
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0C}", with: "\n")
            .components(separatedBy: "\n")
        for line in raw {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(trimmed)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    /// Lines that recur at the very top or very bottom of enough pages to be
    /// furniture rather than writing.
    ///
    /// Candidates are each page's **first and last** content line, and nothing
    /// else. Widening to the first two would put the opening line of the body
    /// in scope, and dropping real prose is far the worse error: a surviving
    /// running head only skews the vocabulary list, where a lost paragraph
    /// changes what the model is shown. Two-line heads therefore keep their
    /// second line — an acceptable trade for never eating a sentence.
    static func runningLines(_ pages: [[String]]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages {
            let content = page.filter { !$0.isEmpty }
            guard let first = content.first else { continue }
            for line in Set([first, content[content.count - 1]]) where line.count <= 100 {
                counts[line, default: 0] += 1
            }
        }
        let floor = max(3, pages.count / 2)
        return Set(counts.filter { $0.value >= floor }.keys)
    }

    /// A line that is a page's plumbing and not a sentence: a bare number, a
    /// "Page 3 of 12", a front-matter roman numeral, however it is decorated
    /// ("— 3 —", "[3]").
    static func isPageArtifact(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 20 else { return false }
        let core = line.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return true }   // "— — —", "***"
        if core.allSatisfy(\.isNumber) { return core.count <= 4 }
        if romanNumerals.contains(core) { return true }
        let words = core.split(separator: " ").map(String.init)
        // "page 3", "page 3 of 12", "3 of 12"
        if words.first == "page", words.dropFirst().allSatisfy(isNumberOrOf) { return true }
        if words.count == 3, words[1] == "of",
           words[0].allSatisfy(\.isNumber), words[2].allSatisfy(\.isNumber) { return true }
        return false
    }

    private static func isNumberOrOf(_ word: String) -> Bool {
        word == "of" || word.allSatisfy(\.isNumber)
    }

    /// An explicit list rather than a parser. Every roman numeral is also a
    /// run of ordinary letters — "mix", "did" and "civic" are all spelled from
    /// IVXLCDM — so recognising them by charset would delete real words. Front
    /// matter never runs past twenty pages anyway.
    static let romanNumerals: Set<String> = [
        "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
        "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx"
    ]

    // MARK: - Reflow

    /// Joins wrapped lines back into paragraphs.
    ///
    /// The measure that makes this work is the document's own median line
    /// length. A line that runs to the margin was broken by the typesetter and
    /// continues; a line that stops well short of it ended because the author
    /// did. Nothing here needs to be perfect — it needs to stop the metrics
    /// from reading a column width as a sentence length.
    static func reflow(_ lines: [String]) -> String {
        let lengths = lines.filter { !$0.isEmpty }.map(\.count).sorted()
        guard !lengths.isEmpty else { return "" }
        let median = lengths[lengths.count / 2]
        let shortLine = max(20, Int(Double(median) * 0.8))

        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
        }

        for (index, line) in lines.enumerated() {
            // A blank line is a paragraph break only when what precedes it
            // finished a sentence. Mid-sentence, a blank is furniture: it is
            // what removing a running head or a page number leaves behind, and
            // honouring it would cut every sentence that spans a page break in
            // half — two fragments the metrics then read as two short
            // sentences.
            guard !line.isEmpty else {
                if endsSentence(current) { flush() }
                continue
            }
            // A bullet or a heading starts its own block whatever preceded it.
            if startsBlock(line) { flush() }
            if current.isEmpty {
                current = line
            } else if let stem = hyphenStem(current), startsLowercase(line) {
                // "migra-" + "tion" — the hyphen is the typesetter's, so it
                // goes, and no space takes its place.
                current = stem + line
            } else {
                current += " " + line
            }
            let blankFollows = index + 1 < lines.count && lines[index + 1].isEmpty
            let nextContent = lines[(index + 1)...].first { !$0.isEmpty }
            if endsParagraph(line, nextContent: nextContent, blankFollows: blankFollows,
                             shortLine: shortLine) { flush() }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?…\"')]”’".contains(last)
    }

    /// The line without its trailing hyphen, or nil when it has none. Both the
    /// ASCII hyphen and the Unicode one typesetters use.
    private static func hyphenStem(_ line: String) -> String? {
        guard let last = line.last, last == "-" || last == "\u{2010}" || last == "\u{00AD}"
        else { return nil }
        return String(line.dropLast())
    }

    private static func startsLowercase(_ line: String) -> Bool {
        line.first?.isLowercase ?? false
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
            || line.hasPrefix("#")
    }

    /// Two rules, both deliberately conservative — a missed break leaves two
    /// paragraphs joined, where a wrong one cuts a sentence in half.
    private static func endsParagraph(
        _ line: String, nextContent: String?, blankFollows: Bool, shortLine: Int
    ) -> Bool {
        let ends = endsSentence(line)
        // The canonical case: a sentence that finished before the margin did.
        if ends, line.count < shortLine { return true }
        // A very short line that isn't a sentence at all, standing alone — a
        // heading, a salutation, a signature. The 0.6 factor keeps ordinary
        // wrapped lines, which run near the margin, from ever reaching this.
        if !ends, line.count < Int(Double(shortLine) * 0.6),
           blankFollows || (nextContent?.first?.isUppercase ?? false) { return true }
        return false
    }
}
