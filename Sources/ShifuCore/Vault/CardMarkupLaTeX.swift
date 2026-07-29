import Foundation

/// The LaTeX half of card markup (design.md §5.2): converts one math span into
/// the styled runs `CardMarkup.segments` hands the review UI. Split from the
/// segmentation so each half stays readable on its own.
extension CardMarkup {
    /// Multi-letter operators that are set upright and keep their name: `\cos`
    /// reads as "cos", not as the product of three variables.
    static let functionNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh",
        "arcsin", "arccos", "arctan", "arg", "deg", "det", "dim", "exp", "gcd",
        "hom", "inf", "ker", "lg", "lim", "liminf", "limsup", "ln", "log",
        "max", "min", "Pr", "sup", "bmod", "mod", "pmod", "tr", "rank"
    ]

    /// Commands handled by shape rather than by symbol lookup.
    static let structuralCommands: Set<String> = [
        "frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom", "sqrt",
        "text", "textrm", "textbf", "textit", "textsf", "texttt", "mathrm",
        "mathsf", "mathtt", "mathfrak", "operatorname", "mathbf", "boldsymbol",
        "bm", "pmb", "mathbb", "mathcal", "mathscr", "mathit", "vec", "hat",
        "widehat", "bar", "overline", "tilde", "widetilde", "dot", "ddot",
        "underline", "begin", "end", "phantom", "hphantom", "vphantom",
        "hspace", "vspace", "label", "tag", "left", "right", "middle", "big",
        "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl",
        "biggr", "Biggl", "Biggr", "displaystyle", "textstyle", "scriptstyle",
        "mathstrut", "limits", "nolimits", "notag", "nonumber"
    ]

    /// Whether `\name` is LaTeX this converter understands — the test that
    /// lets a caller tell a real command apart from a lookalike escape
    /// sequence (`\frac` vs. a formfeed followed by "rac").
    public static func isKnownCommand(_ name: String) -> Bool {
        symbols[name] != nil || functionNames.contains(name)
            || structuralCommands.contains(name)
    }

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ",
        "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω", "varepsilon": "ε", "vartheta": "ϑ",
        "varphi": "φ", "varrho": "ϱ", "varsigma": "ς", "varpi": "ϖ",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓",
        "ast": "∗", "odot": "⊙", "sqcup": "⊔", "sqcap": "⊓",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠",
        "ll": "≪", "gg": "≫", "lesssim": "≲", "gtrsim": "≳",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "asymp": "≍", "propto": "∝", "infty": "∞", "triangleq": "≜",
        "coloneqq": "≔", "eqqcolon": "≕", "doteq": "≐",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "implies": "⇒", "iff": "⇔", "mapsto": "↦",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "longrightarrow": "⟶",
        "Longrightarrow": "⟹", "longleftarrow": "⟵", "hookrightarrow": "↪",
        "uparrow": "↑", "downarrow": "↓", "nearrow": "↗", "searrow": "↘",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
        "subsetneq": "⊊", "nsubseteq": "⊈", "supset": "⊃", "supseteq": "⊇",
        "preceq": "⪯", "succeq": "⪰", "prec": "≺", "succ": "≻",
        "cup": "∪", "cap": "∩", "setminus": "∖", "bigcup": "⋃", "bigcap": "⋂",
        "bigoplus": "⨁", "bigotimes": "⨂", "bigsqcup": "⨆",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "nexists": "∄", "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨",
        "wedge": "∧", "vee": "∨", "vdash": "⊢", "models": "⊨",
        "top": "⊤", "bot": "⊥", "therefore": "∴", "because": "∵",
        "nabla": "∇", "partial": "∂", "sum": "∑", "prod": "∏", "int": "∫",
        "iint": "∬", "iiint": "∭", "coprod": "∐",
        "oint": "∮", "cdots": "⋯", "dots": "…", "ldots": "…", "vdots": "⋮",
        "ddots": "⋱", "dotsc": "…", "dotsb": "⋯",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "hbar": "ℏ", "ell": "ℓ",
        "aleph": "ℵ", "Re": "ℜ", "Im": "ℑ", "wp": "℘", "prime": "′",
        "dagger": "†", "ddagger": "‡", "surd": "√", "checkmark": "✓",
        "degree": "°", "circ": "∘", "star": "⋆", "bullet": "•",
        "triangle": "△", "square": "□", "diamond": "⋄", "blacksquare": "∎",
        "oplus": "⊕", "otimes": "⊗", "ominus": "⊖", "oslash": "⊘",
        "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "mid": "|", "vert": "|", "lvert": "|", "rvert": "|",
        "|": "‖", "Vert": "‖", "lVert": "‖", "rVert": "‖",
        "quad": "  ", "qquad": "    ", "colon": ":", "infin": "∞",
        ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "\\": "\n"
    ]

    /// Converts one LaTeX span into runs. Handles symbol commands, `^`/`_`
    /// scripts, `\frac` (raised numerator ⁄ lowered denominator), `\sqrt`,
    /// accents, the math alphabets (`\mathbb`, `\mathbf`, `\mathcal`),
    /// `\begin`/`\end` environments, and `\text`; unknown commands degrade to
    /// their bare name so nothing ever disappears from a card.
    public static func mathRuns(_ latex: String) -> [MathRun] {
        var converter = LaTeXConverter()
        converter.convert(
            Array(latex.trimmingCharacters(in: .whitespacesAndNewlines)), script: .normal)
        return converter.finish()
    }

    /// The converted glyphs of a span with its scripts flattened away — the
    /// base for accents, which need one string to hang a combining mark on,
    /// and for sizing decisions that must count glyphs rather than source.
    static func flattened(_ latex: String) -> String {
        mathRuns(latex).map(\.text).joined()
    }

    static let environmentDelimiters: [String: (String, String)] = [
        "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"),
        "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", "")
    ]
}

