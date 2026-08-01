import AppKit
import ShifuCore
import SwiftUI

/// The Settings place (design.md §9), as three columns rather than one scroll:
/// a rail of sections, the section's dials, and — on a window with room for
/// it — a column of live readings on the right.
///
/// The rail is the change that matters. §7's minimalism rule says no settings
/// page longer than one screen, and a single scrolling list stopped honouring
/// that the moment the analyzer grew rates and model slots; you now hunted for
/// the heartbeat past nine LLM fields. One section per screen restores it, and
/// makes "where do I change X" a question the rail answers before you scroll.
///
/// The right-hand column answers the question a settings screen normally
/// leaves hanging — *is this actually working* — with measured numbers rather
/// than a restatement of the dials beside them (`SettingsDiagnostics`).
///
/// Still rendered *from* `SettingsCatalog`: adding a numeric setting to the
/// catalog makes it appear in its section, correctly bounded and labelled,
/// with no change to this file. The exceptions are the things that aren't
/// stored settings — Focus Mode's own switch, the exclusion table, and About's
/// facts about the disk — which each section adds under its catalog rows.
struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    /// Below this, the readings column costs the dials more room than it is
    /// worth and the help text under every label wraps to a paragraph. The
    /// window's own 960 minimum lands here, so the column is a reward for a
    /// larger window rather than something a small one has to live without.
    private static let panelMinWidth: CGFloat = 420

    var body: some View {
        GeometryReader { geometry in
            let showsReadings =
                geometry.size.width - SettingsRail.width - SettingsReadings.width
                    >= Self.panelMinWidth
            HStack(spacing: 0) {
                SettingsRail()
                VerticalRule()
                SettingsPanel(section: store.section)
                    .frame(maxWidth: .infinity)
                if showsReadings {
                    VerticalRule()
                    SettingsReadings()
                }
            }
        }
        .onAppear { store.load() }
    }
}

/// The column separator. `Rule` is a horizontal hairline; between columns the
/// same edge has to stand on end.
struct VerticalRule: View {
    var body: some View {
        Rectangle()
            .fill(Instrument.edge)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - The section rail

/// Which part of the instrument you are adjusting. A second rail inside the
/// page rather than a nesting of the source list: the source list says which
/// *place* you are in, and Settings is one place — the same relationship a
/// task's contents have with it.
private struct SettingsRail: View {
    @EnvironmentObject private var store: SettingsStore

    static let width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Settings", tracking: 1.2)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            ForEach(SettingsSection.allCases, id: \.self) { section in
                SettingsRailRow(section: section, selected: store.section == section)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 0) {
                Rule(weight: .section)
                    .padding(.bottom, 8)
                // The promise that governs the section you are in — the one
                // thing a settings screen has to say and normally buries in a
                // release note.
                Text(store.section.promise)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 14)
        .frame(width: SettingsRail.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Instrument.rail.opacity(0.55))
    }
}

/// One rail row. Filled rather than tinted when selected: this rail sits
/// beside the source list, whose selection is a tint, and two tints one column
/// apart read as two selections in the same list.
private struct SettingsRailRow: View {
    @EnvironmentObject private var store: SettingsStore
    let section: SettingsSection
    let selected: Bool

    var body: some View {
        Button {
            store.section = section
        } label: {
            Text(section.rawValue)
                .font(Instrument.sans(13, selected ? .medium : .regular))
                .foregroundStyle(selected ? Instrument.solidInk : Instrument.railInk)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? Instrument.solidFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The panel

/// One section: its head, then its dials — catalog rows first, then whatever
/// the section carries that isn't a stored setting.
private struct SettingsPanel: View {
    @EnvironmentObject private var store: SettingsStore
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 0) {
            PageHead(section.rawValue, subtitle: section.summary)
            panelBody
            if store.hasUnsavedChanges { SaveBar() }
        }
    }

    private var panelBody: some View {
        PageBody {
            VStack(alignment: .leading, spacing: 0) {
                // Focus Mode's switch is live state, not a stored setting,
                // so it stands at the head of its section: the dials under
                // it read as what the switch does.
                if section == .focusMode { FocusModeRow() }
                // Privacy's exclusions come *before* its one catalog
                // setting: the section is about what Shifu refuses to
                // look at, and opening with "how long text is kept"
                // answers a question nobody arrived with.
                if section == .privacy { PrivacyRows() }
                // A gated int is one backend's dial, so it stands after the
                // choice that reveals it, with that backend's text rows — not
                // up top with the section's own dials.
                ForEach(visibleInts.filter { $0.visibleWhen == nil }) {
                    IntSettingRow(setting: $0)
                }
                ForEach(visibleChoices) { ChoiceSettingRow(setting: $0) }
                ForEach(visibleTexts) { TextSettingRow(setting: $0) }
                ForEach(visibleInts.filter { $0.visibleWhen != nil }) {
                    IntSettingRow(setting: $0)
                }
                ForEach(SettingsCatalog.domainLists.filter { $0.section == section }) {
                    DomainListRow(setting: $0)
                }
                extras
                if let error = store.lastError {
                    Text(error)
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.overdue)
                        .padding(.top, 12)
                }
            }
        }
    }

