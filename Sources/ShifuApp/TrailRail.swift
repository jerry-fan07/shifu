import SwiftUI

/// The navigation, with the sidebar taken away (design.md §7): the places hang
/// in the sky as stations on a switchback path, lowest at the bottom, in the
/// order you climb them. There is no panel behind them — only a wash of the
/// hour's own sky colour, so the trail reads as part of the world rather than
/// as chrome laid over it.
///
/// Picking a station flies the camera there; the rail is the map of a place you
/// are already standing in.
struct TrailRail: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selection: Destination
    let palette: SkyPalette

    nonisolated static let width: CGFloat = 186
    /// Enough room under the traffic lights for the mark.
    private static let headerHeight: CGFloat = 86
    private static let footerHeight: CGFloat = 96
    private static let discSize: CGFloat = 30
    private static let nodeWidth: CGFloat = 150

    private var places: [Destination] { Destination.allCases.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            mark
            GeometryReader { proxy in
                let stops = stations(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    path(through: stops)
                    ForEach(Array(places.enumerated()), id: \.element) { index, place in
                        node(place, at: stops[index])
                    }
                }
            }
            RailFooter(palette: palette)
                .frame(height: Self.footerHeight)
        }
        .frame(width: Self.width)
        .background(alignment: .leading) { scrim }
    }

    /// The stations are the only thing on this side of the window, so instead
    /// of a filled sidebar the left edge just gets more of its own sky. The
    /// wash is the palette's top sky colour, which is the one every palette
    /// already guarantees its ink reads against.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: palette.skyColors[0].opacity(0.72), location: 0),
                .init(color: palette.skyColors[0].opacity(0.44), location: 0.5),
                .init(color: palette.skyColors[0].opacity(0), location: 1)
            ],
            startPoint: .leading, endPoint: .trailing)
            .frame(width: Self.width + 120)
            .allowsHitTesting(false)
    }

    /// Evenly spaced up the column, nudged side to side so the line between
    /// them reads as a trail switching back rather than a ruler.
    private func stations(in size: CGSize) -> [CGPoint] {
        let inset: CGFloat = 18
        let step = (size.height - inset * 2) / CGFloat(places.count)
        return places.indices.map { index in
            CGPoint(
                x: 42 + 9 * sin(CGFloat(index) * 0.95),
                y: inset + step * (CGFloat(index) + 0.5))
        }
    }

    private func path(through stops: [CGPoint]) -> some View {
        Canvas { context, _ in
            guard stops.count > 1 else { return }
            var trail = Path()
            trail.move(to: stops[0])
            for index in 1..<stops.count {
                let previous = stops[index - 1]
                let next = stops[index]
                trail.addQuadCurve(
                    to: next,
                    control: CGPoint(x: next.x, y: (previous.y + next.y) / 2))
            }
            context.stroke(
                trail, with: .color(palette.textColor.opacity(0.45)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2.5, 5]))
        }
        .allowsHitTesting(false)
    }

    private func node(_ place: Destination, at stop: CGPoint) -> some View {
        TrailStation(
            place: place, badge: badge(place), palette: palette,
            isSelected: selection == place,
            discSize: Self.discSize, width: Self.nodeWidth
        ) {
            guard selection != place else { return }
            selection = place
        }
        .position(x: stop.x + Self.nodeWidth / 2 - Self.discSize / 2, y: stop.y)
    }

    /// What deserves a number: cards waiting to be reviewed, automations
    /// waiting to be judged. Everything else earns attention by being visited.
    private func badge(_ place: Destination) -> Int? {
        switch place {
        case .practice: return store.dueNotes.count + store.inboxNotes.count
        case .radar: return store.suggestions.count
        default: return nil
        }
    }

    private var mark: some View {
        HStack(spacing: 9) {
            SenseiFigure(size: 30, mood: store.isPaused ? .resting : .serene)
            Text("SHIFU")
                .font(Dojo.label(12, .bold))
                .tracking(3)
                .foregroundStyle(palette.textColor)
            Spacer(minLength: 0)
        }
        .padding(.leading, 27)
        .frame(height: Self.headerHeight, alignment: .bottom)
    }
}

/// One station: a stone disc on the path, its name beside it, and a count when
/// the place is holding something for you. The disc fills with terracotta where
/// you are standing — the same headband the mentor wears.
private struct TrailStation: View {
    let place: Destination
    let badge: Int?
    let palette: SkyPalette
    let isSelected: Bool
    let discSize: CGFloat
    let width: CGFloat
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                disc
                // The region is left to the page header and the world's own
                // signs — the trail is a list of places, not a taxonomy.
                Text(place.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected ? palette.textColor : palette.secondaryTextColor)
                    .shadow(color: shadowColor, radius: 3)
                Spacer(minLength: 0)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(Dojo.label(10, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Dojo.accent, in: Capsule())
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(place.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Light text needs a dark halo and dark text a light one — the rail sits
    /// over whatever the ridge behind it happens to be.
    private var shadowColor: Color {
        (palette.onDark ? Color.black : Color.white).opacity(0.5)
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Dojo.accent : palette.skyColors[0].opacity(0.55))
                .background(isSelected ? nil : Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
            Circle()
                .strokeBorder(
                    isSelected ? Color.white.opacity(0.35) : palette.textColor.opacity(0.28),
                    lineWidth: 1)
            Image(systemName: place.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : palette.textColor.opacity(0.8))
        }
        .frame(width: discSize, height: discSize)
        .scaleEffect(isSelected ? 1.16 : (hovering ? 1.08 : 1))
        .shadow(color: Dojo.accent.opacity(isSelected ? 0.55 : 0), radius: 9)
        .shadow(color: .black.opacity(0.22), radius: 4, y: 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The daemon's whole control surface (§6) at the foot of the trail: capture
/// state, rest, Work Mode, Settings. Glyphs over the sky, not a panel.
private struct RailFooter: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.openSettings) private var openSettings
    let palette: SkyPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.isPaused ? palette.textColor.opacity(0.5) : Dojo.jade)
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: store.isPaused ? .clear : Dojo.jade.opacity(0.9), radius: 5)
                Eyebrow(
                    store.isPaused ? "asleep" : "watching",
                    color: store.isPaused ? palette.secondaryTextColor : Dojo.jade)
                Spacer(minLength: 0)
            }
            if let until = store.pausedUntil {
                Text("until \(until, format: .dateTime.hour().minute())")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryTextColor)
            }
            Toggle(isOn: workModeBinding) {
                Text("Work Mode")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryTextColor)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Glow when you wander off the work path")
            HStack(spacing: 12) {
                pauseMenu
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .font(.system(size: 14))
            .foregroundStyle(palette.textColor.opacity(0.75))
        }
        .padding(.leading, 27)
        .padding(.trailing, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var pauseMenu: some View {
        Menu {
            if store.isPaused {
                Button("Wake Shifu") { store.resume() }
            } else {
                Button("Rest 1 hour") {
                    store.pause(until: Date().addingTimeInterval(3_600))
                }
                Button("Rest until tomorrow") {
                    store.pause(until: Calendar.current.startOfDay(
                        for: Date().addingTimeInterval(86_400)))
                }
            }
        } label: {
            Image(systemName: store.isPaused ? "play.circle" : "pause.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.isPaused ? "Wake Shifu" : "Let Shifu rest")
    }

    private var workModeBinding: Binding<Bool> {
        Binding(get: { store.workModeOn }, set: { _ in store.toggleWorkMode() })
    }
}