/// Walks a LaTeX span into runs. A run's style stays unresolved while
/// converting and is settled per character at the end (`finish`), so literal
/// input and symbol-table output get the same treatment; commands that *know*
/// their style (`\text`, function names, the alphabets) say so.
private struct LaTeXConverter {
    private struct Pending {
        var text: String
        var script: CardMarkup.Script
        var style: CardMarkup.Style?
    }

    private var pending: [Pending] = []
    /// Closing delimiters owed by open `\begin{…}` environments.
    private var environments: [String] = []

    private static let accents: [String: String] = [
        "vec": "\u{20D7}", "hat": "\u{0302}", "widehat": "\u{0302}",
        "bar": "\u{0304}", "overline": "\u{0304}", "tilde": "\u{0303}",
        "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}",
        "underline": "\u{0332}"
    ]

    private static let alphabets: [String: MathAlphabet] = [
        "mathbf": .bold, "boldsymbol": .bold, "bm": .bold, "pmb": .bold,
        "mathbb": .doubleStruck, "mathcal": .script, "mathscr": .script
    ]

    /// Commands whose argument is a word, not math: set upright, unconverted.
    private static let uprightGroups: Set<String> = [
        "text", "textrm", "textbf", "textit", "textsf", "texttt",
        "mathrm", "mathsf", "mathtt", "mathfrak", "operatorname"
    ]

    /// Commands that only hint at size or spacing — the glyph itself follows.
    private static let hints: Set<String> = [
        "left", "right", "middle", "big", "Big", "bigg", "Bigg",
        "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
        "displaystyle", "textstyle", "scriptstyle", "mathstrut",
        "limits", "nolimits", "notag", "nonumber"
    ]

    /// Commands that render nothing, argument included.
    private static let invisible: Set<String> = [
        "phantom", "hphantom", "vphantom", "hspace", "vspace", "label", "tag"
    ]

    private mutating func append(
        _ text: String, script: CardMarkup.Script, style: CardMarkup.Style? = nil
    ) {
        if !text.isEmpty { pending.append(Pending(text: text, script: script, style: style)) }
    }

