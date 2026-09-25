import Foundation

/// The measured half of a voice profile (voice.md §3.1): plain statistics over
/// the corpus, computed with no model, no network and no database.
///
/// This half exists so the profile is not merely a second opinion. An LLM
/// asked to describe someone's prose will always produce fluent-sounding
/// adjectives; a median sentence length is checkable, survives to the bottom of
/// a long prompt, and is something the drafting model can actually aim at. It
/// is also everything the Voice page has to show on an install with the backend
/// set to `off`.
public struct VoiceMetrics: Equatable, Sendable {
    /// Below this the corpus is measured but never *stated*. "You never use
    /// semicolons" drawn from forty words is a lie, and it is a lie the
    /// drafting model would then obey (voice.md §3.1).
    public static let meaningfulWords = 400

    public var words = 0
    public var sentences = 0
    public var paragraphs = 0

    /// At or below this many words a sentence counts as short. Six, because
    /// that is about where a sentence stops being a clause and starts being a
    /// beat.
    public static let shortSentenceWords = 6
    /// How many prose sentences the length distribution needs before its
    /// *shape* is worth stating. Lower than `meaningfulWords` on purpose, and
    /// counted in sentences rather than words: a spread estimated from twenty
    /// sentences is rough but real, where "they never use semicolons" needs a
    /// whole corpus before it stops being a guess. Splitting the two floors is
    /// what stops a 300-word corpus from being told nothing at all.
    public static let rhythmSentences = 20

    public var medianSentenceWords = 0
    public var meanSentenceWords: Double = 0
    public var shortestSentenceWords = 0
    public var longestSentenceWords = 0
    /// The quartiles. These are the numbers that carry the *shape* of the
    /// distribution into the prompt, where median and mean carry only where its
    /// middle sits.
    public var quarterUnderSentenceWords = 0
    public var quarterOverSentenceWords = 0
    /// Standard deviation over the mean — spread, scale-free, so two writers
    /// with different average lengths are comparable. A reading and a test
    /// subject, not a prompt line: "coefficient of variation 0.50" is not
    /// something a model can aim at.
    public var sentenceLengthVariation: Double = 0
    /// **Burstiness**: how many words consecutive sentences differ by, on
    /// average. The measure that matters most and the one this type originally
    /// lacked — a writer whose lengths run 24, 25, 23, 26 and one whose run
    /// 1, 31, 8, 34 have the same median and read nothing alike.
    public var adjacentSentenceGap: Double = 0
    public var shortSentencePercent: Double = 0
    public var medianParagraphSentences = 0

    /// Per 1,000 words, all of them — punctuation is habit, and habit is the
    /// most imitable thing about a writer.
    public var emDashRate: Double = 0
    public var semicolonRate: Double = 0
    public var colonRate: Double = 0
    public var parenthesisRate: Double = 0
    public var ellipsisRate: Double = 0
    public var exclamationRate: Double = 0
    public var questionRate: Double = 0
    public var contractionRate: Double = 0
    public var firstPersonRate: Double = 0
    public var secondPersonRate: Double = 0
    public var hedgeRate: Double = 0
    public var intensifierRate: Double = 0

    public var averageWordLength: Double = 0
    /// Share of words of eight letters or more, as a percentage — the
    /// Latinate-versus-plain dial.
    public var longWordPercent: Double = 0
    /// Share of non-empty lines that start a bullet or a numbered item.
    public var listLinePercent: Double = 0
    public var headingLinePercent: Double = 0

    /// The words this writer starts sentences with, commonest first. An
    /// opener is a fingerprint people cannot hear in their own writing.
    public var openers: [String] = []
    /// Recurring content words — the vocabulary they actually own.
    public var vocabulary: [String] = []
    /// Machine tells this corpus contains none of, so the prompt can proscribe
    /// them by name (`Self.tells`).
    public var absentTells: [String] = []

    /// Whether the corpus is big enough for any of this to be worth stating.
    public var isMeaningful: Bool { words >= Self.meaningfulWords }

    public init() {}

    // MARK: - Measuring

