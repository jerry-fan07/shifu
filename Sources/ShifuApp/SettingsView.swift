import ShifuCore
import SwiftUI

/// Settings window (design.md §9).
///
/// Rendered *from* `SettingsCatalog` rather than from hand-written rows: adding
/// a numeric setting to the catalog makes it appear here, correctly bounded and
/// labelled, with no change to this file.
struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        List {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                let ints = SettingsCatalog.ints.filter { $0.section == section }
                let lists = SettingsCatalog.domainLists.filter { $0.section == section }
                let choices = SettingsCatalog.choices.filter { $0.section == section }
                let texts = SettingsCatalog.texts.filter {
                    $0.section == section && store.isVisible($0)
                }
                if !ints.isEmpty || !lists.isEmpty || !choices.isEmpty || !texts.isEmpty {
                    Section(section.rawValue) {
                        ForEach(ints) { IntSettingRow(setting: $0) }
                        ForEach(choices) { ChoiceSettingRow(setting: $0) }
                        ForEach(texts) { TextSettingRow(setting: $0) }
                        ForEach(lists) { DomainListRow(setting: $0) }
                    }
                }
            }

            Section {
                Text("Capture and analysis changes apply to the running daemon "
                     + "without a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.inset)
        .onAppear { store.load() }
    }
}

/// Stepper bounded by the descriptor's own range — the UI states no limits of
/// its own, so it can't drift from what the daemon enforces.
private struct IntSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: IntSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: store.binding(for: setting), in: setting.range, step: setting.step) {
                HStack {
                    Text(setting.title)
                    Spacer()
                    Text(setting.display(store.value(for: setting)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(setting.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Picker over the descriptor's own options; unknown stored values render as
/// the default because reads normalize.
private struct ChoiceSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: ChoiceSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(setting.title, selection: store.binding(for: setting)) {
                ForEach(setting.options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            Text(setting.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Free-text row; secure settings (API keys) render as a SecureField.
private struct TextSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: TextSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(setting.title)
                if setting.secure {
                    SecureField(setting.placeholder, text: store.binding(for: setting))
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(setting.placeholder, text: store.binding(for: setting))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text(setting.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Add-row + deletable list, mirroring the "New project" pattern in `VaultTabView`.
private struct DomainListRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: DomainListSetting
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(setting.title)
            Text(setting.help)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField(setting.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(setting.normalize(draft) == nil)
            }

            let domains = store.domains(for: setting)
            if domains.isEmpty {
                Text("No sites yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(domains, id: \.self) { domain in
                    HStack {
                        Text(domain).font(.callout)
                        Spacer()
                        Button {
                            store.remove(domain, from: setting)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(domain)")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func add() {
        store.add(draft, to: setting)
        draft = ""
    }
}