    mutating func convert(_ chars: [Character], script: CardMarkup.Script) {
        let end = chars.count
        var index = 0
        while index < end {
            let char = chars[index]
            if char == "\\" {
                let (command, next) = readCommand(chars, after: index, limit: end)
                index = next
                apply(command, chars, at: &index, limit: end, script: script)
            } else if char == "^" || char == "_" {
                index += 1
                let group = readGroup(chars, at: &index, limit: end)
                // Scripts don't nest visually at card sizes: inside a script,
                // a further script stays on the same level.
                let target: CardMarkup.Script = script != .normal
                    ? script : (char == "^" ? .raised : .lowered)
                convert(Array(group), script: target)
            } else if char == "&" {
                append(" ", script: script, style: .upright)   // alignment tab
                index += 1
            } else if char == "{" || char == "}" {
                index += 1   // bare braces only group; drop them
            } else {
                append(String(char), script: script)
                index += 1
            }
        }
    }

    private mutating func apply(
        _ command: String, _ chars: [Character], at index: inout Int,
        limit: Int, script: CardMarkup.Script
    ) {
        if let mark = Self.accents[command] {
            // Hang the mark on every character of the argument so it composes
            // into one grapheme instead of drifting into a run of its own,
            // where the renderer would leave it dangling.
            let base = CardMarkup.flattened(readGroup(chars, at: &index, limit: limit))
            return append(base.map { "\($0)\(mark)" }.joined(), script: script)
        }
        if let alphabet = Self.alphabets[command] {
            let group = CardMarkup.flattened(readGroup(chars, at: &index, limit: limit))
            return append(alphabet.apply(group), script: script, style: .upright)
        }
        if Self.uprightGroups.contains(command) {
            return append(readGroup(chars, at: &index, limit: limit),
                          script: script, style: .upright)
        }
        if Self.invisible.contains(command) {
            _ = readGroup(chars, at: &index, limit: limit)
            return
        }
        if Self.hints.contains(command) { return }
        applyShaped(command, chars, at: &index, limit: limit, script: script)
    }

    private mutating func applyShaped(
        _ command: String, _ chars: [Character], at index: inout Int,
        limit: Int, script: CardMarkup.Script
    ) {
        switch command {
        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = readGroup(chars, at: &index, limit: limit)
            let denominator = readGroup(chars, at: &index, limit: limit)
            // Raised-over-lowered around a fraction slash reads as a built-up
            // fraction at card sizes. Inside a script there's no room to build
            // up, so it collapses to the inline `a⁄b` form.
            convert(Array(numerator), script: script == .normal ? .raised : script)
            append("⁄", script: script, style: .upright)
            convert(Array(denominator), script: script == .normal ? .lowered : script)
        case "binom", "dbinom", "tbinom":
            let top = readGroup(chars, at: &index, limit: limit)
            let bottom = readGroup(chars, at: &index, limit: limit)
            append("(", script: script, style: .upright)
            convert(Array(top), script: script == .normal ? .raised : script)
            convert(Array(bottom), script: script == .normal ? .lowered : script)
            append(")", script: script, style: .upright)
        case "sqrt": radical(chars, at: &index, limit: limit, script: script)
        case "mathit":
            let group = readGroup(chars, at: &index, limit: limit)
            append(CardMarkup.flattened(group), script: script, style: .variable)
        case "begin": beginEnvironment(chars, at: &index, limit: limit, script: script)
        case "end":
            _ = readGroup(chars, at: &index, limit: limit)
            append(environments.popLast() ?? "", script: script, style: .upright)
        default:
            if let symbol = CardMarkup.symbols[command] {
                append(symbol, script: script)
            } else if CardMarkup.functionNames.contains(command) {
                append(command, script: script, style: .upright)
            } else {
                append(command, script: script)   // unknown: never vanish
            }
        }
    }

    private mutating func radical(
        _ chars: [Character], at index: inout Int, limit: Int, script: CardMarkup.Script
    ) {
        if index < limit, chars[index] == "[" {   // \sqrt[n]{…} — the index has
            while index < limit, chars[index] != "]" { index += 1 }   // nowhere
            index += 1                                                // to go
        }
        let radicand = readGroup(chars, at: &index, limit: limit)
        append("√", script: script, style: .upright)
        // Parenthesised only when the radicand is wider than one glyph —
        // measured after conversion, so `\sqrt{\alpha}` is a bare √α.
        let parenthesised = CardMarkup.flattened(radicand).count > 1
        if parenthesised { append("(", script: script, style: .upright) }
        convert(Array(radicand), script: script)
        if parenthesised { append(")", script: script, style: .upright) }
    }

