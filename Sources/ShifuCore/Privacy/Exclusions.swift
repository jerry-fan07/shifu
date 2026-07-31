import Foundation
import GRDB

/// Exclusion list, enforced in the daemon *before* capture (design.md §8).
/// Hardcoded defaults merged with user rows from the `exclusions` table.
public struct Exclusions: Sendable {
    /// Password managers, keychain, and system auth surfaces. Never captured.
    public static let defaultBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "com.dashlane.dashlanephonefinal",
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent"
    ]

    /// Banking/financial and health portals. User-editable; seed list only.
    public static let defaultDomains: Set<String> = [
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
        "capitalone.com", "usbank.com", "americanexpress.com", "discover.com",
        "fidelity.com", "schwab.com", "vanguard.com", "etrade.com",
        "robinhood.com", "wealthfront.com", "betterment.com",
        "paypal.com", "venmo.com", "wise.com",
        "mychart.com", "healthcare.gov", "irs.gov", "ssa.gov"
    ]

    public var bundleIDs: Set<String>
    public var domains: Set<String>

    public init(bundleIDs: Set<String> = defaultBundleIDs, domains: Set<String> = defaultDomains) {
        self.bundleIDs = bundleIDs
        self.domains = domains
    }

    /// Defaults merged with user-added rows from the `exclusions` table.
    public init(database: ShifuDatabase) throws {
        var bundles = Self.defaultBundleIDs
        var domains = Self.defaultDomains
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT kind, value FROM exclusions")
            for row in rows {
                let kind: String = row["kind"]
                let value: String = row["value"]
                if kind == "bundle" { bundles.insert(value) } else { domains.insert(value.lowercased()) }
            }
        }
        self.init(bundleIDs: bundles, domains: domains)
    }

    public func isExcluded(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    // MARK: - The user's own rows

    /// Which of the two lists a row belongs to. The `exclusions` table stores
    /// this as its `kind` column, and has since v1 — the strings are schema.
    public enum Kind: String, Sendable {
        case bundle
        case domain

        /// The built-in list this kind is merged with. Shown beside the user's
        /// rows rather than hidden, because "is my bank already covered?" is
        /// the question this screen exists to answer.
        public var builtIn: Set<String> {
            switch self {
            case .bundle: return Exclusions.defaultBundleIDs
            case .domain: return Exclusions.defaultDomains
            }
        }
    }

    /// The rows the user added, sorted — the built-ins are not in here, so a
    /// list can show what is removable without guessing.
    public static func userValues(
        kind: Kind, database: ShifuDatabase
    ) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(
                db, sql: "SELECT value FROM exclusions WHERE kind = ? ORDER BY value",
                arguments: [kind.rawValue])
        }
    }

    /// Adding a built-in is a no-op rather than an error: the value is already
    /// excluded, and a duplicate row would only make it look removable.
    public static func add(
        _ value: String, kind: Kind, database: ShifuDatabase
    ) throws {
        let cleaned = kind == .domain
            ? value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !kind.builtIn.contains(cleaned) else { return }
        try database.queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO exclusions (kind, value) VALUES (?, ?)",
                arguments: [kind.rawValue, cleaned])
        }
    }

    public static func remove(
        _ value: String, kind: Kind, database: ShifuDatabase
    ) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "DELETE FROM exclusions WHERE kind = ? AND value = ?",
                arguments: [kind.rawValue, value])
        }
    }

    /// True if the URL's host is an excluded domain or a subdomain of one.
    public func isExcluded(url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
