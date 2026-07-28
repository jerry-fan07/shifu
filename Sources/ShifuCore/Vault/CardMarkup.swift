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
    }

    public enum Script: Sendable { case normal, raised, lowered }

    /// One styled slice of converted math: baseline text, or a raised /
    /// lowered run (exponents, indices, fraction halves).
    public struct MathRun: Equatable, Sendable {
        public var text: String
        public var script: Script

        public init(_ text: String, script: Script = .normal) {
            self.text = text
            self.script = script
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
                if !plain.isEmpty { result.append(.text(plain)) }
                plain = ""
                result.append(segment)
                index = next
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

    // MARK: - LaTeX → styled runs

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ",
        "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "propto": "∝", "infty": "∞",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "implies": "⇒", "iff": "⇔", "mapsto": "↦",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "cup": "∪", "cap": "∩", "setminus": "∖",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "neg": "¬", "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨",
        "nabla": "∇", "partial": "∂", "sum": "∑", "prod": "∏", "int": "∫",
        "oint": "∮", "cdots": "⋯", "dots": "…", "ldots": "…", "vdots": "⋮",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "hbar": "ℏ", "ell": "ℓ",
        "degree": "°", "circ": "∘", "star": "⋆", "bullet": "•",
        "oplus": "⊕", "otimes": "⊗", "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "mid": "|", "|": "‖", "quad": "  ", "qquad": "    ",
        ",": " ", ";": " ", " ": " ", "\\": "\n"
    ]

    /// Converts one LaTeX span into runs. Handles symbol commands, `^`/`_`
    /// scripts, `\frac` (raised numerator ⁄ lowered denominator), `\sqrt`,
    /// and `\text`; unknown commands degrade to their bare name so nothing
    /// ever disappears from a card.
    public static func mathRuns(_ latex: String) -> [MathRun] {
        var runs: [MathRun] = []
        convert(Array(latex), from: 0, to: latex.count, script: .normal, into: &runs)
        return coalesce(runs)
    }

    private static func convert(
        _ chars: [Character], from start: Int, to end: Int,
        script: Script, into runs: inout [MathRun]
    ) {
        var index = start
        func append(_ text: String) {
            if !text.isEmpty { runs.append(MathRun(text, script: script)) }
        }
        while index < end {
            let char = chars[index]
            if char == "\\" {
                let (command, next) = readCommand(chars, after: index, limit: end)
                index = next
                switch command {
                case "frac":
                    let numerator = readGroup(chars, at: &index, limit: end)
                    let denominator = readGroup(chars, at: &index, limit: end)
                    // Raised-over-lowered around a fraction slash reads as a
                    // built-up fraction at card sizes; nested scripts flatten.
                    convert(Array(numerator), from: 0, to: numerator.count,
                            script: .raised, into: &runs)
                    runs.append(MathRun("⁄", script: script))
                    convert(Array(denominator), from: 0, to: denominator.count,
                            script: .lowered, into: &runs)
                case "sqrt":
                    let radicand = readGroup(chars, at: &index, limit: end)
                    append(radicand.count > 1 ? "√(\(radicand))" : "√\(radicand)")
                case "text", "mathrm", "operatorname":
                    append(readGroup(chars, at: &index, limit: end))
                case "left", "right", "big", "Big", "displaystyle":
                    break   // sizing/delimiter hints — the glyph itself follows
                default:
                    append(symbols[command] ?? command)
                }
            } else if char == "^" || char == "_" {
                index += 1
                let target: Script = char == "^" ? .raised : .lowered
                let group = readGroup(chars, at: &index, limit: end)
                convert(Array(group), from: 0, to: group.count, script: target, into: &runs)
            } else if char == "{" || char == "}" {
                index += 1   // bare braces only group; drop them
            } else {
                append(String(char))
                index += 1
            }
        }
    }

    /// `\command` name after a backslash: a letter word, or one symbol char.
    private static func readCommand(
        _ chars: [Character], after backslash: Int, limit: Int
    ) -> (name: String, next: Int) {
        var index = backslash + 1
        guard index < limit else { return ("", index) }
        if !chars[index].isLetter {
            return (String(chars[index]), index + 1)
        }
        var name = ""
        while index < limit, chars[index].isLetter {
            name.append(chars[index])
            index += 1
        }
        return (name, index)
    }

    /// The `{…}` group at `index` (brace-balanced), or the single character
    /// there — the two argument shapes LaTeX allows.
    private static func readGroup(_ chars: [Character], at index: inout Int, limit: Int) -> String {
        guard index < limit else { return "" }
        guard chars[index] == "{" else {
            defer { index += 1 }
            return String(chars[index])
        }
        var depth = 1
        var cursor = index + 1
        var group = ""
        while cursor < limit, depth > 0 {
            if chars[cursor] == "{" { depth += 1 }
            if chars[cursor] == "}" { depth -= 1 }
            if depth > 0 { group.append(chars[cursor]) }
            cursor += 1
        }
        index = cursor
        return group
    }

    private static func coalesce(_ runs: [MathRun]) -> [MathRun] {
        var merged: [MathRun] = []
        for run in runs {
            if let last = merged.last, last.script == run.script {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