    private mutating func beginEnvironment(
        _ chars: [Character], at index: inout Int, limit: Int, script: CardMarkup.Script
    ) {
        let name = readGroup(chars, at: &index, limit: limit)
        let key = name.hasSuffix("*") ? String(name.dropLast()) : name
        if key == "array" || key == "tabular" {
            _ = readGroup(chars, at: &index, limit: limit)   // column spec
        }
        let (open, close) = CardMarkup.environmentDelimiters[key] ?? ("", "")
        environments.append(close)
        append(open, script: script, style: .upright)
    }

    mutating func finish() -> [CardMarkup.MathRun] {
        // An unterminated environment still owes its closer.
        while let close = environments.popLast() {
            append(close, script: .normal, style: .upright)
        }
        // Spacing needs to see across command boundaries — `\alpha + \beta`
        // arrives as three separate items — so the runs are broken down to
        // atoms first and reassembled once the whole span is known.
        var atoms: [MathAtom] = []
        var index = pending.startIndex
        while index < pending.endIndex {
            if let style = pending[index].style {
                let item = pending[index]
                atoms += item.text.map {
                    MathAtom(char: $0, script: item.script, style: style, isLiteral: true)
                }
                index += 1
                continue
            }
            // Ordinary characters arrive one at a time, so the whole
            // unstyled stretch has to be gathered before classifying it —
            // otherwise "cos" is three lone letters and never reads as a word.
            let script = pending[index].script
            var text = ""
            while index < pending.endIndex, pending[index].style == nil,
                  pending[index].script == script {
                text += pending[index].text
                index += 1
            }
            for run in CardMarkup.classify(text, script: script) {
                atoms += run.text.map {
                    MathAtom(char: $0, script: script, style: run.style, isLiteral: false)
                }
            }
        }
        return CardMarkup.trimmingEdges(assembleMath(atoms))
    }

    /// `\command` name after a backslash: a letter word, or one symbol char.
    private func readCommand(
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
    private func readGroup(_ chars: [Character], at index: inout Int, limit: Int) -> String {
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
}

/// A Unicode math alphabet (`\mathbb` → ℝ, `\mathbf` → 𝐱). The blocks are
/// contiguous except where a letter was already encoded in the BMP, which is
/// what the exception table patches.
private struct MathAlphabet {
    var upper: UInt32?
    var lower: UInt32?
    var digit: UInt32?
    var exceptions: [Character: Character] = [:]

    static let bold = MathAlphabet(upper: 0x1D400, lower: 0x1D41A, digit: 0x1D7CE)
    static let doubleStruck = MathAlphabet(
        upper: 0x1D538, lower: 0x1D552, digit: 0x1D7D8,
        exceptions: ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ",
                     "Q": "ℚ", "R": "ℝ", "Z": "ℤ"])
    static let script = MathAlphabet(
        upper: 0x1D49C, lower: 0x1D4B6, digit: nil,
        exceptions: ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ",
                     "L": "ℒ", "M": "ℳ", "R": "ℛ",
                     "e": "ℯ", "g": "ℊ", "o": "ℴ"])

    func apply(_ text: String) -> String {
        String(text.map { char in
            if let replacement = exceptions[char] { return replacement }
            guard char.isASCII, let scalar = char.unicodeScalars.first else { return char }
            let base: (UInt32, UInt32)? = switch scalar.value {
            case 0x41...0x5A: upper.map { ($0, 0x41) }
            case 0x61...0x7A: lower.map { ($0, 0x61) }
            case 0x30...0x39: digit.map { ($0, 0x30) }
            default: nil
            }
            guard let (start, origin) = base,
                  let mapped = Unicode.Scalar(start + scalar.value - origin)
            else { return char }
            return Character(mapped)
        })
    }
}
