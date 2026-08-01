import AppKit
import ShifuCore
import SwiftUI

// The six pages first run turns (design.md §7), and the rail furniture that
// counts them off. Split out of OnboardingView.swift for length only — the
// shell that frames them, and everything that is actually decided, lives
// there.

// MARK: - The beats

/// The six things first run has to say, in the order that makes each one
/// unsurprising. The rail lists them by these names; the page titles them.
enum Beat: Int, CaseIterable, Identifiable {
    case capture, permissions, exclusions, backend, focus, firstHour

    var id: Int { rawValue }

    /// The rail's name for it: short enough to sit in a 196 pt column.
    var railTitle: String {
        switch self {
        case .capture: return "What it keeps"
        case .permissions: return "Permissions"
        case .exclusions: return "Exclusions"
        case .backend: return "A mind, or none"
        case .focus: return "Focus Mode"
        case .firstHour: return "The first hour"
        }
    }

    var title: String {
        switch self {
        case .capture: return "It watches you work."
        case .permissions: return "Two permissions, then it's watching"
        case .exclusions: return "What stays unseen"
        case .backend: return "A model may be consulted"
        case .focus: return "A nudge, not a wall"
        case .firstHour: return "Give it an hour"
        }
    }

    /// "Step one of six" — spelled out, because a flow short enough to count
    /// shouldn't be reported as a fraction.
    var ordinal: String {
        let words = ["one", "two", "three", "four", "five", "six"]
        return "Step \(words[rawValue]) of \(words[Beat.allCases.count - 1])"
    }

    /// The promise that matters most on this beat, for the rail's foot — in
    /// the register that says it is a rule rather than a reassurance. Nil on
    /// the last two beats, whose foot shows the live thing instead: the Focus
    /// Mode switch, then the capture state.
    var promise: String? {
        switch self {
        case .capture: return "Nothing is captured until this flow ends."
        case .permissions:
            return "Pixels are never saved. Screenshots live in memory for one OCR call."
        case .exclusions: return "Exclusions are enforced before capture, not filtered after."
        case .backend: return "Nothing leaves this Mac unless you switch this on. "
            + "Off is the default."
        case .focus, .firstHour: return nil
        }
    }

    /// The line the page's own footer carries, where there is one. The rest of
    /// each beat's small print lives in the rail's foot.
    var note: String? {
        switch self {
        case .capture, .firstHour: return "Raw text is deleted after 14 days."
        case .focus: return "Captures nothing extra."
        default: return nil
        }
    }
}

/// One beat in the rail: its number, or a tick once it is behind you.
struct BeatRow: View {
    let beat: Beat
    let current: Bool
    /// Nil for the beats you haven't reached — the row is a label until then.
    let action: (() -> Void)?

    var body: some View {
        row
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(
                current ? Instrument.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .modifier(TappableRow(action: action))
    }

    private var row: some View {
        HStack(spacing: 9) {
            Figure(
                mark, size: 11,
                color: done || current ? Instrument.accentText : Instrument.ghost)
            Text(beat.railTitle)
                .font(Instrument.sans(13, current ? .medium : .regular))
                .foregroundStyle(current ? Instrument.ink : Instrument.railInk)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var done: Bool { action != nil }

    private var mark: String { done ? "✓" : String(format: "%02d", beat.rawValue + 1) }
}

/// Makes a row a button only when it leads somewhere — a plain `Button` with a
/// no-op action still reads as one to VoiceOver and still takes a click.
private struct TappableRow: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - 01 · What it keeps

struct CaptureBeat: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("""
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
                    Bullet(line, mark: "×", color: Instrument.alert)
                }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - 02 · Permissions

struct PermissionsBeat: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("""
            The capture daemon starts at login (System Settings → Login Items) and needs \
            both, from System Settings → Privacy & Security. Shifu can't read the daemon's \
            grant state from here — the ledger filling up is the proof.
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
}

// MARK: - 03 · Exclusions

struct ExclusionsBeat: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("""
            Excluded content is never read. Only an opaque "private time" duration is \
            counted, and it shows on the ribbon as hatching rather than as a gap.
            """)
            ribbon
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("Never inspected")
                ForEach([
                    "password managers and Keychain",
                    "banking, payment, and health sites",
                    "private and incognito browser windows — always, not configurable",
                    "cards, SSNs, and secret-shaped strings, redacted before any write"
                ], id: \.self) { line in
                    Bullet(line)
                }
            }
        }
    }

    /// What "hatching rather than a gap" looks like, since the sentence is
    /// about a mark. Sample proportions, not a reading: the ledger is empty
    /// until this flow ends, so the key names the two kinds of stretch and
    /// carries no figures that could be mistaken for the user's own.
    private var ribbon: some View {
        VStack(alignment: .leading, spacing: 6) {
            Ribbon(segments: [
                RibbonSegment(id: 0, weight: 26, fill: .series(Instrument.strong)),
                RibbonSegment(id: 1, weight: 12, fill: .series(Instrument.mid)),
                RibbonSegment(id: 2, weight: 14, fill: .hidden),
                RibbonSegment(id: 3, weight: 22, fill: .series(Instrument.soft)),
                RibbonSegment(id: 4, weight: 9, fill: .series(Instrument.warm)),
                RibbonSegment(id: 5, weight: 17, fill: .gap)
            ])
            HStack(spacing: 14) {
                key("private", color: Instrument.quiet, hatched: true)
                key("read", color: Instrument.strong, hatched: false)
            }
        }
    }

    private func key(_ label: String, color: Color, hatched: Bool) -> some View {
        HStack(spacing: 5) {
            SeriesSwatch(color: color, hatched: hatched)
            Eyebrow(label)
        }
    }
}

