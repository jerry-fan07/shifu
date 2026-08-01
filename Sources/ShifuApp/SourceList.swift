import ShifuCore
import SwiftUI

// MARK: - The source list

/// The permanent left column. What it lists depends on where you are: the
/// places while you are in one, and the open thing's own contents while you
/// are inside a task or a theme — so the window never stops saying where you
/// are, and the way back is where the way in was.
struct SourceList: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        Group {
            switch router.route {
            case .none: Places()
            case .task(let taskID): TaskContents(taskID: taskID)
            case .theme(let themeID): ThemeContents(themeID: themeID)
            case .deck(let deckID): DeckContents(deckID: deckID)
            case .newDeck: NewDeckContents()
            case .looseCards: LooseContents()
            case .merges: MergeContents()
            case .note(let noteID): NoteContents(noteID: noteID)
            }
        }
        .frame(width: Instrument.railWidth)
        .background(Instrument.rail)
    }
}

/// The default contents: the places, each with the count that says whether
/// going there is worth it. Not a `RailColumn`: this is the one rail with a
/// foot — Focus Mode and the door to Settings, pinned under the places and
/// above the capture line (design.md §7).
private struct Places: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shifu")
                        .font(Instrument.sans(14, .semibold))
                        .tracking(-0.14)
                        .foregroundStyle(Instrument.ink)
                    Figure(
                        store.todayMs > 0
                            ? store.todayTotalLabel + " today"
                            : "nothing yet today",
                        size: 10.5, color: Instrument.faint)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)

                ForEach(Region.allCases) { region in
                    VStack(alignment: .leading, spacing: 0) {
                        RailHeading(region.rawValue)
                        ForEach(region.places) { place in
                            RailRow(
                                title: place.title,
                                badge: place.badge(store),
                                urgent: place == .due,
                                selected: router.place == place
                            ) {
                                router.go(to: place)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 12)

            FocusModeRailRow()
            RailRow(
                title: "Settings",
                selected: router.place == .settings
            ) {
                router.go(to: .settings)
            }

            VStack(alignment: .leading, spacing: 3) {
                Rule(weight: .section)
                    .padding(.bottom, 7)
                // Capture state and how far the ledger reaches — the two
                // things that explain a screen emptier than the day felt.
                Text(store.captureLine)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.railInk)
                if let through = store.ledgerThrough {
                    Figure(
                        "ledger to " + through.formatted(.dateTime.hour().minute()),
                        size: 10.5, color: Instrument.ghost)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Focus Mode at the rail's foot — the one switch the window carries. The whole
/// row is the target, like the menu bar's line; the switch is the state, and
/// the line under it is the clock (`FocusTimerLine`).
private struct FocusModeRailRow: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        Button {
            store.toggleFocusMode()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Focus Mode")
                        .font(Instrument.sans(13))
                        .foregroundStyle(Instrument.railInk)
                    Spacer(minLength: 0)
                    ToggleSwitch(isOn: store.focusModeOn) { store.toggleFocusMode() }
                }
                FocusTimerLine()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Focus Mode")
    }
}

/// The suggestion queue's contents: nothing but the way back.
private struct MergeContents: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        RailColumn {
            RailBack(title: "Tasks") { router.go(to: .tasks) }
        } footer: {
            Text("Dismissed pairs are never re-suggested.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The shape every source list takes: contents at the top, a footer pinned to
/// the bottom over a rule.
struct RailColumn<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 3) {
                Rule(weight: .section)
                    .padding(.bottom, 7)
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One row of the source list: a name, and the number that says how much is
/// behind it. The count is the whole point of a permanent list — it means you
/// can decide whether to go there without going there.
struct RailRow: View {
    let title: String
    var badge: String?
    var urgent = false
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Instrument.sans(13, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Instrument.ink : Instrument.railInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge, !badge.isEmpty {
                    Figure(badge, size: 11, weight: urgent ? .medium : .regular, color: badgeColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(
                selected ? Instrument.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var badgeColor: Color {
        if urgent { return Instrument.alert }
        return selected ? Instrument.accentText : Instrument.faint
    }
}

/// The way back out of a task or a theme.
struct RailBack: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("← \(title)")
                .font(Instrument.sans(12.5))
                .foregroundStyle(Instrument.accentText)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A heading inside the source list.
struct RailHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Eyebrow(text, tracking: 1.2)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)
    }
}
