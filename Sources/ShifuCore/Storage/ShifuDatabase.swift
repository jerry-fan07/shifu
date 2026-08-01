import Foundation
import GRDB

/// Single local SQLite database, WAL mode, one write queue (design.md §2.2, §3.5).
public struct ShifuDatabase: Sendable {
    public let queue: DatabaseQueue

    /// Failures that are *not* corruption. Kept separate precisely so
    /// `openRotatingOnCorruption` can tell "unreadable forever" from
    /// "readable, but not right now" and avoid rotating good data aside.
    public enum OpenError: Error, CustomStringConvertible {
        /// The file is SQLCipher-encrypted but no key is available. This is a
        /// configuration problem, not corruption — never rotate on it.
        case encryptedButNoKey

        public var description: String {
            "database is encrypted but no key was found (Keychain item missing "
                + "and \(DatabaseKey.envVar) unset)"
        }
    }

    /// Opens (creating if needed) the database at the given URL and runs
    /// migrations. Pass a passphrase to open/create SQLCipher-encrypted (§8).
    public init(at url: URL, passphrase: String? = nil) throws {
        var config = Configuration()
        config.qos = .utility
        config.prepareDatabase { db in
            // The key must be applied before any other statement touches the file.
            if let passphrase {
                try db.usePassphrase(passphrase)
            }
            // WAL (§3.5): kill -9 mid-write loses at most one observation.
            // synchronous=NORMAL is the recommended WAL pairing — durable
            // across app crashes, loses at most the last commit on power loss.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        queue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(queue)
    }

    /// True when the file exists and does not start with the plaintext SQLite
    /// magic — i.e. it is SQLCipher-encrypted (or garbage).
    public static func isEncrypted(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16) else { return false }
        return header != Data("SQLite format 3\0".utf8)
    }

    /// The standard opener: resolves the key (env override or Keychain) and
    /// picks plaintext vs encrypted based on the file and key state.
    ///
    /// - plaintext file → open plaintext (even if a key exists; migration to
    ///   encrypted is explicit, via `shifu encrypt`)
    /// - encrypted file → key required, else `OpenError.encryptedButNoKey`
    /// - no file → encrypted when a key exists, plaintext otherwise
    public static func open(at url: URL = ShifuPaths.database) throws -> ShifuDatabase {
        let key = try DatabaseKey.existing()
        if FileManager.default.fileExists(atPath: url.path) {
            if isEncrypted(at: url) {
                guard let key else { throw OpenError.encryptedButNoKey }
                return try ShifuDatabase(at: url, passphrase: key)
            }
            return try ShifuDatabase(at: url)
        }
        return try ShifuDatabase(at: url, passphrase: key)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> ShifuDatabase {
        try ShifuDatabase(queue: DatabaseQueue())
    }

    /// Opens the database; on corruption, rotates the damaged files aside and
    /// starts fresh rather than silently dropping capture (design.md §10).
    /// Returns the rotated-aside URL when rotation happened.
    ///
    /// A Keychain *error* (locked, access denied) is rethrown — the key may
    /// exist, so rotating could orphan good data. A confirmed missing key
    /// rotates: the file is unreadable forever either way, and rotation
    /// renames rather than deletes.
    public static func openRotatingOnCorruption(at url: URL) throws -> (ShifuDatabase, rotatedTo: URL?) {
        do {
            return (try open(at: url), nil)
        } catch let error as DatabaseKey.KeyError {
            throw error
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.moveItem(
                        at: source, to: URL(fileURLWithPath: aside.path + suffix))
                }
            }
            return (try open(at: url), aside)
        }
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }
}

/// Typed access to the `settings` table.
public enum Settings {
    /// Analysis backend: "shifu-cloud" (hosted proxy, no user key — choosing
    /// it is the opt-in), "deepseek" (the user's own API key is the opt-in —
    /// the default, inert until a key is set) or "off" (rules-only). Legacy
    /// values ("auto", "claude", "openai") are folded into these by
    /// migration v15.
    public static let analysisBackendKey = "analysis.backend"
    public static let deepseekAPIKeyKey = "deepseek.api_key"
    /// Device token minted by the Shifu Cloud proxy on the analyzer's first
    /// run — an implementation detail of the hosted backend, never typed by
    /// the user. The opt-in is the backend choice, not this token existing.
    public static let shifuCloudTokenKey = "shifu_cloud.token"
    public static let shifuCloudBaseURLKey = "shifu_cloud.base_url"
    public static let deepseekBaseURLKey = "deepseek.base_url"
    /// Fast model (default deepseek-v4-flash): classification, extraction,
    /// narratives, radar — the high-volume, low-judgment stages.
    public static let deepseekModelKey = "deepseek.model"
    /// Reasoning model (default deepseek-v4-pro): semantic task grouping and
    /// theme clustering, where naming the user's intent is the whole job.
    public static let deepseekReasoningModelKey = "deepseek.reasoning_model"
    public static let digestHourKey = "digest.hour"

