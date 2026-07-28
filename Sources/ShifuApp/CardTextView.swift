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
                flow += Self.markdownText(plain)
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

    /// Styled math runs: serif italic, with raised/lowered smaller runs for
    /// scripts and fraction halves (CardMarkup.MathRun).
    static func math(_ runs: [CardMarkup.MathRun], size: CGFloat) -> AttributedString {
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            switch run.script {
            case .normal:
                piece.font = .system(size: size + 1, design: .serif).italic()
            case .raised:
                piece.font = .system(size: size * 0.72, design: .serif).italic()
                piece.baselineOffset = size * 0.38
            case .lowered:
                piece.font = .system(size: size * 0.72, design: .serif).italic()
                piece.baselineOffset = -size * 0.18
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
