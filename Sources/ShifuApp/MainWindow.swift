import ShifuCore
import SwiftUI

/// The main window (design.md §7): the mountain, edge to edge, with the trail
/// hanging in the sky on the left and the current place's scroll unfurled on
/// the right. Changing places does not swap a screen — it flies the camera up
/// or down the mountain to another terrace, and the panel rolls up while it
/// travels so you can see where you are going. Shows onboarding instead until
/// the first-run flow completes.
struct MainWindow: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var destination: Destination = .today
    @State private var camera = WorldMap.camera(for: .today)
    /// The leg being walked, so the world can tell travelling from arrived.
    @State private var leg = Leg(from: .zero, to: .zero)
    @State private var travelling = false
    @State private var hop: CGFloat = 0
    @State private var arrival: Task<Void, Never>?
    @EnvironmentObject private var store: LedgerStore

    private struct Leg {
        var from: CGPoint
        var to: CGPoint
    }

    /// How long the camera takes to cross from one terrace to the next. Long
    /// enough to read as a climb, short enough that it never feels like a wait.
    private static let flightDuration = 0.82

    var body: some View {
        if onboarded {
            world.tint(Dojo.accent)
        } else {
            OnboardingView().tint(Dojo.accent)
        }
    }

    private var sky: SkyTime { SkyTime.current() }

    private var world: some View {
        GeometryReader { proxy in
            let layout = Layout(size: proxy.size, destination: destination)
            ZStack(alignment: .topLeading) {
                WorldStage(
                    camera: camera, anchor: layout.anchor, sky: sky,
                    mood: store.isPaused ? .resting : .watching,
                    origin: leg.from, arrival: leg.to, hop: hop)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { jump() }
                if destination == .today { SkyGreeting(palette: sky.palette) }
                TrailRail(selection: $destination, palette: sky.palette)
                panel(layout)
            }
        }
        .frame(minWidth: 1_020, minHeight: 660)
        .onChange(of: destination) { _, place in fly(to: place) }
    }

    // MARK: - Travelling

    private func fly(to place: Destination) {
        let next = WorldMap.camera(for: place)
        leg = Leg(from: camera.target, to: next.target)
        arrival?.cancel()
        withAnimation(.easeIn(duration: 0.14)) { travelling = true }
        withAnimation(.timingCurve(0.5, 0, 0.12, 1, duration: Self.flightDuration)) {
            camera = next
        }
        arrival = Task {
            try? await Task.sleep(for: .seconds(Self.flightDuration * 0.82))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { travelling = false }
        }
    }

    /// A click on the mountain and he hops. Nothing depends on it — it is
    /// there because a place you can poke is a place you believe in.
    private func jump() {
        // Up, then down — two transactions, because both assignments in one
        // pass would land on the value he started at and animate nothing.
        guard hop == 0 else { return }
        withAnimation(.easeOut(duration: 0.16)) { hop = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeIn(duration: 0.2)) { hop = 0 }
        }
    }

    // MARK: - Layers over the world

    private func panel(_ layout: Layout) -> some View {
        destination.page
            .frame(width: layout.panelWidth, height: layout.size.height - Layout.inset * 2)
            .dojoPanel()
            .offset(x: layout.panelX, y: Layout.inset)
            .opacity(travelling ? 0 : 1)
            .scaleEffect(travelling ? 0.97 : 1, anchor: .trailing)
            .allowsHitTesting(!travelling)
    }

    /// Where the panel sits, and therefore where the terrace has to land: the
    /// camera aims at the middle of the gap the panel leaves, so the temple you
    /// travelled to is never the thing the scroll is covering.
    private struct Layout {
        static let inset: CGFloat = 16
        let size: CGSize
        let destination: Destination

        /// Today is mostly picture, so its scroll is narrower.
        var panelWidth: CGFloat {
            let isToday = destination == .today
            return min(
                isToday ? 520 : 780,
                max(isToday ? 380 : 520, size.width * (isToday ? 0.40 : 0.58)))
        }

        var panelX: CGFloat { size.width - Self.inset - panelWidth }

        var anchor: UnitPoint {
            let gap = (TrailRail.width + panelX) / 2
            return UnitPoint(x: max(0.16, gap / max(1, size.width)), y: 0.6)
        }
    }
}