// MARK: - 04 · A mind, or none

/// The consent gate (§8). Nothing here is preselected: for a screen observer,
/// sending anything anywhere has to be the user's affirmative act, so each
/// disclosure appears only under the choice it describes.
struct BackendBeat: View {
    @Binding var backend: String
    @Binding var apiKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("""
            Task naming, ambiguous-time classification, and knowledge extraction use a \
            model. Off, those stages are skipped and Shifu runs on rules alone — nothing \
            ever leaves this Mac.
            """)
            SegmentedBar(
                options: [
                    ("Rules only", "off"),
                    ("Shifu Cloud", "shifu-cloud"),
                    ("Own API key", "deepseek")
                ],
                selection: $backend)
            if backend == "off" {
                // What "rules alone" costs, spelled out — otherwise the default
                // reads as the safe *and* free choice, and it is only the first.
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("What each stage does without one")
                    ForEach([
                        "tasks keep the app's name instead of the work's",
                        "ambiguous stretches land in Unclassified rather than guessing",
                        "the vault stays empty — knowledge extraction is a model stage"
                    ], id: \.self) { line in
                        Bullet(line)
                    }
                }
            }
            if backend == "shifu-cloud" {
                Aside("No key and no account: redacted, post-exclusion text samples go to "
                    + "Shifu's server, which forwards them to DeepSeek — an AI provider "
                    + "based in China — and holds the credentials. Never pixels, never "
                    + "raw captures. Choosing this is the switch; flip it back anytime "
                    + "in Settings.")
            }
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
                Aside("Only derived text samples are sent, after exclusions and redaction — "
                    + "straight to DeepSeek with your key, never through Shifu's server. "
                    + "Defaults: deepseek-v4-flash for classification, deepseek-v4-pro "
                    + "for grouping — change either in Settings.")
            }
            Aside("Change it in Settings → Analysis at any time; switching it off stops "
                + "the stages immediately.")
        }
    }
}

// MARK: - 05 · Focus Mode

struct FocusBeat: View {
    let demo: NudgeDemo

    /// "4.4s" — read off the pulse rather than typed, so the page can't claim
    /// a length the daemon has stopped animating.
    private static let pulseLength = String(format: "%.1fs", FocusNudge.pulse)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("""
            When Focus Mode is on, drifting off what you said you were doing pulses a glow \
            at the edge of the screen. It blocks nothing, closes nothing, and reports to \
            nobody.
            """)
            VStack(alignment: .leading, spacing: 9) {
                Eyebrow("The nudge")
                HStack(spacing: 14) {
                    // Still, at the pulse's peak. The breath itself is what the
                    // button below is for — an animation looping in the corner
                    // of a page you are reading is the one thing the real nudge
                    // is careful not to be.
                    NudgeMiniature()
                        .frame(height: 88)
                    VStack(alignment: .leading, spacing: 5) {
                        Figure("glow at the screen edge", size: 10.5,
                               color: Instrument.muted)
                        Figure("one line, on the screen you are on", size: 10.5,
                               color: Instrument.muted)
                        Figure("gone in \(Self.pulseLength)", size: 10.5,
                               color: Instrument.ghost)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.edge, lineWidth: 1)
            }
            HStack(spacing: 12) {
                OutlineButton(title: "Show me the nudge", tinted: true) { demo.present() }
                    .fixedSize()
                Text("Click to see a demonstration of the nudge, which you can disable "
                    + "in settings.")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 06 · The first hour

struct FirstHourBeat: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Prose("""
            The daemon registers itself as a Login Item and starts keeping the ledger. \
            There is nothing left to configure — the proof that everything is wired is the \
            ledger beginning to fill.
            """)
            // Today's rail, which is empty, because nothing has been captured
            // yet. An empty instrument is the honest picture of where the user
            // is standing — and it needs the eyebrow, or a blank track reads as
            // a thing that failed to load rather than a day that hasn't run.
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Today, so far")
                VStack(alignment: .leading, spacing: 0) {
                    Ribbon(segments: [RibbonSegment(id: 0, weight: 1, fill: .gap)])
                    RibbonAxis(ticks: LedgerShapes.ticks(.day))
                }
            }
            Rule()
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("When each place fills")
                fills("1 hour", "Breakdown and Timeline have a shape")
                fills("1 day", "Notes and Themes, from what you read")
                fills("1 week", "Radar has enough repetition to spot")
            }
        }
    }

    private func fills(_ when: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Figure(when.uppercased(), size: 11, color: Instrument.faint)
                .frame(width: 52, alignment: .leading)
            Text(what)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.body)
        }
    }
}

// MARK: - The register the beats are written in

/// Body copy. Takes a `LocalizedStringKey` rather than a `String` because
/// `Text` only parses the **markdown** through that initializer — which means
/// the caller has to pass a literal, not a concatenation.
struct Prose: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(Instrument.sans(14))
            .lineSpacing(5)
            .foregroundStyle(Instrument.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 470, alignment: .leading)
    }
}

/// The smaller print under a choice: what it means, in the register that says
/// it is a consequence rather than a caveat.
struct Aside: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Instrument.sans(11.5))
            .foregroundStyle(Instrument.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line of a list, marked by type rather than by a bullet glyph: "·" for a
/// fact, "×" in `alert` for a thing that never happens.
struct Bullet: View {
    let line: String
    var mark: String = "·"
    var color: Color = Instrument.ghost

    init(_ line: String, mark: String = "·", color: Color = Instrument.ghost) {
        self.line = line
        self.mark = mark
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Figure(mark, size: 12, weight: .medium, color: color)
            Text(line)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
