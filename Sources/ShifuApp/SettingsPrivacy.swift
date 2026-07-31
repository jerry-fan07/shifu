import AppKit
import ShifuCore
import SwiftUI
import UniformTypeIdentifiers

/// The two sections that carry no stored settings of their own: Privacy, whose
/// exclusions live in their own table, and About, whose facts live on disk.
///
/// Privacy is the section this redesign exists for. The exclusion list has been
/// in the schema since v1 and the daemon has always merged it with the built-in
/// defaults — but nothing could write a row, so the "user-editable" half of
/// design.md §8 was a promise no surface kept. A trust screen that can't be
/// edited is a claim, not a control.

/// Excluded apps, excluded domains, and the redaction choke point — the rows
/// that stand above Privacy's one catalog setting (text retention).
struct PrivacyRows: View {
    var body: some View {
        ExcludedAppsRow()
        ExcludedDomainsRow()
        RedactionRow()
    }
}

/// Apps skipped before capture. Chosen from a file panel rather than typed:
/// the daemon matches on bundle identifier, and asking someone to know that
/// `com.apple.MobileSMS` is Messages is how a privacy control goes unused.
private struct ExcludedAppsRow: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var showingBuiltIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                "Excluded apps",
                help: "Skipped before capture, so they contribute duration and nothing "
                    + "else — no title, no text, no URL. Password managers and system "
                    + "auth surfaces are built in."
            ) {
                OutlineButton(title: "Add app…") { choose() }
            }
            ValueList(
                values: store.excluded(.bundle),
                empty: "Nothing beyond the built-in list.",
                label: Self.appName,
                remove: { store.unexclude($0, kind: .bundle) })
            BuiltInDisclosure(
                kind: .bundle, expanded: $showingBuiltIn, label: Self.appName)
        }
    }

    /// The app's own name when macOS can still find it, falling back to the
    /// identifier — which is also what an app that has since been deleted
    /// shows, so a stale row is visibly stale rather than silently wrong.
    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Shifu will skip this app before capture."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        store.exclude(bundleID, kind: .bundle)
    }
}

/// Excluded domains. Normalized through the same reduction Work Mode's site
/// list uses, so pasting a full URL works here for the same reason it works
/// there — and so what is stored is the shape `Exclusions` compares against.
private struct ExcludedDomainsRow: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var draft = ""
    @State private var showingBuiltIn = false

    /// Borrowed for its `normalize` alone: exclusions are not a setting, but
    /// "what counts as a domain" must not be written twice.
    private var shape: DomainListSetting { SettingsCatalog.workModeDistractingDomains }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                "Excluded domains",
                help: "Matched against the host, subdomains included — paste a full URL "
                    + "and Shifu reduces it. Finance and health portals ship excluded."
            ) {
                DomainAddField(
                    placeholder: "example.com", draft: $draft,
                    isValid: { shape.normalize($0) != nil },
                    add: { add() })
            }
            ValueList(
                values: store.excluded(.domain),
                empty: "Nothing beyond the built-in list.",
                remove: { store.unexclude($0, kind: .domain) })
            BuiltInDisclosure(kind: .domain, expanded: $showingBuiltIn)
        }
    }

    private func add() {
        guard let domain = shape.normalize(draft) else { return }
        store.exclude(domain, kind: .domain)
        draft = ""
    }
}

/// The built-in half of an exclusion list, collapsed. Folded rather than shown
/// because twenty-two banking domains would bury the two rows you added — but
/// present, because "is my bank already covered?" is the question this page
/// exists to answer, and a count alone doesn't answer it.
private struct BuiltInDisclosure: View {
    let kind: Exclusions.Kind
    @Binding var expanded: Bool
    var label: (String) -> String = { $0 }

    var body: some View {
        let values = kind.builtIn.sorted()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow("\(values.count) built in", size: 9.5, tracking: 0.6)
                InlineLink(expanded ? "hide" : "show") { expanded.toggle() }
            }
            .padding(.bottom, expanded ? 6 : 13)
            if expanded {
                ValueList(values: values, label: label)
            }
        }
    }
}

/// Redaction, stated. The one row on this page with no control at all, and
/// deliberately so: it is a single choke point every write passes through
/// (CLAUDE.md invariant 2), and a switch beside it would imply there is a way
/// around it.
private struct RedactionRow: View {
    var body: some View {
        SettingRow(
            "Redaction", note: "always on",
            help: "Every extracted string passes one choke point before disk — PEM "
                + "blocks, JWTs, API keys, card numbers and SSNs are replaced in "
                + "place. There is no path around it, and no setting that opens one."
        ) {
            EmptyView()
        }
    }
}

// MARK: - About

/// Where everything lives, and what this build is. Facts about the machine
/// rather than dials, so every control here opens something rather than
/// changing it.
struct AboutRows: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        SettingRow(
            "Version",
            help: "Five processes share one database: the capture daemon, the analysis "
                + "worker, the CLI, this app, and the menu bar item."
        ) {
            Figure("Shifu \(Shifu.version)", color: Instrument.secondary)
        }
        SettingRow(
            "Database", note: store.diagnostics?.databaseEncrypted == true
                ? "encrypted" : nil,
            help: encryptionHelp
        ) {
            Figure(store.diagnostics?.databaseSizeLabel ?? "—", color: Instrument.ink)
            OutlineButton(title: "Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([ShifuPaths.database])
            }
        }
        SettingRow(
            "Vault",
            help: "Markdown, one file per note, readable by anything. The database "
                + "indexes it; the files are the source of truth."
        ) {
            OutlineButton(title: "Open") { open(ShifuPaths.vault) }
        }
        SettingRow(
            "Logs",
            help: "The daemon's own log, size-capped. The first place to look when the "
                + "ledger stops filling up."
        ) {
            OutlineButton(title: "Open") { open(ShifuPaths.logs) }
        }
    }

    private var encryptionHelp: String {
        let base = "Observations, the ledger, tasks, themes and review history, at "
            + "\(ShifuPaths.database.path). "
        return store.diagnostics?.databaseEncrypted == true
            ? base + "Encrypted at rest with SQLCipher."
            : base + "Stored in plaintext — run `shifu encrypt` to convert it in place."
    }

    private func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
