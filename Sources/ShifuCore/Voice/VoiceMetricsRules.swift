import Foundation

/// Turning measurements into words: the readings the Voice page and the
/// profile file display, and the imperative lines the drafting prompt carries
/// (voice.md §3.1). Split from `VoiceMetrics.swift` for length only.
extension VoiceMetrics {
    /// One labelled measurement, for the page's right column and the measured
    /// block of `profile.md`. Same list in both, so what the user reads is
    /// exactly what the model is told.
    public struct Reading: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String

        public var id: String { label }
    }

    public var readings: [Reading] {
        guard words > 0 else { return [] }
        return [
            Reading(label: "Corpus", value: "\(words) words · \(sentences) sentences"),
            Reading(label: "Sentence length",
                    value: "\(medianSentenceWords) words median · "
                        + "\(number(meanSentenceWords)) mean"),
            // The shape, given its own row: it is what the drafting prompt
            // leans on hardest, so it has to be visible rather than implied by
            // a median.
            Reading(label: "Sentence spread",
                    value: "\(shortestSentenceWords)–\(longestSentenceWords) words · "
                        + "quartiles \(quarterUnderSentenceWords)/\(quarterOverSentenceWords) · "
                        + "variation \(number(sentenceLengthVariation))"),
            Reading(label: "Rhythm",
                    value: "±\(number(adjacentSentenceGap)) words between consecutive · "
                        + "\(number(shortSentencePercent))% under "
                        + "\(VoiceMetrics.shortSentenceWords + 1)"),
            Reading(label: "Paragraph",
                    value: "\(medianParagraphSentences) sentence"
                        + (medianParagraphSentences == 1 ? "" : "s")),
            Reading(label: "Punctuation", value: punctuationReading),
            Reading(label: "Contractions", value: per1kLabel(contractionRate)),
            Reading(label: "Person", value: personReading),
            Reading(label: "Diction",
                    value: "\(number(averageWordLength)) letters average · "
                        + "\(number(longWordPercent))% long words"),
            Reading(label: "Hedging",
                    value: "\(per1kLabel(hedgeRate)) hedges · "
                        + "\(per1kLabel(intensifierRate)) intensifiers"),
            Reading(label: "Layout",
                    value: "\(number(listLinePercent))% list lines · "
                        + "\(number(headingLinePercent))% headings")
        ] + distinctiveReadings
    }

    private var distinctiveReadings: [Reading] {
        var extra: [Reading] = []
        if !openers.isEmpty {
            extra.append(Reading(label: "Opens with", value: openers.joined(separator: ", ")))
        }
        if !vocabulary.isEmpty {
            extra.append(Reading(label: "Recurring words",
                                 value: vocabulary.joined(separator: ", ")))
        }
        return extra
    }

    private var punctuationReading: String {
        let parts = [("em dash", emDashRate), ("semicolon", semicolonRate),
                     ("colon", colonRate), ("parenthesis", parenthesisRate),
                     ("ellipsis", ellipsisRate), ("!", exclamationRate),
                     ("?", questionRate)]
            .filter { $0.1 >= 0.5 }
            .map { "\($0.0) \(number($0.1))" }
        return parts.isEmpty ? "plain — none of the marks recur" : parts.joined(separator: " · ")
    }

    private var personReading: String {
        "first \(number(firstPersonRate)) · second \(number(secondPersonRate)) per 1k"
    }

    // MARK: - Prompt rules (voice.md §4.2, step 3)

    /// The measured constraints, as imperative lines with numbers in them.
    /// Empty below `meaningfulWords`: a rule drawn from forty words is a
    /// fabrication the drafting model would obey to the letter.
    ///
    /// Numbers rather than adjectives on purpose. "Writes concisely" survives
    /// nothing; "median sentence 14 words" is something a model can aim at and
    /// something a reader can check afterwards.
    public func rules() -> [String] {
        // Rhythm rides a lower gate than the rest (`rhythmSentences`): the
        // *shape* of a length distribution is estimable from twenty sentences,
        // where an absence claim needs a whole corpus. Below both floors this
        // is still empty.
        var lines = rhythmRules
        guard isMeaningful else { return lines }
        lines.append("Paragraphs run about \(medianParagraphSentences) sentence"
            + (medianParagraphSentences == 1 ? "" : "s") + ".")
        lines.append(contentsOf: punctuationRules)
        lines.append(contractionRule)
        lines.append(contentsOf: personRules)
        lines.append(contentsOf: stanceRules)
        lines.append("Diction: \(number(averageWordLength)) letters per word on average, "
            + "\(number(longWordPercent))% of words eight letters or longer.")
        lines.append(contentsOf: layoutRules)
        if !openers.isEmpty {
            lines.append("Sentences most often open with: \(openers.joined(separator: ", ")).")
        }
        if !vocabulary.isEmpty {
            lines.append("Words that recur in their writing: "
                + "\(vocabulary.joined(separator: ", ")). Use them where they fit; "
                + "do not force them.")
        }
        // Behind `isMeaningful`, not the rhythm gate: "appear nowhere in
        // their writing" is a word-level absence claim, and like the other
        // absences it needs the whole corpus before it stops being a guess.
        if !absentTells.isEmpty {
            lines.append("Never use these — they read as machine-written and appear "
                + "nowhere in their writing: \(absentTells.joined(separator: ", ")).")
        }
        return lines
    }

    /// The length distribution's *shape*, and the instruction not to flatten it.
    ///
    /// This replaces a single line that read "keep most sentences near the
    /// median and let a few run long". That line was the design's worst defect:
    /// it stated one number and then asked for uniformity around it, which is
    /// the one thing that makes prose read as machine-written. It rested on a
    /// belief — that the gap between median and mean captures burstiness — that
    /// measurement disproved: on a real corpus the gap was 1.6 words while the
    /// spread ran from 4 to 69 (voice.md §3.1a).
    ///
    /// So the shape is stated as quartiles a model can aim at, the adjacent gap
    /// is stated in words, and the failure mode is named outright. A model will
    /// regress to a uniform cadence unless told that the cadence itself is the
    /// mistake.
    private var rhythmRules: [String] {
        guard sentences >= VoiceMetrics.rhythmSentences else { return [] }
        var lines = [
            "Sentence length is a *distribution*, not a target. Theirs: shortest "
                + "\(shortestSentenceWords), a quarter under \(quarterUnderSentenceWords), "
                + "median \(medianSentenceWords), a quarter over "
                + "\(quarterOverSentenceWords), longest \(longestSentenceWords) words. "
                + "Reproduce that whole range in the draft, including its ends.",
            "Consecutive sentences of theirs differ by \(number(adjacentSentenceGap)) "
                + "words on average. Vary length sentence to sentence by about that "
                + "much: follow a long sentence with a short one, and do not settle "
                + "into a steady cadence. A draft where nearly every sentence is "
                + "close to the median is the single clearest sign it was not "
                + "written by them — more telling than any word choice."
        ]
        if shortSentencePercent >= 3 {
            lines.append("\(number(shortSentencePercent))% of their sentences are "
                + "\(VoiceMetrics.shortSentenceWords) words or fewer. Include some that "
                + "short. A four-word sentence is a sentence.")
        }
        return lines
    }

    /// Each mark gets a line only when it is a habit or a pointed absence.
    /// The middle of the range says nothing about anybody.
    private var punctuationRules: [String] {
        let marks = [("em dashes", emDashRate), ("semicolons", semicolonRate),
                     ("colons", colonRate), ("parentheses", parenthesisRate),
                     ("ellipses", ellipsisRate), ("exclamation marks", exclamationRate),
                     ("question marks", questionRate)]
        var lines: [String] = []
        let used = marks.filter { $0.1 >= 1 }
            .map { "\($0.0) (\(number($0.1)) per 1,000 words)" }
        if !used.isEmpty {
            lines.append("Punctuation they reach for: \(used.joined(separator: ", ")).")
        }
        let unused = marks.filter { $0.1 == 0 }.map(\.0)
        if !unused.isEmpty {
            lines.append("They never use: \(unused.joined(separator: ", ")). Do not introduce them.")
        }
        return lines
    }

    private var contractionRule: String {
        if contractionRate >= 15 {
            return "Contracted throughout (\(number(contractionRate)) per 1,000 words) — "
                + "write \"don't\", \"it's\", \"we're\"."
        }
        if contractionRate <= 3 {
            return "Almost never contracts (\(number(contractionRate)) per 1,000 words) — "
                + "write \"do not\", \"it is\", \"we are\" in full."
        }
        return "Contracts sometimes (\(number(contractionRate)) per 1,000 words) — "
            + "not uniformly one way or the other."
    }

    private var personRules: [String] {
        var lines: [String] = []
        if firstPersonRate >= 10 {
            lines.append("Writes in the first person (\(number(firstPersonRate)) per 1,000 "
                + "words) — \"I\" and \"we\" belong in the draft.")
        } else if firstPersonRate <= 2 {
            lines.append("Keeps themselves out of it (\(number(firstPersonRate)) first-person "
                + "words per 1,000) — do not add \"I think\" or \"we believe\".")
        }
        if secondPersonRate >= 10 {
            lines.append("Addresses the reader directly (\(number(secondPersonRate)) "
                + "second-person words per 1,000).")
        }
        return lines
    }

    private var stanceRules: [String] {
        var lines: [String] = []
        if hedgeRate >= 6 {
            lines.append("Hedges deliberately (\(number(hedgeRate)) per 1,000 words) — "
                + "\"probably\", \"might\", \"roughly\". Do not write with more certainty "
                + "than they do.")
        } else if hedgeRate <= 1 {
            lines.append("Does not hedge (\(number(hedgeRate)) hedges per 1,000 words) — "
                + "state things flat.")
        }
        if intensifierRate <= 1 {
            lines.append("No intensifiers (\(number(intensifierRate)) per 1,000 words) — "
                + "no \"very\", \"really\", \"incredibly\".")
        } else if intensifierRate >= 6 {
            lines.append("Uses intensifiers freely (\(number(intensifierRate)) per 1,000 words).")
        }
        return lines
    }

    private var layoutRules: [String] {
        var lines: [String] = []
        if listLinePercent >= 10 {
            lines.append("Reaches for bullets — \(number(listLinePercent))% of their lines "
                + "are list items.")
        } else if listLinePercent < 2 {
            lines.append("Writes in prose, not bullets (\(number(listLinePercent))% list "
                + "lines). Do not answer with a list unless asked for one.")
        }
        if headingLinePercent >= 5 {
            lines.append("Uses headings (\(number(headingLinePercent))% of lines).")
        }
        return lines
    }

    // MARK: - Formatting

    /// One decimal, and no trailing ".0" — a profile is read by a person.
    private func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private func per1kLabel(_ value: Double) -> String { "\(number(value))/1k" }
}