    private var visibleInts: [IntSetting] {
        SettingsCatalog.ints.filter { $0.section == section && store.isVisible($0) }
    }

    private var visibleChoices: [ChoiceSetting] {
        SettingsCatalog.choices.filter { $0.section == section && store.isVisible($0) }
    }

    private var visibleTexts: [TextSetting] {
        SettingsCatalog.texts.filter { $0.section == section && store.isVisible($0) }
    }

    /// What a section carries beyond the catalog, under its catalog rows. Each
    /// is a separate `if` rather than one switch: a reused `@ViewBuilder`
    /// switch over a section is one of the shapes that crashes this app's
    /// SwiftUI IRGen.
    @ViewBuilder private var extras: some View {
        if section == .capture { CaptureLadderRow() }
        if section == .about { AboutRows() }
        // The Qwen edition's model state, under the backend rows it serves:
        // installed tier, a live download, or the way back in when
        // onboarding's fetch failed or was skipped. Same panel, same
        // fetcher as onboarding — a download started there continues here.
        if section == .analysis, Edition.current == .qwen,
           store.value(for: SettingsCatalog.analysisBackend) == "local" {
            LocalModelSetupPanel()
                .padding(.top, 12)
        }
    }
}

/// The bar the panel grows the moment a dial differs from what's stored, and
/// loses the moment it doesn't — dialling a setting back disarms it, as does
/// Save itself. Pinned under the scroll rather than in it, so a staged edit
/// three sections away can't hide its own Save button.
///
/// Save writes the staged edits and re-reads the store; the daemon reloads
/// saved values on its own within a heartbeat (`Daemon.reloadIntervals()`).
/// The list gestures — exclusions, Focus Mode's sites — never arm this bar,
/// because their Add/remove already committed.
private struct SaveBar: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            Rule(weight: .section)
            HStack(alignment: .center, spacing: 12) {
                Text("Changes staged, not yet applied — Save writes them, "
                    + "and the daemon reloads within a heartbeat.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                OutlineButton(title: "Discard") { store.discardChanges() }
                SolidButton(title: "Save") { store.save() }
            }
            .padding(.horizontal, Instrument.gutter)
            .padding(.vertical, 11)
        }
        .background(Instrument.rail.opacity(0.55))
    }
}

/// The question asked when something would carry the user away from staged
/// edits — clicking another place, or quitting. One shape for both, which is
/// why it is app-modal (`runModal`) rather than a sheet: navigation needs a
/// synchronous answer to cancel itself, and `applicationShouldTerminate`
/// cannot return until it has one. System chrome on purpose — this is the
/// one dialog in the app, and a warning that looks like macOS is a warning
/// the user has already learned to read.
@MainActor
enum UnsavedSettingsAlert {
    static func ask() -> SettingsStore.DepartureChoice {
        let alert = NSAlert()
        alert.messageText = "Save your settings changes?"
        alert.informativeText =
            "You have settings edits that aren't saved. Unsaved changes never "
            + "reach the daemon; discarding puts the dials back as they were."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .stay
        }
    }
}

extension SettingsStore {
    /// The gate every way out shares — another place (`Router.departureGuard`),
    /// the window's close button (`WindowCloseGuard`), quitting (`AppDelegate`).
    /// Free when nothing is staged; otherwise the three-way question.
    func confirmDeparture() -> Bool {
        guard hasUnsavedChanges else { return true }
        return resolveDeparture(UnsavedSettingsAlert.ask())
    }
}

/// Focus Mode's switch — the `focus_mode` control file the daemon watches, not a
/// catalog setting, so it reads through `LedgerStore` like the rail's copy of
/// the same switch and there is nothing to store here.
private struct FocusModeRow: View {
    @EnvironmentObject private var ledger: LedgerStore

    var body: some View {
        SettingRow(
            "Focus Mode",
            help: "On until you turn it off — it doesn't expire. The same switch sits "
                + "at the source list's foot and in the menu bar, and all three show "
                + "the same state because all three read the one control file."
        ) {
            HStack(spacing: 10) {
                Figure(ledger.focusModeOn ? "on" : "off", color: Instrument.secondary)
                ToggleSwitch(isOn: ledger.focusModeOn) { ledger.toggleFocusMode() }
            }
            .accessibilityLabel("Focus Mode")
        }
    }
}

/// The capture ladder, stated (§3.2). A reading with no dial, because the
/// rungs are not configurable and the thing worth saying about them — that the
/// screenshot is never written down — is an invariant, not a preference.
private struct CaptureLadderRow: View {
    var body: some View {
        SettingRow(
            "Screenshots", note: "never saved",
            help: "Shifu reads window titles and accessibility text first, and only "
                + "falls back to a screenshot for apps that expose no text. The bitmap "
                + "lives in memory for the one OCR call and is never written to disk."
        ) {
            EmptyView()
        }
    }
}
