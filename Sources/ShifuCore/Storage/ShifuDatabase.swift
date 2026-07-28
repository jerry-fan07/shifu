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
    /// Analysis backend: "auto" (Foundation Models if available, else rules-only),
    /// "claude" (opt-in cloud, analyzer-only), "openai" (opt-in cloud,
    /// OpenAI-compatible endpoint — DeepSeek by default), "off" (rules-only).
    public static let analysisBackendKey = "analysis.backend"
    public static let claudeAPIKeyKey = "claude.api_key"
    public static let openAIAPIKeyKey = "openai.api_key"
    public static let openAIBaseURLKey = "openai.base_url"
    public static let openAIModelKey = "openai.model"
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
