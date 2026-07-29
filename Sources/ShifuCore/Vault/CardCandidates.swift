import Foundation

/// The JSON shape every card-writing prompt answers in, and the parser that
/// survives what models actually send back (design.md §5.1–5.2). Shared by
/// `KnowledgeExtractor` (reference notes: topic + note), `DeckSuggester`
/// (sample cards) and `DeckBuilder` (full decks) — one shape, one parser, one
/// set of LaTeX rules, so a repair learned in one place holds everywhere.
public enum CardCandidates {
    /// One parsed object. `question`/`answer` are optional because the
    /// reference-note prompt doesn't ask for them; the deck prompts require
    /// both and drop candidates missing either.
    public struct Candidate: Equatable, Sendable {
        public var topic: String
        public var note: String
        public var question: String?
        public var answer: String?
        public var confidence: Double
    }

    /// The LaTeX contract, verbatim in every card prompt. Models are asked to
    /// double their backslashes here and routinely don't — `parse` repairs
    /// that below, but asking still measurably reduces the damage.
    public static func latexRules() -> String {
        """
        Write every formula, variable, and symbol as LaTeX — inline as \\( ... \\),
        displayed as $$ ... $$ — never as ASCII or pasted Unicode: \\alpha not "alpha",
        \\frac{a}{b} not "a/b", \\|x\\| not "||x||", x^{2} not "x^2". Name a variable in
        prose and it still gets delimiters: "the angle \\( \\theta \\) between ...".
        Because this is JSON, every backslash must be doubled: write "\\\\frac{a}{b}".
        """
    }

    /// Pulls the JSON array out of a response and parses it, repairing raw
    /// LaTeX escapes first and falling back to the untouched text.
    public static func parse(_ response: String) -> [Candidate] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end
        else { return [] }
        let raw = String(response[start...end])
        guard let array = objects(repairingLaTeXEscapes(raw)) ?? objects(raw)
        else { return [] }
        return array.compactMap { obj in
            guard let topic = obj["topic"] as? String,
                  let note = obj["note"] as? String,
                  let confidence = (obj["confidence"] as? NSNumber)?.doubleValue
            else { return nil }
            return Candidate(topic: topic, note: note,
                             question: obj["question"] as? String,
                             answer: obj["answer"] as? String,
                             confidence: confidence)
        }
    }

    /// The response's outermost JSON *object*, for prompts that answer with a
    /// verdict wrapping the cards (`DeckSuggester`'s `{"worth": …}`). Same
    /// escape repairs, same fall back to the untouched text.
    public static func verdict(_ response: String) -> [String: Any]? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start < end
        else { return nil }
        let raw = String(response[start...end])
        return dictionary(repairingLaTeXEscapes(raw)) ?? dictionary(raw)
    }

    private static func objects(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private static func dictionary(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Backslashes that open LaTeX rather than a JSON escape (§5.2). Models
    /// are asked to double them and routinely don't, and unrepaired the damage
    /// is silent: `"\(x\)"` is an invalid escape that fails the whole array —
    /// losing every candidate in the batch — while `"\frac"` parses as a
    /// formfeed and quietly eats the `f`. Only names `CardMarkup` recognises
    /// are escaped, so a genuine `\n` between sentences survives.
    static func repairingLaTeXEscapes(_ json: String) -> String {
        let chars = Array(json)
        var result = ""
        var index = 0
        while index < chars.count {
            guard chars[index] == "\\", index + 1 < chars.count else {
                result.append(chars[index])
                index += 1
                continue
            }
            let next = chars[index + 1]
            if next == "\\" {   // already a correctly escaped backslash
                result += "\\\\"
                index += 2
            } else if next.isLetter {
                var name = ""
                var cursor = index + 1
                while cursor < chars.count, chars[cursor].isLetter {
                    name.append(chars[cursor])
                    cursor += 1
                }
                if CardMarkup.isKnownCommand(name) {
                    result += "\\\\" + name
                    index = cursor
                } else {
                    result.append(chars[index])
                    index += 1
                }
            } else if latexPunctuation.contains(next) {
                result += "\\\\"
                index += 1
            } else {
                result.append(chars[index])
                index += 1
            }
        }
        return result
    }

    /// Characters a backslash can precede in LaTeX that JSON has no escape
    /// for, so seeing one means the backslash was never meant as an escape.
    private static let latexPunctuation: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "|", ";", ",", "!", ":", "%", "&", "#",
        "_", "$", " "
    ]
}
