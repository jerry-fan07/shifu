import Foundation

/// Card text markup (design.md §5.2): splits note/question/answer text into
/// plain-text, math, and code segments, and converts a practical subset of
/// LaTeX into styled runs the review UI can render natively (§7: no web
/// views). Parsing lives here so it stays unit-testable without SwiftUI.
public enum CardMarkup {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case inlineMath([MathRun])
        case displayMath([MathRun])
        case inlineCode(String)
        case codeBlock(code: String, language: String?)

        /// Segments that own their own line, so the surrounding text shouldn't
        /// keep the newlines that separated them.
        var isBlock: Bool {
            switch self {
            case .displayMath, .codeBlock: return true
            case .text, .inlineMath, .inlineCode: return false
            }
        }
    }

    public enum Script: Sendable { case normal, raised, lowered }

    /// The one typographic distinction that separates real math from italicised
    /// ASCII (TeX's default math italic): variables lean, while digits,
    /// operators, uppercase Greek, function names and `\text` stand upright.
    public enum Style: Sendable { case variable, upright }

    /// One styled slice of converted math: baseline text, or a raised /
    /// lowered run (exponents, indices, fraction halves).
    public struct MathRun: Equatable, Sendable {
        public var text: String
        public var script: Script
        public var style: Style

        public init(_ text: String, script: Script = .normal, style: Style = .variable) {
            self.text = text
            self.script = script
            self.style = style
        }
    }

    // MARK: - Segmentation

    /// Order of precedence: fenced code, display math ($$…$$ / \[…\]), inline
    /// code, inline math ($…$ / \(…\)). Unterminated delimiters stay literal,
    /// and single `$` follows the Pandoc rule (opener touches a non-space,
    /// closer touched by one) so prices ("$5 and $10") never become math.
    public static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var plain = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count, chars[index + 1] == "$" {
                plain.append("$")   // escaped dollar stays literal
                index += 2
            } else if let (segment, next) = delimitedSegment(chars, at: index) {
                // A block stands on its own line, so the blank space that put
                // it there isn't text — leaving it in adds an empty paragraph
                // above and a stray leading newline below.
                if segment.isBlock {
                    while let last = plain.last, last.isWhitespace { plain.removeLast() }
                }
                if !plain.isEmpty { result.append(.text(plain)) }
                plain = ""
                result.append(segment)
                index = next
                if segment.isBlock, index < chars.count, chars[index] == "\n" { index += 1 }
            } else {
                plain.append(chars[index])
                index += 1
            }
        }
        if !plain.isEmpty { result.append(.text(plain)) }
        return result
    }

    /// The delimited segment opening at `index`, with the index just past its
    /// closer — or nil when `index` sits on ordinary text.
    private static func delimitedSegment(
        _ chars: [Character], at index: Int
    ) -> (Segment, Int)? {
        let atLineStart = index == 0 || chars[index - 1] == "\n"
        if atLineStart, matches(chars, at: index, "```"),
           let fence = parseFence(chars, at: index) {
            return (.codeBlock(code: fence.code, language: fence.language), fence.end)
        }
        if matches(chars, at: index, "$$"), let close = find("$$", in: chars, from: index + 2) {
            return (.displayMath(mathRuns(String(chars[(index + 2)..<close]))), close + 2)
        }
        if matches(chars, at: index, "\\["), let close = find("\\]", in: chars, from: index + 2) {
            return (.displayMath(mathRuns(String(chars[(index + 2)..<close]))), close + 2)
        }
        if matches(chars, at: index, "\\("), let close = find("\\)", in: chars, from: index + 2) {
            return (.inlineMath(mathRuns(String(chars[(index + 2)..<close]))), close + 2)
        }
        if chars[index] == "`", let close = find("`", in: chars, from: index + 1),
           close > index + 1 {   // `` is not an (empty) code span
            return (.inlineCode(String(chars[(index + 1)..<close])), close + 1)
        }
        if chars[index] == "$", let close = inlineMathClose(chars, opener: index) {
            return (.inlineMath(mathRuns(String(chars[(index + 1)..<close]))), close + 1)
        }
        return nil
    }

    /// Index of `delim` scanning from `start`. The match check runs before
    /// the escape skip because closers like "\\]" start with the escape
    /// character themselves.
    private static func find(_ delim: String, in chars: [Character], from start: Int) -> Int? {
        var cursor = start
        while cursor <= chars.count - delim.count {
            if matches(chars, at: cursor, delim) { return cursor }
            if chars[cursor] == "\\" { cursor += 2; continue }
            cursor += 1
        }
        return nil
    }

    private static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        let tokenChars = Array(token)
        guard index + tokenChars.count <= chars.count else { return false }
        return Array(chars[index..<(index + tokenChars.count)]) == tokenChars
    }

    /// A valid `$…$` span: opener followed by non-space, closer preceded by
    /// non-space, single line, and the closer isn't immediately trailed by a
    /// digit (that's the second price in "$5 and $10").
    private static func inlineMathClose(_ chars: [Character], opener: Int) -> Int? {
        guard opener + 1 < chars.count, !chars[opener + 1].isWhitespace,
              chars[opener + 1] != "$" else { return nil }
        var cursor = opener + 1
        while cursor < chars.count, chars[cursor] != "\n" {
            if chars[cursor] == "\\" { cursor += 2; continue }
            if chars[cursor] == "$" {
                guard !chars[cursor - 1].isWhitespace else { return nil }
                if cursor + 1 < chars.count, chars[cursor + 1].isNumber { return nil }
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private struct Fence {
        var code: String
        var language: String?
        var end: Int
    }

    /// A ```lang fence opened at `index`. Like CommonMark, an unterminated
    /// fence runs to the end of the text — so the editor's live preview shows
    /// a code block the moment the fence is opened. Nil only when the opener
    /// has no line of its own (no newline after "```lang").
    private static func parseFence(_ chars: [Character], at index: Int) -> Fence? {
        var cursor = index + 3
        var language = ""
        while cursor < chars.count, chars[cursor] != "\n" {
            language.append(chars[cursor])
            cursor += 1
        }
        guard cursor < chars.count else { return nil }
        let tag = language.trimmingCharacters(in: .whitespaces)
        let codeStart = cursor + 1
        var lineStart = codeStart
        while lineStart <= chars.count - 3 {
            if lineStart == 0 || chars[lineStart - 1] == "\n", matches(chars, at: lineStart, "```") {
                var code = String(chars[codeStart..<lineStart])
                if code.hasSuffix("\n") { code.removeLast() }
                var end = lineStart + 3
                if end < chars.count, chars[end] == "\n" { end += 1 }
                return Fence(code: code, language: tag.isEmpty ? nil : tag, end: end)
            }
            lineStart += 1
        }
        return Fence(code: String(chars[min(codeStart, chars.count)...]),
                     language: tag.isEmpty ? nil : tag, end: chars.count)
    }

    // MARK: - Plain text

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
        "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼",
        "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ", "j": "ʲ", "k": "ᵏ",
        "m": "ᵐ", "p": "ᵖ", "x": "ˣ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ",
        "e": "ᵉ", "t": "ᵗ", "r": "ʳ", "s": "ˢ", "*": "*", "'": "′"
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
        "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌",
        "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ", ",": ","
    ]

    /// A single-line, delimiter-free rendering for places that can't style
    /// text — list-row snippets and the `shifu review` terminal UI. Scripts
    /// become Unicode super/subscripts when every character has one, and fall
    /// back to `^(…)` / `_(…)` when they don't.
    public static func plainText(_ text: String) -> String {
        var result = ""
        for segment in segments(text) {
            switch segment {
            case .text(let plain): result += plain
            case .inlineCode(let code): result += code
            case .inlineMath(let runs): result += flatten(runs)
            // Blocks had the newlines that set them apart trimmed off in
            // `segments`, so they'd otherwise run into the surrounding words.
            case .codeBlock(let code, _): result += " \(code) "
            case .displayMath(let runs): result += " \(flatten(runs)) "
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func flatten(_ runs: [MathRun]) -> String {
        // Style splits are invisible here, and a script that spans two of them
        // ("x" + " → 0") must be mapped as one piece or neither half fits.
        var merged: [MathRun] = []
        for run in runs {
            if let last = merged.last, last.script == run.script {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        merged = merged.map { run in
            var run = run
            run.text = unspaced(run.text, script: run.script)
            return run
        }
        return merged.indices.map { index in
            // A fraction's halves are already spelled out by the slash between
            // them, so they read better flat: "a⁄b", not "ᵃ⁄_b".
            let touchesSlash = (index > 0 && merged[index - 1].text == "⁄")
                || (index + 1 < merged.count && merged[index + 1].text == "⁄")
            return touchesSlash ? merged[index].text : scripted(merged[index])
        }.joined()
    }

    /// Undoes the typographic spacing, which only means something to a
    /// renderer that can draw fractional gaps. Italic correction goes
    /// entirely; the operator gaps become ordinary spaces at the baseline and
    /// nothing at all inside a script, where they'd otherwise stop the run
    /// mapping to Unicode super/subscripts ("∑ᵢ₌₁ⁿ" rather than "∑_(i = 1)").
    private static func unspaced(_ text: String, script: Script) -> String {
        String(text.compactMap { char in
            switch char {
            case italicCorrection: return nil
            case relationSpace, operatorSpace: return script == .normal ? " " : nil
            default: return char
            }
        })
    }

    private static func scripted(_ run: MathRun) -> String {
        let table: [Character: Character]
        let marker: String
        switch run.script {
        case .normal: return run.text
        case .raised: (table, marker) = (superscripts, "^")
        case .lowered: (table, marker) = (subscripts, "_")
        }
        let mapped = run.text.map { table[$0] }
        guard !mapped.contains(where: { $0 == nil }) else {
            return run.text.count == 1 ? "\(marker)\(run.text)" : "\(marker)(\(run.text))"
        }
        return String(mapped.compactMap { $0 })
    }
}
