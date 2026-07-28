import Combine
import Foundation
import ShifuCore
import SwiftUI

/// Read/write model for the Settings window (design.md §9).
///
/// Keyed by setting rather than one property per setting, so adding a catalog
/// entry costs nothing here — this type never grows. Writes go straight to the
/// `settings` table; `shifud` picks them up on its own (see
/// `Daemon.reloadIntervals()`).
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var ints: [String: Int] = [:]
    @Published private(set) var domainLists: [String: [String]] = [:]
    @Published private(set) var choices: [String: String] = [:]
    @Published private(set) var texts: [String: String] = [:]
    @Published private(set) var lastError: String?

    private var database: ShifuDatabase?

    private func db() throws -> ShifuDatabase {
        if let database { return database }
        try ShifuPaths.ensureHomeExists()
        let opened = try ShifuDatabase.open(at: ShifuPaths.database)
        database = opened
        return opened
    }

    func load() {
        do {
            let database = try db()
            for setting in SettingsCatalog.ints {
                ints[setting.key] = Settings.value(setting, database: database)
            }
            for setting in SettingsCatalog.domainLists {
                domainLists[setting.key] = Settings.value(setting, database: database)
            }
            for setting in SettingsCatalog.choices {
                choices[setting.key] = Settings.value(setting, database: database)
            }
            for setting in SettingsCatalog.texts {
                texts[setting.key] = Settings.value(setting, database: database)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Ints

    func value(for setting: IntSetting) -> Int {
        ints[setting.key] ?? setting.defaultValue
    }

    func set(_ setting: IntSetting, to value: Int) {
        let clamped = setting.clamp(value)
        ints[setting.key] = clamped        // optimistic: keeps the Stepper responsive
        do {
            try Settings.set(setting, to: clamped, database: db())
            lastError = nil
        } catch {
            // Never leave the optimistic value on screen after a failed write —
            // the daemon would still be on the old interval and the UI would be
            // quietly lying about it. Re-read so what's shown is what's stored.
            lastError = "\(error)"
            load()
        }
    }

    func binding(for setting: IntSetting) -> Binding<Int> {
        Binding(get: { self.value(for: setting) }, set: { self.set(setting, to: $0) })
    }

    // MARK: - Choices & text (AI backend config)

    func value(for setting: ChoiceSetting) -> String {
        choices[setting.key] ?? setting.defaultValue
    }

    func set(_ setting: ChoiceSetting, to value: String) {
        choices[setting.key] = setting.normalize(value)
        do {
            try Settings.set(setting, to: value, database: db())
            lastError = nil
        } catch {
            lastError = "\(error)"
            load()
        }
    }

    func binding(for setting: ChoiceSetting) -> Binding<String> {
        Binding(get: { self.value(for: setting) }, set: { self.set(setting, to: $0) })
    }

    func value(for setting: TextSetting) -> String {
        texts[setting.key] ?? ""
    }

    func set(_ setting: TextSetting, to value: String) {
        texts[setting.key] = value
        do {
            try Settings.set(setting, to: value, database: db())
            lastError = nil
        } catch {
            lastError = "\(error)"
            load()
        }
    }

    func binding(for setting: TextSetting) -> Binding<String> {
        Binding(get: { self.value(for: setting) }, set: { self.set(setting, to: $0) })
    }

    /// Whether a text row should show, given its `visibleWhen` gate.
    func isVisible(_ setting: TextSetting) -> Bool {
        guard let gate = setting.visibleWhen else { return true }
        let current = SettingsCatalog.choices.first { $0.key == gate.key }
            .map(value(for:)) ?? choices[gate.key]
        return current == gate.value
    }

    // MARK: - Domain lists

    func domains(for setting: DomainListSetting) -> [String] {
        domainLists[setting.key] ?? []
    }

    /// No-op when the input isn't a usable domain or is already listed.
    func add(_ raw: String, to setting: DomainListSetting) {
        guard let domain = setting.normalize(raw) else { return }
        var current = domains(for: setting)
        guard !current.contains(domain) else { return }
        current.append(domain)
        write(current, to: setting)
    }

    func remove(_ domain: String, from setting: DomainListSetting) {
        write(domains(for: setting).filter { $0 != domain }, to: setting)
    }

    private func write(_ domains: [String], to setting: DomainListSetting) {
        do {
            try Settings.set(setting, to: domains, database: db())
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        load()   // re-read so normalization/de-duplication is what's displayed
    }
}
