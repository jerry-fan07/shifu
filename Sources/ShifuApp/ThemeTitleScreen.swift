import ShifuCore
import SwiftUI

/// The theme page's opening screen: the theme's name at the largest size on
/// the page, what it is, and its headline figures — then the one instruction
/// the page needs, which is that there is more below.
///
/// It is sized off the page rather than fixed, so the campaign's heading
/// always peeks under it: a page that ends exactly at the fold reads as a page
/// that ends, and everything this page is *for* is underneath. Scrolling it
/// out is the first thing the user does, so the screen goes with the scroll —
/// the banner leaves at scroll speed while its type lags behind and fades,
/// which is what makes the two read as separate layers.
///
/// The ground is the rust the story panel is printed on, run full-bleed out
/// past the page's gutter: the one field of colour the app fills, and the
/// reason the fold is impossible to mistake for the end of the page.
struct ThemeTitleScreen: View {
    let detail: ThemeStore.Detail
    /// From the list's overview, not the detail's: the detail query doesn't
    /// fill `weekMs` in, and a theme page that silently drops the week is the
    /// one figure you came for.
    let weekMs: Int64
    let pageHeight: CGFloat
    /// What the cue promises is under the fold — the campaign when the theme
    /// has one, and the record it does have when it doesn't.
    let cue: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tall enough to read as a screen of its own, short enough to leave the
    /// campaign showing — and capped, because the shot harness films at window
    /// heights no display has (`SHIFU_SHOT_HEIGHT`).
    private var height: CGFloat {
        min(max(pageHeight * 0.66, 320), 600)
    }

    var body: some View {
        GeometryReader { proxy in
            let scrolled = max(
                0, -proxy.frame(in: .named(CampaignHero.scrollSpace)).minY)
            let leaving = reduceMotion ? 0 : min(1, scrolled / max(height * 0.75, 1))
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 12)
                title
                Spacer(minLength: 12)
                ScrollCue(label: cue, spent: reduceMotion ? 0 : min(1, scrolled / 80))
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(1 - leaving)
            // Slower than the scroll that carries it: the type hangs back a
            // little on its way out, which is what makes it read as a layer
            // over the banner rather than as part of it.
            .offset(y: reduceMotion ? 0 : scrolled * 0.22)
        }
        .frame(height: height)
        // The banner itself doesn't fade — a half-transparent rust field over
        // the ground is a smear, not a layer — so the fill sits outside the
        // type's transition, and past the gutter the page body indents by.
        .background(alignment: .top) {
            Instrument.banner
                .padding(.horizontal, -Instrument.gutter)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Theme", color: .white.opacity(0.7))
            Text(detail.overview.name)
                .font(Instrument.sans(46, .semibold))
                .tracking(-1.15)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.top, 12)
            if let gist = detail.overview.gist, !gist.isEmpty {
                Text(gist)
                    .font(Instrument.sans(15))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 12)
            }
            figures
                .padding(.top, 20)
        }
    }

    /// The headline figures, in the banner's own register: white held back a
    /// step, because on a filled ground the palette's greys have nothing to be
    /// quiet against.
    private var figures: some View {
        let tint = Color.white.opacity(0.78)
        return HStack(spacing: 18) {
            Figure("\(TimeBreakdown.duration(detail.overview.totalMs)) total",
                   size: 12, color: tint)
            if weekMs > 0 {
                Figure("\(TimeBreakdown.duration(weekMs)) this week",
                       size: 12, color: tint)
            }
            Figure("\(detail.tasks.count) task\(detail.tasks.count == 1 ? "" : "s")",
                   size: 12, color: tint)
            Figure(
                "last active " + Date(
                    timeIntervalSince1970: Double(detail.overview.lastActiveAt) / 1_000)
                    .formatted(.relative(presentation: .numeric)),
                size: 12, color: tint)
        }
    }
}

/// The title screen's one instruction. It bobs, because a still arrow on a
/// still screen reads as decoration, and it dims away as `spent` rises — the
/// scroll it asks for is the only thing that answers it, and an instruction
/// that stays after it has been obeyed is noise.
private struct ScrollCue: View {
    let label: String
    let spent: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobbing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Instrument.sans(12))
                .foregroundStyle(.white.opacity(0.82))
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .offset(y: bobbing ? 2.5 : -1.5)
        }
        .opacity(1 - spent)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                bobbing = true
            }
        }
    }
}
