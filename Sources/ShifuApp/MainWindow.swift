import ShifuCore
import SwiftUI

/// The main window (design.md §7): a full desktop app — the trail on the left,
/// one place on the right — wrapped in the Dojo look. Shows onboarding instead
/// until the first-run flow completes.
struct MainWindow: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var destination: Destination = .today

    var body: some View {
        if onboarded {
            NavigationSplitView {
                SidebarView(selection: $destination)
                    .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 290)
            } detail: {
                destination.page
            }
            .frame(minWidth: 940, minHeight: 620)
            .tint(Dojo.accent)
        } else {
            OnboardingView()
                .tint(Dojo.accent)
        }
    }
}

/// The places the trail can take you. Grouped the way the mentor thinks about
/// them: the path (where time goes), the mind (what it taught you), the watch
/// (what could be handed to a machine).
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
    /// heading the sidebar groups it under.
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

/// One NavigationStack with the routes every page may push — task pages,
/// theme pages, the suggestion queue — and the paper ground behind all of it.
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
        .background(Dojo.paper)
    }
}

/// The sidebar: Shifu's mark up top, the places strung along a dashed trail,
/// the daemon's controls, and the mountain he lives on holding up the bottom.
///
/// Rows are hand-drawn rather than a `List(selection:)` so the selected row
/// wears the accent — the system sidebar paints selection in the user's OS
/// accent color, which fights the warm palette everywhere it isn't orange.
struct SidebarView: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selection: Destination

    /// Where the station discs are centred, and so where the trail runs.
    private static let trailX: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(.today)
                    ForEach(Destination.groups, id: \.name) { group in
                        sectionLabel(group.name)
                        ForEach(group.places) { place in
                            row(place)
                        }
                    }
                }
                // Behind, not in front: the trail is drawn to the rows' own
                // height, so it starts and stops at the first and last station.
                .background(alignment: .top) { trail }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            StatusFooter()
            footerScene
        }
        .background(Dojo.sidebar)
    }

    /// The dashed line the stations sit on. Drawn behind the rows and inset at
    /// both ends so it reads as a route, not a rule.
    private var trail: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: Self.trailX, y: 14))
                path.addLine(to: CGPoint(x: Self.trailX, y: proxy.size.height - 14))
            }
            .stroke(
                Dojo.accent.opacity(0.24),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
        }
        .allowsHitTesting(false)
    }

    private var footerScene: some View {
        MountainScene(detail: .compact)
            .frame(height: 76)
            .mask(
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.7)))
            .allowsHitTesting(false)
    }

    private func sectionLabel(_ title: String) -> some View {
        Eyebrow(title)
            .padding(.leading, 42)
            .padding(.top, 16)
            .padding(.bottom, 5)
    }

    private func row(_ destination: Destination) -> some View {
        SidebarRow(
            destination: destination,
            badge: badge(destination),
            trailX: Self.trailX,
            selection: $selection)
    }

    /// What deserves a number: cards waiting to be reviewed, automations
    /// waiting to be judged. Everything else earns attention by being visited.
    private func badge(_ destination: Destination) -> Int? {
        switch destination {
        case .practice: return store.dueNotes.count + store.inboxNotes.count
        case .radar: return store.suggestions.count
        default: return nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SenseiFigure(size: 40, mood: store.isPaused ? .resting : .serene)
            VStack(alignment: .leading, spacing: 1) {
                Text("SHIFU")
                    .font(Dojo.label(14, .bold))
                    .tracking(3)
                Text("your time, mentored")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

extension Destination {
    /// The sidebar's groups, in trail order, with Today pulled out as its own
    /// ungrouped first stop.
    static var groups: [(name: String, places: [Destination])] {
        [("The path", [.time, .themes, .tasks]),
         ("The mind", [.practice, .scrolls]),
         ("The watch", [.radar])]
    }
}

/// One station on the trail: a disc on the dashed line, the title, and an
/// optional count. The current place fills its disc with terracotta.
private struct SidebarRow: View {
    let destination: Destination
    let badge: Int?
    let trailX: CGFloat
    @Binding var selection: Destination
    @State private var hovering = false

    private var isSelected: Bool { selection == destination }

    var body: some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                station
                Text(destination.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(Dojo.label(10, .bold))
                        .foregroundStyle(Dojo.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Dojo.accentSoft, in: Capsule())
                }
            }
            .padding(.leading, trailX - 24)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && !isSelected ? Color.primary.opacity(0.05) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var station: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Dojo.accent : Dojo.sidebar)
                .frame(width: 26, height: 26)
            Circle()
                .strokeBorder(
                    isSelected ? Color.clear : Dojo.hairline, lineWidth: 1)
                .frame(width: 26, height: 26)
            Image(systemName: destination.symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : .secondary)
        }
        .frame(width: 48, alignment: .center)
    }
}

/// Capture state, pause controls, Work Mode, and the door to Settings —
/// the daemon's whole control surface (§6), pinned under the trail.
private struct StatusFooter: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.isPaused ? Color.secondary : Dojo.jade)
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: store.isPaused ? .clear : Dojo.jade.opacity(0.8),
                        radius: 4)
                Eyebrow(
                    store.isPaused ? "asleep" : "watching",
                    color: store.isPaused ? .secondary : Dojo.jade)
                Spacer()
                pauseMenu
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            if let until = store.pausedUntil {
                Text("until \(until, format: .dateTime.hour().minute())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: workModeBinding) {
                Text("Work Mode")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Glow when you wander off the work path")
        }
        .padding(11)
        .dojoCard(padding: 0)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