    public static func measure(_ texts: [String]) -> VoiceMetrics {
        var metrics = VoiceMetrics()
        let corpus = texts.joined(separator: "\n\n")
        let allWords = words(in: corpus)
        guard !allWords.isEmpty else { return metrics }

        metrics.words = allWords.count
        let paragraphs = paragraphs(in: corpus)
        metrics.paragraphs = paragraphs.count

        // Length statistics come from *prose* sentences only, and the run of
        // lengths is kept per text: an adjacent-length gap measured across a
        // sample boundary is not a transition the author wrote.
        let runs = texts.map { text in
            Self.paragraphs(in: text).flatMap { Self.proseSentences(in: $0) }
                .map { VoiceSample.words(in: $0) }
        }
        metrics.applySentenceLengths(runs)
        metrics.medianParagraphSentences = median(
            paragraphs.map { proseSentences(in: $0).count }.filter { $0 > 0 })

        metrics.applyPunctuation(corpus)
        metrics.applyLexicon(allWords)
        metrics.applyLineShape(corpus)
        metrics.openers = topOpeners(paragraphs)
        metrics.vocabulary = topVocabulary(allWords)
        metrics.absentTells = Self.tells.filter { tell in
            corpus.range(of: tell, options: [.caseInsensitive]) == nil
        }
        return metrics
    }

    /// Everything the length distribution says. Separated because the *shape*
    /// of this distribution — not its centre — is what makes prose read as
    /// written by a person, and the first version of this type measured only
    /// the centre (see `rules()`).
    private mutating func applySentenceLengths(_ runs: [[Int]]) {
        let lengths = runs.flatMap { $0 }
        guard !lengths.isEmpty else { return }
        let sorted = lengths.sorted()
        sentences = lengths.count
        shortestSentenceWords = sorted[0]
        longestSentenceWords = sorted[sorted.count - 1]
        medianSentenceWords = percentile(sorted, 0.5)
        quarterUnderSentenceWords = percentile(sorted, 0.25)
        quarterOverSentenceWords = percentile(sorted, 0.75)
        let total = lengths.reduce(0, +)
        meanSentenceWords = Double(total) / Double(lengths.count)
        let variance = lengths
            .map { pow(Double($0) - meanSentenceWords, 2) }
            .reduce(0, +) / Double(lengths.count)
        sentenceLengthVariation = meanSentenceWords == 0
            ? 0 : variance.squareRoot() / meanSentenceWords
        shortSentencePercent = 100
            * Double(lengths.filter { $0 <= Self.shortSentenceWords }.count)
            / Double(lengths.count)
        // Within each text, never across two — hence `runs`.
        let gaps = runs.flatMap { run in
            zip(run, run.dropFirst()).map { abs($0 - $1) }
        }
        adjacentSentenceGap = gaps.isEmpty
            ? 0 : Double(gaps.reduce(0, +)) / Double(gaps.count)
    }

