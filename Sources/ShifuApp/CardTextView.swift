import ShifuCore
import SwiftUI

/// Renders card text with math and code formatting, natively (§7: no web
/// views): CardMarkup segments become styled AttributedString flow, code
/// blocks, and centered display math.
struct CardTextView: View {
    let text: String
    var baseSize: CGFloat = 13
    var alignment: TextAlignment = .leading

    /// One vertical slab: inline flow (text, inline math/code), or a block.
    private enum Block {
        case flow(AttributedString)
        case heading(String, level: Int)
        case displayMath(AttributedString)
        case code(String, language: String?)
    }

    var body: some View {
        let blocks = makeBlocks()
        VStack(alignment: horizontalAlignment, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .flow(let attributed):
                    Text(attributed)
                        .font(.system(size: baseSize))
                        .multilineTextAlignment(alignment)
                        .textSelection(.enabled)
                case .heading(let title, let level):
                    Text(Self.markdownText(title))
                        .font(.system(size: baseSize + Self.headingBump(level),
                                      weight: .semibold))
                        .multilineTextAlignment(alignment)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .displayMath(let attributed):
                    Text(attributed)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language, baseSize: baseSize)
                }
            }
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func makeBlocks() -> [Block] {
        var blocks: [Block] = []
        var flow = AttributedString()
        func flushFlow() {
            let plain = String(flow.characters)
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.flow(flow))
            }
            flow = AttributedString()
        }
        for segment in CardMarkup.segments(text) {
            switch segment {
            case .text(let plain):
                // `#`-prefixed lines are their own slab. The detailed day
                // notes emit `### Learned / decided` sections, and the inline
                // Markdown parser leaves those hashes on screen verbatim.
                var run = ""
                for line in plain.components(separatedBy: "\n") {
                    guard let title = Self.headingTitle(line) else {
                        run += run.isEmpty ? line : "\n" + line
                        continue
                    }
                    if !run.isEmpty {
                        flow += Self.markdownText(run)
                        run = ""
                    }
                    flushFlow()
                    blocks.append(.heading(title.text, level: title.level))
                }
                if !run.isEmpty { flow += Self.markdownText(run) }
            case .inlineCode(let code):
                flow += Self.inlineCode(code, size: baseSize)
            case .inlineMath(let runs):
                flow += Self.math(runs, size: baseSize)
            case .displayMath(let runs):
                flushFlow()
                blocks.append(.displayMath(Self.math(runs, size: baseSize + 3)))
            case .codeBlock(let code, let language):
                flushFlow()
                blocks.append(.code(code, language: language))
            }
        }
        flushFlow()
        return blocks
    }

    // MARK: - AttributedString builders

    /// `## Title` → ("Title", 2), for `#` through `###`. A `#` without a
    /// following space is not a heading — `#1` and `#swift` are ordinary text.
    static func headingTitle(_ line: String) -> (text: String, level: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (title, level)
    }

    /// Headings stay close to body size — these sit inside note bodies, not
    /// at the top of a page.
    static func headingBump(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 4
        case 2: return 2
        default: return 1
        }
    }

    /// Plain text through the inline Markdown parser so **bold** / *italic*
    /// in extracted notes render; falls back to the literal string.
    static func markdownText(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func inlineCode(_ code: String, size: CGFloat) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.font = .system(size: size - 0.5, design: .monospaced)
        attributed.backgroundColor = .primary.opacity(0.08)
        return attributed
    }

    /// Styled math runs: serif throughout, italic only for variables so
    /// digits, operators and function names stay upright the way a typeset
    /// formula has them, with raised/lowered smaller runs for scripts and
    /// fraction halves (CardMarkup.MathRun).
    static func math(_ runs: [CardMarkup.MathRun], size: CGFloat) -> AttributedString {
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            let pointSize = run.script == .normal ? size + 1 : size * 0.72
            let font = Font.system(size: pointSize, design: .serif)
            piece.font = run.style == .variable ? font.italic() : font
            switch run.script {
            case .normal: break
            case .raised: piece.baselineOffset = size * 0.38
            case .lowered: piece.baselineOffset = -size * 0.18
            }
            attributed += piece
        }
        return attributed
    }
}

/// One fenced code block: monospaced, selectable, on a recessive surface with
/// the language tag as a corner caption.
struct CodeBlockView: View {
    let code: String
    let language: String?
    var baseSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(code)
                .font(.system(size: baseSize - 0.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