    public static func get(_ key: String, database: ShifuDatabase) throws -> String? {
        try database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public static func set(_ key: String, to value: String, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "INSERT INTO settings (key, value) VALUES (?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    /// What the LLM stages may authenticate with, or nil when the user has
    /// not opted in — the gate that decides whether anything ever leaves this
    /// Mac (§8). Lives here rather than beside the backend because two
    /// binaries need the same answer for different reasons: the analyzer
    /// builds a backend from it, and the app greys out the actions that can't
    /// work without one. A credential here is not a promise the endpoint
    /// answers; it is the difference between "will try" and "cannot".
    public static func llmCredential(database: ShifuDatabase) throws -> LLMCredential? {
        switch try get(analysisBackendKey, database: database) {
        case "off":
            return nil
        case "shifu-cloud":
            // The choice itself is the opt-in; the token is provisioned by
            // the analyzer on its next run when nil.
            let token = try get(shifuCloudTokenKey, database: database)
            return .shifuCloud(token: (token?.isEmpty ?? true) ? nil : token)
        default:
            guard let key = try ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
                ?? get(deepseekAPIKeyKey, database: database), !key.isEmpty
            else { return nil }
            return .deepseek(key: key)
        }
    }
}

/// How the analyzer may talk to an LLM once the user has opted in: their own
/// DeepSeek key, or the hosted Shifu Cloud proxy (whose device token may not
/// exist yet — the analyzer mints one on first use).
public enum LLMCredential: Equatable, Sendable {
    case deepseek(key: String)
    case shifuCloud(token: String?)
}

// MARK: - Catalog-typed access

/// Typed reads/writes for `SettingsCatalog` entries. Every path routes through
/// the descriptor's own `clamp`/`normalize`, so callers never restate bounds —
/// that's what keeps the daemon and the app from drifting apart.
extension Settings {
    /// Clamped, and defaulted when missing or unparseable. Non-throwing: a bad
    /// settings row must never take the daemon down (design.md §10).
    public static func value(_ setting: IntSetting, database: ShifuDatabase) -> Int {
        guard let raw = try? get(setting.key, database: database),
              let parsed = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return setting.defaultValue }
        return setting.clamp(parsed)
    }

    public static func set(_ setting: IntSetting, to value: Int, database: ShifuDatabase) throws {
        try set(setting.key, to: String(setting.clamp(value)), database: database)
    }

    /// Normalized and de-duplicated, order preserved.
    public static func value(_ setting: DomainListSetting, database: ShifuDatabase) -> [String] {
        guard let raw = try? get(setting.key, database: database) else { return [] }
        var seen: Set<String> = []
        return raw.split(separator: "\n").compactMap { line in
            guard let domain = setting.normalize(String(line)), seen.insert(domain).inserted
            else { return nil }
            return domain
        }
    }

    public static func set(
        _ setting: DomainListSetting, to domains: [String], database: ShifuDatabase
    ) throws {
        var seen: Set<String> = []
        let cleaned = domains.compactMap { entry -> String? in
            guard let domain = setting.normalize(entry), seen.insert(domain).inserted
            else { return nil }
            return domain
        }
        try set(setting.key, to: cleaned.joined(separator: "\n"), database: database)
    }

    /// Normalized to a known option, defaulted when missing or unrecognized.
    public static func value(_ setting: ChoiceSetting, database: ShifuDatabase) -> String {
        guard let raw = try? get(setting.key, database: database)
        else { return setting.defaultValue }
        return setting.normalize(raw)
    }

    public static func set(
        _ setting: ChoiceSetting, to value: String, database: ShifuDatabase
    ) throws {
        try set(setting.key, to: setting.normalize(value), database: database)
    }

    /// Trimmed; empty string when unset.
    public static func value(_ setting: TextSetting, database: ShifuDatabase) -> String {
        ((try? get(setting.key, database: database)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func set(
        _ setting: TextSetting, to value: String, database: ShifuDatabase
    ) throws {
        try set(setting.key, to: value.trimmingCharacters(in: .whitespacesAndNewlines),
                database: database)
    }
}
