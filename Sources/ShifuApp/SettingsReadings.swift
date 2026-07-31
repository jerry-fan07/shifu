import ShifuCore
import SwiftUI

/// The Settings page's right-hand column: what the machine is doing, beside
/// the dials that tell it to.
///
/// This is the half of the redesign a settings screen normally has no answer
/// for. You can set a heartbeat of 60 seconds and have no idea whether
/// anything is being captured at all; you can opt into an LLM backend and have
/// no idea what has left the machine since. Every figure here is measured from
/// the same database the daemon writes (`SettingsDiagnostics`) — nothing on
/// this column restates a setting back at you.
///
/// What it deliberately does *not* show is the daemon's TCC grants. `shifud`
/// is a separate binary with its own identity, and this process cannot read
/// its Accessibility or Screen Recording state — only its own. A green tick
/// for a permission we cannot see would be the one lie on a page whose whole
/// job is to be believed; the capture counts below are the honest proxy, and
/// they say more anyway.
struct SettingsReadings: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var ledger: LedgerStore

    static let width: CGFloat = 216

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            capture
            wire
            if let diagnostics = store.diagnostics {
                ReadingBlock("Storage") {
                    ReadingLine("database", value: diagnostics.databaseSizeLabel)
                    if diagnostics.databaseEncrypted {
                        ReadingLine("at rest", value: "encrypted")
                    }
                }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Instrument.rail.opacity(0.55))
        .task {
            // The dials are stable; these are not. Reloading them alone —
            // never `load()` — keeps a half-typed API key on screen.
            while !Task.isCancelled {
                store.loadDiagnostics()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Today's captures, split the way the ladder produced them (§3.2). The
    /// split is the diagnostic: `text` falling to zero while `metadata` climbs
    /// is the Accessibility grant gone, which no amount of settings would say.
    private var capture: some View {
        ReadingBlock("Capture") {
            HStack(spacing: 7) {
                StatusDot(color: ledger.isPaused ? Instrument.alert : Instrument.live)
                Text(ledger.isPaused ? "Resting" : "Watching")
                    .font(Instrument.sans(12.5, .medium))
                    .foregroundStyle(Instrument.ink)
            }
            .padding(.bottom, 4)
            if let diagnostics = store.diagnostics {
                ReadingLine("text", value: "\(diagnostics.text)")
                ReadingLine("ocr fallback", value: "\(diagnostics.ocr)")
                ReadingLine("metadata only", value: "\(diagnostics.metadata)")
                ReadingLine("excluded", value: "\(diagnostics.excluded)")
                ReadingLine("today", value: "\(diagnostics.captureTotal)", strong: true)
            }
            if let through = ledger.ledgerThrough {
                Text("Ledger to " + through.formatted(.dateTime.hour().minute()))
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                    .padding(.top, 5)
            }
        }
    }

    /// What left this Mac today. The blank state is the important one: on a
    /// rules-only install this reads "Nothing today", every day, forever, and
    /// that sentence is the product's central claim rendered as a measurement
    /// rather than as copy.
    private var wire: some View {
        ReadingBlock("What left this Mac") {
            if let diagnostics = store.diagnostics, diagnostics.llmCalls > 0 {
                ReadingLine("calls", value: "\(diagnostics.llmCalls)")
                ReadingLine("tokens", value: diagnostics.llmTokensLabel)
                if let cost = diagnostics.llmCostLabel {
                    ReadingLine("spend", value: cost, strong: true)
                }
                Text("Redacted text samples, after exclusions. No pixels, no raw captures.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            } else {
                Text("Nothing today.")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.body)
            }
        }
    }

    /// The two things you come to a settings page to *do* rather than set.
    /// Pause lives here, not in the Capture section, because it is a state you
    /// put the instrument into for an hour — not a preference.
    private var actions: some View {
        VStack(spacing: 6) {
            WideButton(title: "Analyze now") { ledger.runAnalysis() }
            if ledger.isPaused {
                WideButton(title: "Resume capture") { ledger.resume() }
            } else {
                WideButton(title: "Pause 1 hour") {
                    ledger.pause(until: Date().addingTimeInterval(3_600))
                }
            }
            Text(ledger.captureLine)
                .font(Instrument.sans(11))
                .foregroundStyle(Instrument.ghost)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
        }
    }
}

/// A titled group of readings, over a rule. The column's only structure —
/// hairlines and an eyebrow, the same as every table in the app.
private struct ReadingBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(title, tracking: 1.2)
                .padding(.bottom, 7)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One reading: what it counts on the left, the figure on the right.
private struct ReadingLine: View {
    let label: String
    let value: String
    var strong = false

    init(_ label: String, value: String, strong: Bool = false) {
        self.label = label
        self.value = value
        self.strong = strong
    }

    var body: some View {
        HStack(spacing: 8) {
            Figure(label, size: 11, color: Instrument.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Figure(
                value, size: 11, weight: strong ? .medium : .regular,
                color: strong ? Instrument.ink : Instrument.secondary)
        }
        .padding(.vertical, 2.5)
    }
}

/// An outlined button that fills its column. `OutlineButton` sizes to its
/// title, which in a 216-point column leaves a ragged stack of three different
/// widths where the design calls for one edge.
private struct WideButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Instrument.sans(12))
                .foregroundStyle(Instrument.railInk)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
