import ShifuCore
import SwiftUI

/// The main window (design.md §7): a full desktop app — sidebar of places on
/// the left, one page on the right — wrapped in the Dojo look. Shows
/// onboarding instead until the first-run flow completes.
struct MainWindow: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var destination: Destination = .today

    var body: some View {
        if onboarded {
            NavigationSplitView {
                SidebarView(selection: $destination)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
            } detail: {
                destination.page
            }
            .frame(minWidth: 900, minHeight: 600)
            .tint(Dojo.accent)
        } else {
            OnboardingView()
                .tint(Dojo.accent)
        }
    }
}

/// The places the sidebar can take you. Grouped the way the mentor thinks
/// about them: the path (where time goes), the mind (what it taught you),
/// the watch (what could be automated away).
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
        case .today: return "sun.horizon"
        case .time: return "hourglass"
        case .themes: return "square.stack.3d.up"
        case .tasks: return "checklist"
        case .practice: return "rectangle.stack"
        case .scrolls: return "scroll"
        case .radar: return "dot.radiowaves.left.and.right"
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

/// The sidebar: the sensei's mark up top, the places, and a status card that
/// keeps capture state and Work Mode one glance away. Rows are hand-drawn
/// rather than a `List(selection:)` so the selected row wears the accent —
/// the system sidebar paints selection in the user's OS accent color, which
/// fights the warm palette everywhere it isn't orange.
struct SidebarView: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selection: Destination

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.today)
                    sectionLabel("Path")
                    row(.time)
                    row(.themes)
                    row(.tasks)
                    sectionLabel("Mind")
                    row(.practice)
                    row(.scrolls)
                    sectionLabel("Watch")
                    row(.radar)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            StatusFooter()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }

    private func row(_ destination: Destination) -> some View {
        SidebarRow(
            destination: destination,
            badge: badge(destination),
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
        HStack(spacing: 9) {
            SenseiFigure(size: 30, mood: store.isPaused ? .resting : .serene)
            VStack(alignment: .leading, spacing: 0) {
                Text("Shifu")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("your time, mentored")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// One place in the sidebar: icon, title, optional count, and the terracotta
/// wash when it is the current page.
private struct SidebarRow: View {
    let destination: Destination
    let badge: Int?
    @Binding var selection: Destination
    @State private var hovering = false

    private var isSelected: Bool { selection == destination }

    var body: some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 8) {
                Image(systemName: destination.symbol)
                    .frame(width: 19)
                    .foregroundStyle(isSelected ? Dojo.accentText : Color.secondary)
                Text(destination.title)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Dojo.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Dojo.accentSoft, in: Capsule())
                }
            }
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                        ? AnyShapeStyle(Dojo.accentSoft)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : Color.clear)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Capture state, pause controls, Work Mode, and the door to Settings —
/// the daemon's whole control surface (§6), pinned under the sidebar.
private struct StatusFooter: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isPaused ? Color.secondary : Dojo.jade)
                    .frame(width: 7, height: 7)
                Text(store.isPaused ? "Resting" : "Watching")
                    .font(.caption.weight(.medium))
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
        .padding(10)
        .dojoCard(padding: 0)
        .padding(10)
    }

    private var pauseMenu: some View {
        Menu {
            if store.isPaused {
                Button("Resume capture") { store.resume() }
            } else {
                Button("Pause 1 hour") {
                    store.pause(until: Date().addingTimeInterval(3_600))
                }
                Button("Pause until tomorrow") {
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
        .help(store.isPaused ? "Resume capture" : "Pause capture")
    }

    private var workModeBinding: Binding<Bool> {
        Binding(get: { store.workModeOn }, set: { _ in store.toggleWorkMode() })
    }
}
