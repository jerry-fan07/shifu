import Foundation

/// Math spacing (design.md §5.2). TeX sets a formula by what its symbols
/// *are* — a relation gets a wider gap than a binary operator, an italic
/// glyph gets a correction before an upright one — rather than by whatever
/// the author typed. That matters here because the author is a model, and
/// models type math with wildly uneven spacing.
extension CardMarkup {
    /// Uppercase Greek is upright in TeX's default math italic, unlike the
    /// lowercase letters — so it can't be settled by `isLetter` alone.
    private static let uprightLetters: Set<Character> = [
        "Γ", "Δ", "Θ", "Λ", "Ξ", "Π", "Σ", "Υ", "Φ", "Ψ", "Ω"
    ]

    /// Splits ordinary math text into italic variable runs and upright runs.
    /// Iteration is by grapheme, so an accented base ("x̂") stays one character
    /// and keeps its base letter's style. A bare word that spells a function
    /// name is set upright even without its backslash — models drop it often,
    /// and "cos θ" in italics reads as three variables multiplied together.
    static func classify(_ text: String, script: Script) -> [MathRun] {
        var runs: [MathRun] = []
        func add(_ text: String, _ style: Style) {
            if var last = runs.last, last.style == style {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(MathRun(text, script: script, style: style))
            }
        }
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            var cursor = index
            while cursor < chars.count, chars[cursor].isASCII, chars[cursor].isLetter {
                cursor += 1
            }
            let word = String(chars[index..<cursor])
            if functionNames.contains(word) {
                add(word, .upright)
                index = cursor
                continue
            }
            let char = chars[index]
            add(String(char), char.isLetter && !uprightLetters.contains(char)
                ? .variable : .upright)
            index += 1
        }
        return runs
    }

    // MARK: - Inter-atom spacing

    // TeX's three gaps, as Unicode fixed spaces so the runs stay plain text
    // that `plainText` can undo for a terminal.
    static let relationSpace: Character = "\u{2005}"     // four-per-em, 1/4 em
    static let operatorSpace: Character = "\u{2009}"     // thin, 1/5 em
    static let italicCorrection: Character = "\u{200A}"  // hair

    /// Relations take the widest gap: they separate two halves of a claim.
    static let relations: Set<Character> = [
        "=", "≠", "<", ">", "≤", "≥", "≈", "≡", "∼", "≃", "≅", "≍", "≐",
        "∈", "∉", "∋", "⊂", "⊆", "⊊", "⊈", "⊃", "⊇", "≺", "≻", "⪯", "⪰",
        "≪", "≫", "≲", "≳", "∝", "≜", "≔", "≕", "⊢", "⊨", ":",
        "→", "←", "↔", "⇒", "⇐", "⇔", "↦", "⟶", "⟵", "⟹", "↪"
    ]

    /// Binary operators take a narrower gap: they join two operands into one.
    static let binaryOperators: Set<Character> = [
        "+", "−", "±", "∓", "×", "÷", "·", "∗", "∪", "∩", "∖", "⊔", "⊓",
        "⊕", "⊗", "⊖", "⊘", "⊙", "∧", "∨"
    ]

    /// What a binary operator needs on its left to *be* binary — otherwise
    /// it's a sign, and "−1" must not open with a gap the way "a − 1" does.
    static func isOperand(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || ")]}‖|⟩⌋⌉!′".contains(char)
    }

    /// Whitespace at the outside of a span is layout, not math — it survives
    /// the up-front trim when a command produces it (`\begin{aligned} x`,
    /// `\quad x`) and would push centred display math off its axis.
    static func trimmingEdges(_ runs: [MathRun]) -> [MathRun] {
        var trimmed = runs
        while var first = trimmed.first {
            while let char = first.text.first, char.isWhitespace { first.text.removeFirst() }
            if first.text.isEmpty { trimmed.removeFirst() } else { trimmed[0] = first; break }
        }
        while var last = trimmed.last {
            while let char = last.text.last, char.isWhitespace { last.text.removeLast() }
            if last.text.isEmpty {
                trimmed.removeLast()
            } else {
                trimmed[trimmed.count - 1] = last
                break
            }
        }
        return trimmed
    }

    static func coalesce(_ runs: [MathRun]) -> [MathRun] {
        var merged: [MathRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.script == run.script, last.style == run.style {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}

/// One converted character, before spacing has been decided. `isLiteral`
/// marks text that came from `\text`/`\mathrm` and friends: a hyphen in
/// "well-known" is not a minus sign, and its spaces are the author's.
struct MathAtom {
    var char: Character
    var script: CardMarkup.Script
    var style: CardMarkup.Style
    var isLiteral: Bool
}

/// Builds the final runs, inserting TeX's inter-atom spacing as it goes: a gap
/// around relations, a narrower one around binary operators, and an italic
/// correction wherever a leaning glyph meets an upright one — without which
/// "‖x‖" renders with the bars welded onto the x.
func assembleMath(_ atoms: [MathAtom]) -> [CardMarkup.MathRun] {
    var runs: [CardMarkup.MathRun] = []
    var owed: Character?   // space the previous atom asked to have after it

    func emit(_ text: String, _ script: CardMarkup.Script, _ style: CardMarkup.Style) {
        if var last = runs.last, last.script == script, last.style == style {
            last.text += text
            runs[runs.count - 1] = last
        } else {
            runs.append(CardMarkup.MathRun(text, script: script, style: style))
        }
    }

    for index in atoms.indices {
        var atom = atoms[index]
        let previous = index > 0 ? atoms[index - 1] : nil
        let next = index + 1 < atoms.count ? atoms[index + 1] : nil
        if !atom.isLiteral, atom.char == "-" { atom.char = "−" }   // the real minus

        var wanted: Character?
        var after: Character?
        if atom.isLiteral || atom.char.isWhitespace {
            wanted = nil
        } else if CardMarkup.relations.contains(atom.char) {
            wanted = scaled(CardMarkup.relationSpace, atom.script)
            after = wanted
        } else if CardMarkup.binaryOperators.contains(atom.char), next != nil,
                  let previous, CardMarkup.isOperand(previous.char),
                  // Binary needs an operand on its left. Dropping *into* a
                  // script starts a fresh sub-formula, so the "−" of x^{-1}
                  // is a sign; climbing back out of one doesn't, so the "+"
                  // of a^2+b^2 still joins two operands.
                  previous.script == atom.script || atom.script == .normal {
            wanted = scaled(CardMarkup.operatorSpace, atom.script)
            after = wanted
        } else if !atom.isLiteral, ",;".contains(atom.char) {
            after = scaled(CardMarkup.operatorSpace, atom.script)   // "[0, 1]"
        } else if let previous, previous.style == .variable, atom.style == .upright,
                  previous.script == atom.script, !",.;:".contains(atom.char) {
            // Only along the baseline: a script sits above or below its base,
            // so "x²" has nothing to collide with and wants no gap at all.
            wanted = CardMarkup.italicCorrection
        }

        // The wider of the two claims wins, and neither applies next to a
        // space the author already typed.
        let space = [owed, wanted].compactMap { $0 }.max { width($0) < width($1) }
        if let space, let previous, !previous.char.isWhitespace, !atom.char.isWhitespace {
            emit(String(space), atom.script, .upright)
        }
        owed = after
        emit(String(atom.char), atom.script, atom.style)
    }
    return runs
}

/// TeX measures these gaps in `mu`, which shrink with the current math size,
/// so a script's spacing is tighter than the baseline's — otherwise a
/// subscript like "i=1" is set at 72% with full-size gaps around it.
private func scaled(_ space: Character, _ script: CardMarkup.Script) -> Character {
    guard script != .normal else { return space }
    return space == CardMarkup.relationSpace
        ? CardMarkup.operatorSpace : CardMarkup.italicCorrection
}

private func width(_ space: Character) -> Int {
    switch space {
    case CardMarkup.relationSpace: return 3
    case CardMarkup.operatorSpace: return 2
    default: return 1
    }
}
