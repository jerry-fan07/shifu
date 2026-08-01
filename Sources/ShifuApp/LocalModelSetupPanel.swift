import ShifuCore
import SwiftUI

/// The Qwen edition's model setup, everywhere it shows: the onboarding
/// backend beat and the Settings → Analysis recovery row both render this
/// over the one `ModelFetcher`, so a fetch started on either surface is the
/// same fetch on the other. One panel per state: the promise before, the
/// meter during, the specific unmet requirement when setup may not start,
/// and the retry when the network let it down.
struct LocalModelSetupPanel: View {
    @ObservedObject private var fetcher = ModelFetcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch fetcher.phase {
            case .idle:
                offer
            case .blocked(let reason):
                verdict(reason, color: Instrument.alert)
            case .downloading(let fraction):
                progress(fraction)
            case .verifying:
                Figure("verifying the download…", size: 11.5, color: Instrument.muted)
            case .installed(let tier):
                installed(tier)
            case .failed(let reason):
                verdict(reason, color: Instrument.alert)
                OutlineButton(title: "Try again", tinted: true) { fetcher.start() }
                    .fixedSize()
            }
        }
        .padding(13)
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.edge, lineWidth: 1)
        }
    }

    /// Before anything starts: which model this Mac gets and what the fetch
    /// costs, or — if preflight already says no — the requirement itself,
    /// shown without a click spent to discover it.
    @ViewBuilder private var offer: some View {
        switch LocalModel.preflightHere() {
        case .failure(let reason):
            verdict(ModelFetcher.explain(reason), color: Instrument.alert)
        case .success(let tier):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(tier.displayName) — a one-time \(tier.displayBytes) download")
                        .font(Instrument.sans(13, .medium))
                        .foregroundStyle(Instrument.ink)
                    Figure("from Hugging Face, straight to this Mac; "
                        + "analysis flips on by itself when it lands",
                        size: 10.5, color: Instrument.muted)
                }
                Spacer(minLength: 0)
                SolidButton(title: "Download") { fetcher.start() }
            }
        }
    }

    private func progress(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Figure(
                    "downloading \(fetcher.tier?.displayName ?? "model") · "
                        + "\(Int(fraction * 100))%",
                    size: 11.5, color: Instrument.body)
                Spacer(minLength: 0)
                InlineLink("Cancel", size: 11.5) { fetcher.cancel() }
            }
            Meter(share: fraction)
        }
    }

    private func installed(_ tier: LocalModel.Tier) -> some View {
        HStack(spacing: 8) {
            Figure("✓", size: 12, weight: .medium, color: Instrument.accentText)
            Text("\(tier.displayName) installed — analysis runs on this Mac")
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.body)
        }
    }

    private func verdict(_ reason: String, color: Color) -> some View {
        Text(reason)
            .font(Instrument.sans(12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
