import Combine
import Foundation
import ShifuCore
import SwiftUI

/// Read/write model for the Settings window (design.md §9).
///
/// Keyed by setting rather than one property per setting, so adding a catalog
/// entry costs nothing here — this type never grows. Dial edits (steppers,
/// strips, text fields) are *staged*: they sit in the draft dictionaries until
/// `save()` writes them to the `settings` table in one gesture, which is when
/// `shifud` starts picking them up on its own (see `Daemon.reloadIntervals()`).
/// Staging is what keeps a half-typed API key off the disk. The list gestures —
/// exclusions, Focus Mode's sites — still write immediately: "Add" and "remove"
/// are already explicit, and a privacy exclusion must not wait behind a second
/// button (§8: exclusions are enforced before capture).
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var ints: [String: Int] = [:]
    @Published private(set) var domainLists: [String: [String]] = [:]
    @Published private(set) var choices: [String: String] = [:]
    @Published private(set) var texts: [String: String] = [:]
    @Published private(set) var lastError: String?
    /// Edits not yet written. An entry exists only while it differs from the
    /// stored value, so "any entry at all" is the Save bar's whole trigger —
    /// dialling a setting back to what's stored disarms it.
    @Published private(set) var draftInts: [String: Int] = [:]
    @Published private(set) var draftChoices: [String: String] = [:]
    @Published private(set) var draftTexts: [String: String] = [:]
    /// Which section the page is showing. Held here rather than in the view so
    /// the window's title bar can name it — "Settings · Analysis" — and so
    /// stepping away to another place and back doesn't reset it.
    @Published var section: SettingsSection = .capture
    /// The user's own exclusion rows, by kind — the built-ins are merged in by
    /// `Exclusions.init(database:)` at capture time and are not in here, so a
    /// list can show what's removable without guessing.
    @Published private(set) var exclusions: [Exclusions.Kind: [String]] = [:]
    /// What the machine is actually doing, for the page's right-hand column.
    /// Nil until the first read.
    @Published private(set) var diagnostics: SettingsDiagnostics?

    private var database: ShifuDatabase?

    /// The app passes nothing and the store opens ~/Shifu on first use; tests
    /// hand in an in-memory database.
    init(database: ShifuDatabase? = nil) {
        self.database = database
    }

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
            for kind in [Exclusions.Kind.bundle, .domain] {
                exclusions[kind] = try Exclusions.userValues(kind: kind, database: database)
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        loadDiagnostics()
    }

    /// Re-reads the right-hand column alone. Separate from `load()` because
    /// the dials are stable and these numbers are not: the column refreshes on
    /// a timer while Settings is open, and re-reading every setting underneath
    /// a half-typed API key would put the stored value back in the field.
    func loadDiagnostics() {
        guard let database = try? db() else { return }
        diagnostics = SettingsDiagnostics.read(database: database)
    }

    // MARK: - Exclusions (their own table, not a setting)

    /// The user's rows for one kind. Built-ins are deliberately not merged in
    /// here — the Privacy page shows them separately, as unremovable.
    func excluded(_ kind: Exclusions.Kind) -> [String] { exclusions[kind] ?? [] }

    func exclude(_ value: String, kind: Exclusions.Kind) {
        write(kind) { try Exclusions.add(value, kind: kind, database: $0) }
    }

    func unexclude(_ value: String, kind: Exclusions.Kind) {
        write(kind) { try Exclusions.remove(value, kind: kind, database: $0) }
    }

    /// Re-reads after every write rather than mutating optimistically: the
    /// table de-duplicates and drops built-ins, so what's shown has to be what
    /// the daemon will read on its next capture, not what we asked for.
    private func write(
        _ kind: Exclusions.Kind, _ change: (ShifuDatabase) throws -> Void
    ) {
        do {
            let database = try db()
            try change(database)
            exclusions[kind] = try Exclusions.userValues(kind: kind, database: database)
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Save (the staged dials)

    var hasUnsavedChanges: Bool {
        !draftInts.isEmpty || !draftChoices.isEmpty || !draftTexts.isEmpty
    }

    /// Writes every staged edit, then re-reads so what's shown is what's
    /// stored. That write is the whole reload story: `shifud` re-reads the
    /// settings table on its next heartbeat (`Daemon.reloadIntervals()`), and
    /// the diagnostics column re-reads here rather than waiting for its timer.
    ///
    /// Each draft is cleared as its write lands, so a mid-save failure keeps
    /// the unwritten ones staged — the bar stays up and Save retries exactly
    /// what is still pending.
    func save() {
        do {
            let database = try db()
            for setting in SettingsCatalog.ints {
                guard let value = draftInts[setting.key] else { continue }
                try Settings.set(setting, to: value, database: database)
                draftInts[setting.key] = nil
            }
            for setting in SettingsCatalog.choices {
                guard let value = draftChoices[setting.key] else { continue }
                try Settings.set(setting, to: value, database: database)
                draftChoices[setting.key] = nil
            }
            for setting in SettingsCatalog.texts {
                guard let value = draftTexts[setting.key] else { continue }
                try Settings.set(setting, to: value, database: database)
                draftTexts[setting.key] = nil
            }
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        load()
    }

    /// Drops every staged edit; the dials snap back to what's stored.
    func discardChanges() {
        draftInts = [:]
        draftChoices = [:]
        draftTexts = [:]
    }

    /// The answers to "you're leaving with staged edits".
    enum DepartureChoice {
        case save, discard, stay
    }

    /// Applies the user's answer and says whether leaving may proceed. Kept
    /// apart from the alert that asks (`UnsavedSettingsAlert`) so the logic
    /// is testable — and so a failed save keeps you on the page with the
    /// error showing, rather than quietly abandoning the drafts.
    func resolveDeparture(_ choice: DepartureChoice) -> Bool {
        switch choice {
        case .save:
            save()
            return !hasUnsavedChanges
        case .discard:
            discardChanges()
            return true
        case .stay:
            return false
        }
    }

    // MARK: - Ints

    func value(for setting: IntSetting) -> Int {
        draftInts[setting.key] ?? ints[setting.key] ?? setting.defaultValue
    }

    func set(_ setting: IntSetting, to value: Int) {
        let clamped = setting.clamp(value)
        let stored = ints[setting.key] ?? setting.defaultValue
        draftInts[setting.key] = clamped == stored ? nil : clamped
    }

    // MARK: - Choices & text (AI backend config)

    func value(for setting: ChoiceSetting) -> String {
        draftChoices[setting.key] ?? choices[setting.key] ?? setting.defaultValue
    }

    func set(_ setting: ChoiceSetting, to value: String) {
        let normalized = setting.normalize(value)
        let stored = choices[setting.key] ?? setting.defaultValue
        draftChoices[setting.key] = normalized == stored ? nil : normalized
    }

    func binding(for setting: ChoiceSetting) -> Binding<String> {
        Binding(get: { self.value(for: setting) }, set: { self.set(setting, to: $0) })
    }

    func value(for setting: TextSetting) -> String {
        draftTexts[setting.key] ?? texts[setting.key] ?? ""
    }

    /// The draft keeps the string exactly as typed — trimming happens in
    /// `Settings.set` on save, not under the cursor.
    func set(_ setting: TextSetting, to value: String) {
        let stored = texts[setting.key] ?? ""
        draftTexts[setting.key] = value == stored ? nil : value
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