/// Words laid straight on the painting need a halo the opposite way round from
/// the sky they sit on, or dusk eats them.
func haloColor(_ palette: SkyPalette) -> Color {
    palette.onDark ? Color.black : Color.white
}

/// The salutation and the day's line, laid on the open sky above the camp.
/// Only Today gets words on the painting; every other place says its piece
/// inside its own scroll.
private struct SkyGreeting: View {
    let palette: SkyPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                .uppercased())
                .font(Dojo.label())
                .tracking(1.6)
                .foregroundStyle(palette.secondaryTextColor)
            Text(greeting)
                .font(Dojo.display(34))
                .foregroundStyle(palette.textColor)
            Text("“\(Wisdom.daily())”")
                .font(Dojo.voice(size: 14.5))
                .foregroundStyle(palette.secondaryTextColor)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .shadow(color: haloColor(palette).opacity(0.45), radius: 6)
        .padding(.leading, TrailRail.width + 16)
        .padding(.top, 44)
        .allowsHitTesting(false)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default: return "The late hours."
        }
    }
}

/// The places the trail can take you, in the order you climb them. Grouped the
/// way the mentor thinks about them: the path (where time goes), the mind (what
/// it taught you), the watch (what could be handed to a machine).
enum Destination: String, CaseIterable, Identifiable {
    case today, time, themes, tasks, practice, scrolls, radar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .time: return "Time"
        case .themes: return "Themes"
        case .tasks: return "Task log"
        case .practice: return "Practice"
        case .scrolls: return "Scrolls"
        case .radar: return "Radar"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "mountain.2.fill"
        case .time: return "hourglass"
        case .themes: return "square.stack.3d.up.fill"
        case .tasks: return "checklist"
        case .practice: return "rectangle.stack.fill"
        case .scrolls: return "scroll.fill"
        case .radar: return "dot.radiowaves.left.and.right"
        }
    }

    /// The band this place belongs to — the eyebrow every page wears, and the
    /// name of the stretch of mountain it stands on.
    var region: String {
        switch self {
        case .today: return "Basecamp"
        case .time, .themes, .tasks: return "The path"
        case .practice, .scrolls: return "The mind"
        case .radar: return "The watch"
        }
    }

    /// One line on what the place is for, under its title.
    var blurb: String {
        switch self {
        case .today: return "How the day is going."
        case .time: return "Where the hours went, and when."
        case .themes: return "The few long arcs your work belongs to."
        case .tasks: return "Every task the ledger has named."
        case .practice: return "What you learned, brought back before it fades."
        case .scrolls: return "The vault, searched."
        case .radar: return "Work a machine could be doing instead."
        }
    }

    /// The page, inside its own stack so task/theme pages push in place.
    @MainActor @ViewBuilder var page: some View {
        switch self {
        case .today: DetailStack { TodayView() }
        case .time: DetailStack { TimeView() }
        case .themes: DetailStack { ThemeListView() }
        case .tasks: DetailStack { TaskLogView() }
        case .practice: DetailStack { PracticeView() }
        case .scrolls: DetailStack { ScrollsView() }
        case .radar: DetailStack { RadarView() }
        }
    }
}

/// One NavigationStack with the routes every page may push — task pages, theme
/// pages, the suggestion queue. No ground of its own: the scroll it sits in
/// supplies that, and the mountain shows through it.
struct DetailStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: Int64.self) { taskID in
                    TaskDetailView(taskID: taskID)
                }
                .navigationDestination(for: ThemeRoute.self) { route in
                    ThemeDetailView(themeID: route.id)
                }
                .navigationDestination(for: SuggestionsRoute.self) { _ in
                    MergeReviewView()
                }
        }
        .scrollContentBackground(.hidden)
    }
}
