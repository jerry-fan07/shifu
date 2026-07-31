import ShifuCore
import SwiftUI

/// The Settings place (design.md §9), in the Instrument register: a label, its
/// value in mono on the right, and one line underneath saying what it does. No
/// boxes — a section is a rule and a heading. A place like any other rather
/// than a separate window: the app is one instrument, and its dials are on it.
///
/// Rendered *from* `SettingsCatalog` rather than from hand-written rows: adding
/// a numeric setting to the catalog makes it appear here, correctly bounded and
/// labelled, with no change to this file. The one exception is Work Mode's own
/// switch — live state, not a stored setting — which stands at the head of its
/// section so the dials under it read as what the switch does.
struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                "Settings",
                subtitle: "Capture and analysis changes reach the running daemon "
                    + "without a restart.")
            PageBody {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(SettingsSection.allCases.enumerated()), id: \.element
                    ) { index, section in
                        SettingsGroup(section: section, ruled: index > 0)
                    }
                    if let error = store.lastError {
                        Text(error)
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(Instrument.overdue)
                            .padding(.top, 10)
                    }
                }
                // Full-bleed rows would strand each value a window's width from
                // its label; the page is a column of dials, not a table.
                .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .onAppear { store.load() }
    }
}

/// One catalog section, or nothing at all when everything in it is hidden.
/// `ruled` separates it from the section above; the first sits directly under
/// the page head's own rule.
private struct SettingsGroup: View {
    @EnvironmentObject private var store: SettingsStore
    let section: SettingsSection
    let ruled: Bool

    var body: some View {
        let ints = SettingsCatalog.ints.filter { $0.section == section }
        let choices = SettingsCatalog.choices.filter { $0.section == section }
        let texts = SettingsCatalog.texts.filter {
            $0.section == section && store.isVisible($0)
        }
        let lists = SettingsCatalog.domainLists.filter { $0.section == section }
        if section == .workMode || !ints.isEmpty || !choices.isEmpty
            || !texts.isEmpty || !lists.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if ruled {
                    Rule(weight: .section)
                        .padding(.top, 6)
                }
                Eyebrow(section.rawValue, tracking: 1.2)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                if section == .workMode { WorkModeRow() }
                ForEach(ints) { IntSettingRow(setting: $0) }
                ForEach(choices) { ChoiceSettingRow(setting: $0) }
                ForEach(texts) { TextSettingRow(setting: $0) }
                ForEach(lists) { DomainListRow(setting: $0) }
                if section == .analysis, let spend = store.llmSpendToday {
                    LLMSpendRow(spend: spend)
                }
            }
        }
    }
}

/// Work Mode's switch. Live state — the `work_mode` control file the daemon
/// watches — not a catalog setting, so it reads through `LedgerStore` like the
/// rail's copy of the same switch and there is nothing to store here.
private struct WorkModeRow: View {
    @EnvironmentObject private var ledger: LedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("Work Mode")
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                Spacer(minLength: 0)
                Figure(
                    ledger.workModeOn ? "on" : "off",
                    color: Instrument.secondary)
                ToggleSwitch(isOn: ledger.workModeOn) { ledger.toggleWorkMode() }
            }
            SettingHelp(
                "A gentle glow when a distracting site holds the screen. The same "
                    + "switch sits at the rail's foot and in the menu bar.")
        }
        .accessibilityLabel("Work Mode")
    }
}

/// What today's analysis has cost, at the rates set just above it. A reading,
/// not a dial — the only row here the user can't turn — so it carries no
/// control and stands last in its section. Absent entirely on a day nothing
/// was billed, rather than reading "$0.000" at someone who hasn't opted in.
private struct LLMSpendRow: View {
    let spend: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("LLM spend today")
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                Spacer(minLength: 0)
                Figure(spend, color: Instrument.secondary)
            }
            SettingHelp("An estimate: today's token counts priced at the rates "
                + "above. Analysis is never stopped on cost.")
        }
    }
}

/// The help line every setting carries. Kept as its own view so no row can
/// forget it — a number with no explanation is how a settings screen rots.
private struct SettingHelp: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Instrument.sans(11.5))
            .foregroundStyle(Instrument.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
    }
}

/// Stepper bounded by the descriptor's own range — the UI states no limits of
/// its own, so it can't drift from what the daemon enforces.
private struct IntSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: IntSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(setting.title)
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                Spacer(minLength: 0)
                Figure(setting.display(store.value(for: setting)), color: Instrument.secondary)
                HStack(spacing: 0) {
                    nudge("−", by: -setting.step)
                    Rectangle().fill(Instrument.edge).frame(width: 1)
                    nudge("+", by: setting.step)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
            }
            SettingHelp(setting.help)
        }
    }

    private func nudge(_ glyph: String, by step: Int) -> some View {
        let value = store.value(for: setting)
        let next = value + step
        return Button {
            store.binding(for: setting).wrappedValue = next
        } label: {
            Text(glyph)
                .font(Instrument.sans(12))
                .foregroundStyle(Instrument.railInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!setting.range.contains(next))
        .opacity(setting.range.contains(next) ? 1 : 0.35)
    }
}

/// The descriptor's own options as a segmented strip; unknown stored values
/// render as the default because reads normalize.
private struct ChoiceSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: ChoiceSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(setting.title)
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                Spacer(minLength: 0)
                SegmentedBar(
                    options: setting.options.map { ($0.label, $0.value) },
                    selection: store.binding(for: setting))
            }
            SettingHelp(setting.help)
        }
    }
}

/// Free-text row; secure settings (API keys) render as a SecureField.
private struct TextSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: TextSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(setting.title)
                    .font(Instrument.sans(13))
                    .foregroundStyle(Instrument.ink)
                    .frame(width: 108, alignment: .leading)
                Group {
                    if setting.secure {
                        SecureField(setting.placeholder, text: store.binding(for: setting))
                    } else {
                        TextField(setting.placeholder, text: store.binding(for: setting))
                    }
                }
                .textFieldStyle(.plain)
                .font(Instrument.mono(12))
                .foregroundStyle(Instrument.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
            }
            SettingHelp(setting.help)
        }
    }
}

/// Add-row plus a deletable list: type a value, Add appends it, remove drops it.
private struct DomainListRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: DomainListSetting
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(setting.title)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
            Text(setting.help)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                TextField(setting.placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Instrument.mono(12))
                    .foregroundStyle(Instrument.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Instrument.edge, lineWidth: 1)
                    }
                    .onSubmit(add)
                OutlineButton(title: "Add", action: add)
                    .opacity(setting.normalize(draft) == nil ? 0.35 : 1)
                    .allowsHitTesting(setting.normalize(draft) != nil)
            }
            .padding(.bottom, 8)

            let domains = store.domains(for: setting)
            if domains.isEmpty {
                Text("No sites yet.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                    .padding(.bottom, 12)
            } else {
                ForEach(domains, id: \.self) { domain in
                    Rule()
                    HStack {
                        Figure(domain, size: 12, color: Instrument.secondary)
                        Spacer()
                        InlineLink("remove") { store.remove(domain, from: setting) }
                    }
                    .padding(.vertical, 4)
                }
                Spacer().frame(height: 12)
            }
        }
    }

    private func add() {
        store.add(draft, to: setting)
        draft = ""
    }
}
