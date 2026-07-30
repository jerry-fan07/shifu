import AppKit
import ShifuCore
import SwiftUI

/// First run (design.md §7): four steps — what is captured, the two
/// permissions, what stays unseen, and whether a model may be consulted.
/// Local-only is the default, and every screen's job is to make the next one
/// unsurprising.
struct OnboardingView: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var step = 0
    @State private var backend = "deepseek"
    @State private var apiKey = ""

    private static let steps = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ticks
            Text(title)
                .font(Instrument.sans(24, .semibold))
                .tracking(-0.36)
                .foregroundStyle(Instrument.ink)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case 0: capturePage
                    case 1: permissionsPage
                    case 2: exclusionsPage
                    default: backendPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Rule(weight: .section)
            footer
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .frame(maxWidth: 560, maxHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Instrument.ground)
    }

    /// Four ticks, not a percentage: the flow is short enough to count.
    private var ticks: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.steps, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Instrument.accent : Instrument.well)
                    .frame(width: 34, height: 3)
            }
        }
        .padding(.bottom, 18)
    }

    private var title: String {
        switch step {
        case 0: return "It watches you work."
        case 1: return "Two permissions, then it's watching"
        case 2: return "What stays unseen"
        default: return "A model may be consulted"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                InlineLink("Back", size: 12.5) { step -= 1 }
            }
            Figure(note, size: 11, color: Instrument.ghost)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if step < Self.steps - 1 {
                SolidButton(title: "Next") { step += 1 }
            } else {
                SolidButton(title: "Begin", action: finish)
            }
        }
        .padding(.vertical, 14)
    }

    /// The promise that matters most on each step, in the register that says
    /// it is a rule rather than a reassurance.
    private var note: String {
        switch step {
        case 0: return "Raw text is deleted after 14 days."
        case 1: return "Pixels are never saved. Screenshots live in memory for one OCR call."
        case 2: return "Exclusions are enforced before capture, not filtered after."
        default: return "Nothing leaves this Mac until you add a key."
        }
    }

    // MARK: - Steps

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            prose("""
            Not to judge — to remember. Shifu captures **text and metadata** about what is \
            on your screen — app, window title, visible text — and turns it into a time \
            ledger, a knowledge vault, and automation suggestions.
            """)
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("What it never does")
                ForEach([
                    "never records keystrokes",
                    "never saves screenshots — pixels live in memory only, for OCR",
                    "never sends raw captures anywhere"
                ], id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Figure("×", size: 12, weight: .medium, color: Instrument.alert)
                        Text(line)
                            .font(Instrument.sans(13))
                            .foregroundStyle(Instrument.body)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            prose("""
            The capture daemon runs from `~/Shifu/bin` and needs both, from System \
            Settings → Privacy & Security. Shifu can't read the daemon's grant state from \
            here — the ledger filling up is the proof.
            """)
            permission(
                "Accessibility",
                detail: "Window titles and visible text — the cheap path.",
                url: "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_Accessibility")
            permission(
                "Screen Recording",
                detail: "The OCR fallback for apps that expose no text. Without it Shifu "
                    + "keeps working on metadata alone.",
                url: "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_ScreenCapture")
        }
    }

    private func permission(_ name: String, detail: String, url: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(color: Instrument.alert)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(name)
                        .font(Instrument.sans(13.5, .semibold))
                        .foregroundStyle(Instrument.ink)
                    Spacer(minLength: 0)
                    SolidButton(title: "Open Settings") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }
                }
                Text(detail)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var exclusionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            prose("""
            Excluded content is never read. Only an opaque "private time" duration is \
            counted, and it shows on the ribbon as hatching rather than as a gap.
            """)
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("Never inspected")
                ForEach([
                    "password managers and Keychain",
                    "banking, payment, and health sites",
                    "private and incognito browser windows — always, not configurable",
                    "cards, SSNs, and secret-shaped strings, redacted before any write"
                ], id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Figure("·", size: 12, weight: .medium, color: Instrument.ghost)
                        Text(line)
                            .font(Instrument.sans(13))
                            .foregroundStyle(Instrument.body)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var backendPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            prose("""
            Task naming, ambiguous-time classification, and knowledge extraction use \
            DeepSeek. Without a key those stages are skipped and Shifu runs on rules alone.
            """)
            SegmentedBar(
                options: [("DeepSeek", "deepseek"), ("Rules only", "off")],
                selection: $backend)
            if backend == "deepseek" {
                SecureField("DeepSeek API key (or set DEEPSEEK_API_KEY)", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(Instrument.mono(12))
                    .foregroundStyle(Instrument.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Instrument.edge, lineWidth: 1)
                    }
                Text("Only derived text samples are sent, after exclusions and redaction. "
                    + "Never pixels. Defaults: deepseek-v4-flash for classification, "
                    + "deepseek-v4-pro for grouping — change either in Settings.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Body copy. A literal string, not a concatenation: `Text` only parses
    /// the **markdown** through its LocalizedStringKey initializer.
    private func prose(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Instrument.sans(14))
            .lineSpacing(5)
            .foregroundStyle(Instrument.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 470, alignment: .leading)
    }

    private func finish() {
        if let database = try? ShifuDatabase.open(at: ShifuPaths.database) {
            try? Settings.set(Settings.analysisBackendKey, to: backend, database: database)
            if backend == "deepseek" && !apiKey.isEmpty {
                try? Settings.set(Settings.deepseekAPIKeyKey, to: apiKey, database: database)
            }
        }
        onboarded = true
    }
}
