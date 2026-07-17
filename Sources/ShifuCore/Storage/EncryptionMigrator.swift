import Foundation
import GRDB

/// One-way migration of a plaintext database to SQLCipher (design.md §8).
/// Uses `sqlcipher_export` into a sibling file, verifies, then swaps —
/// the plaintext original is securely removed on success.
public enum EncryptionMigrator {
    public enum MigrationError: Error, CustomStringConvertible {
        case alreadyEncrypted
        case noDatabase
        case verificationFailed(String)

        public var description: String {
            switch self {
            case .alreadyEncrypted: return "database is already encrypted"
            case .noDatabase: return "no database file to encrypt"
            case .verificationFailed(let why): return "encrypted copy failed verification: \(why)"
            }
        }
    }

    public static func encrypt(at url: URL, passphrase: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MigrationError.noDatabase
        }
        guard !ShifuDatabase.isEncrypted(at: url) else {
            throw MigrationError.alreadyEncrypted
        }

        let target = URL(fileURLWithPath: url.path + ".encrypting")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: target.path + suffix)
        }

        // Export via SQLCipher's canonical path. Opening the plaintext side
        // also checkpoints its WAL so the export sees every committed row.
        let plain = try DatabaseQueue(path: url.path)
        try plain.inDatabase { db in
            try db.execute(literal: """
                ATTACH DATABASE \(target.path) AS encrypted KEY \(passphrase)
                """)
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
        }

        // Verify the encrypted copy is complete before touching the original.
        let check = try ShifuDatabase(at: target, passphrase: passphrase)
        let originalCount = try plain.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observations") ?? 0
        }
        let copiedCount = try check.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observations") ?? 0
        }
        try check.queue.close()
        try plain.close()
        guard copiedCount == originalCount else {
            throw MigrationError.verificationFailed(
                "\(copiedCount) observations copied, expected \(originalCount)")
        }

        // Swap: plaintext (and its WAL/SHM) out, encrypted file in.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        try FileManager.default.moveItem(at: target, to: url)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: target.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try FileManager.default.moveItem(
                    at: side, to: URL(fileURLWithPath: url.path + suffix))
            }
        }
    }
}