    private static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    private func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        Self.percentile(sorted, fraction)
    }

    private mutating func applyPunctuation(_ corpus: String) {
        // Ellipses and em-dashes are counted before the bare characters they
        // contain, so "…" isn't also three full stops and "—" isn't a hyphen.
        let ellipses = Self.occurrences(of: "…", in: corpus)
            + Self.occurrences(of: "...", in: corpus)
        ellipsisRate = per1k(ellipses)
        emDashRate = per1k(Self.occurrences(of: "—", in: corpus)
            + Self.occurrences(of: " -- ", in: corpus))
        semicolonRate = per1k(corpus.filter { $0 == ";" }.count)
        colonRate = per1k(corpus.filter { $0 == ":" }.count)
        parenthesisRate = per1k(corpus.filter { $0 == "(" }.count)
        exclamationRate = per1k(corpus.filter { $0 == "!" }.count)
        questionRate = per1k(corpus.filter { $0 == "?" }.count)
    }

    private mutating func applyLexicon(_ allWords: [String]) {
        let lowered = allWords.map { $0.lowercased() }
        // An apostrophe with letters on both sides. Catches possessives too
        // ("Anna's"), which is why this is reported as a rate and read as a
        // formality dial rather than as a contraction census.
        contractionRate = per1k(lowered.filter(hasInnerApostrophe).count)
        // Person is matched on the display form — apostrophe kept — because
        // the stripped form of "we're" is "were", and counting every past
        // tense as first person would mute the "keeps themselves out of it"
        // rule for exactly the writer it exists for.
        firstPersonRate = per1k(
            lowered.filter { Self.firstPerson.contains(Self.displayWord($0)) }.count)
        secondPersonRate = per1k(
            lowered.filter { Self.secondPerson.contains(Self.displayWord($0)) }.count)
        hedgeRate = per1k(lowered.filter { Self.hedges.contains(stripped($0)) }.count)
        intensifierRate = per1k(
            lowered.filter { Self.intensifiers.contains(stripped($0)) }.count)

        let letters = allWords.map { stripped($0).count }.filter { $0 > 0 }
        averageWordLength = letters.isEmpty
            ? 0 : Double(letters.reduce(0, +)) / Double(letters.count)
        longWordPercent = letters.isEmpty
            ? 0 : 100 * Double(letters.filter { $0 >= 8 }.count) / Double(letters.count)
    }

    private mutating func applyLineShape(_ corpus: String) {
        let lines = corpus.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let bullets = lines.filter { line in
            line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
                || isNumberedItem(line)
        }
        listLinePercent = 100 * Double(bullets.count) / Double(lines.count)
        headingLinePercent = 100 * Double(lines.filter { $0.hasPrefix("#") }.count)
            / Double(lines.count)
    }

    private func per1k(_ count: Int) -> Double {
        words == 0 ? 0 : 1_000 * Double(count) / Double(words)
    }

    // MARK: - Splitting

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    static func paragraphs(in text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sentences inside one paragraph. Split on terminal punctuation followed
    /// by whitespace; a paragraph that never terminates (a heading, a bullet,
    /// a one-line note) is one sentence, because that is how it reads.
    ///
    /// A full stop directly after a bare number is **not** a terminator. It is
    /// a list marker or a decimal, and treating it as one is what made "4." and
    /// "3." register as one-word sentences on a real corpus with numbered
    /// lists — dragging every length statistic down and, worse, inventing a
    /// habit of writing one-word sentences that the author does not have.
    static func sentences(in paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in paragraph {
            if let previous, ".!?…".contains(previous),
               character.isWhitespace || character.isNewline,
               !(previous == "." && endsInBareNumber(current)) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// Whether what has accumulated so far ends in digits and then the stop —
    /// "4.", "3.14", "step 2." — rather than in a word.
    private static func endsInBareNumber(_ accumulated: String) -> Bool {
        let body = accumulated.hasSuffix(".") ? String(accumulated.dropLast()) : accumulated
        guard let last = body.split(whereSeparator: { $0.isWhitespace }).last else { return false }
        return last.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The sentences that are actually prose, for the length distribution.
    ///
    /// Two exclusions, both measured against a real corpus rather than
    /// imagined. A "sentence" with no letters in it is punctuation the split
    /// stranded ("." , ".”"). A short one that never terminates is furniture —
    /// a title block ("UTA Application", "Jerry Fan", "April 2026"), a bullet
    /// stub, or a run of CJK that whitespace-splitting counts as one word.
    /// Neither is a sentence anybody wrote, and both sit at the bottom of the
    /// range, which is exactly where they distort a spread the prompt then
    /// asks a model to reproduce.
    static func proseSentences(in paragraph: String) -> [String] {
        sentences(in: paragraph).filter { sentence in
            guard sentence.contains(where: \.isLetter) else { return false }
            let terminated = sentence.last.map { ".!?…\"')]”’".contains($0) } ?? false
            return terminated || VoiceSample.words(in: sentence) >= 8
        }
    }

    // MARK: - Distinctive words

    private static func topOpeners(_ paragraphs: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for paragraph in paragraphs {
            // Prose only, for the same reason the lengths are: "4." and a title
            // block are not openings the author chose.
            for sentence in proseSentences(in: paragraph) {
                guard let first = words(in: sentence).first else { continue }
                let word = displayWord(first.lowercased())
                guard word.count > 1 else { continue }
                counts[word, default: 0] += 1
            }
        }
        return rank(counts, minimum: 2, limit: 5)
    }

    private static func topVocabulary(_ allWords: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for word in allWords {
            let stem = displayWord(word.lowercased())
            guard stem.count >= 4, !stopwords.contains(stripped(stem)) else { continue }
            counts[stem, default: 0] += 1
        }
        return rank(counts, minimum: 3, limit: 8)
    }

    /// Commonest first, ties broken alphabetically so the same corpus always
    /// renders the same profile — a profile that reshuffles on every rebuild
    /// would look like the corpus changed when it didn't.
    private static func rank(_ counts: [String: Int], minimum: Int, limit: Int) -> [String] {
        counts.filter { $0.value >= minimum }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: - Small helpers

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func median(_ values: [Int]) -> Int { Self.median(values) }

    /// Letters only — drops the punctuation a word is wearing, keeps the
    /// apostrophe out so "don't" stems to "dont" consistently.
    private static func stripped(_ word: String) -> String {
        String(word.filter { $0.isLetter })
    }

    /// The form a word is *shown* in — letters plus the apostrophe inside
    /// them, so "It's" lists as "it's" rather than as "its". The two are
    /// different words, and in a feature whose whole claim is precision about
    /// someone's writing, printing one as the other reads as a typo.
    private static func displayWord(_ word: String) -> String {
        let kept = word.filter { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private func stripped(_ word: String) -> String { Self.stripped(word) }

    private func hasInnerApostrophe(_ word: String) -> Bool {
        let characters = Array(word)
        for (index, character) in characters.enumerated()
        where character == "'" || character == "\u{2019}" {
            if index > 0, index < characters.count - 1,
               characters[index - 1].isLetter, characters[index + 1].isLetter {
                return true
            }
        }
        return false
    }

    private func isNumberedItem(_ line: String) -> Bool {
        let head = line.prefix(4)
        guard let dot = head.firstIndex(where: { $0 == "." || $0 == ")" }) else { return false }
        let digits = head[head.startIndex..<dot]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }

    // MARK: - Word lists

    /// Matched against `displayWord`, so contractions keep their apostrophe.
    /// Apostrophe-free spellings appear only where nothing else spells them —
    /// a casual "im" or "ive" is first person, where a bare "were", "id" or
    /// "ill" is almost always the ordinary word.
    static let firstPerson: Set<String> = ["i", "me", "my", "mine", "myself", "we", "us", "our",
                                           "ours", "i'm", "i've", "i'd", "i'll", "we're",
                                           "we've", "we'd", "we'll", "im", "ive", "weve"]
    static let secondPerson: Set<String> = ["you", "your", "yours", "yourself", "you're",
                                            "you've", "you'll", "you'd", "youre", "youve",
                                            "youll"]
    static let hedges: Set<String> = ["maybe", "perhaps", "might", "probably", "possibly",
                                      "somewhat", "fairly", "arguably", "apparently", "roughly",
                                      "seemingly", "presumably", "generally", "typically",
                                      "slightly", "supposedly", "seems", "seem"]
    static let intensifiers: Set<String> = ["very", "really", "extremely", "incredibly",
                                            "absolutely", "totally", "completely", "hugely",
                                            "massively", "utterly", "deeply", "insanely",
                                            "super", "enormously"]
    /// Words and phrases that read as machine-written to almost everybody.
    ///
    /// The evidence for the list is that they are tells, not that this corpus
    /// lacks them — LLMs reach for all of these far more than people do. The
    /// corpus check is a **safety valve**: a writer who genuinely says
    /// "furthermore" keeps it, because proscribing a word someone actually uses
    /// would be the profile arguing with its own samples. Static and short by
    /// design; this is not a setting.
    static let tells: [String] = [
        "delve", "moreover", "furthermore", "notably", "crucially", "pivotal",
        "realm", "myriad", "tapestry", "testament", "landscape", "leverage",
        "seamless", "robust", "underscore", "foster", "endeavor", "utilize",
        "multifaceted", "nuanced", "holistic", "paradigm", "synergy",
        "it's important to note", "it's worth noting", "in conclusion",
        "at the end of the day", "that being said", "navigate the complexities",
        "a testament to", "plays a crucial role", "in today's world"
    ]

    /// Function words and the commonest verbs — everything left over after
    /// these is the writer's own subject matter.
    static let stopwords: Set<String> = [
        "that", "this", "with", "from", "have", "will", "they", "them", "then", "than",
        "what", "when", "which", "were", "been", "your", "just", "about", "there", "their",
        "would", "could", "should", "into", "some", "more", "most", "only", "over", "also",
        "here", "does", "done", "said", "make", "made", "like", "want", "need", "know",
        "think", "going", "still", "much", "many", "even", "well", "back", "take", "took",
        "come", "came", "give", "gave", "sure", "thing", "things", "really", "very", "because"
    ]
}
