import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite(.serialized) struct EncryptionTests {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-cipher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func encryptedDatabaseRoundTrips() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shifu.db")

        let db = try ShifuDatabase(at: url, passphrase: "correct horse")
        try db.queue.write { sqlite in
            var obs = Observation(startedAt: 1_000, appBundle: "com.a",
                                  captureKind: .ax, text: "secret text")
            try obs.insert(sqlite)
        }
        try db.queue.close()

        // On-disk header is not plaintext SQLite, and the text isn't findable.
        #expect(ShifuDatabase.isEncrypted(at: url))
        let raw = try Data(contentsOf: url)
        #expect(String(bytes: raw, encoding: .utf8)?.contains("secret text") != true)

        // Correct key reopens; wrong key fails.
        let reopened = try ShifuDatabase(at: url, passphrase: "correct horse")
        let count = try reopened.queue.read { try Observation.fetchCount($0) }
        #expect(count == 1)
        try reopened.queue.close()
        #expect(throws: (any Error).self) {
            _ = try ShifuDatabase(at: url, passphrase: "wrong key")
        }
    }

    @Test func openUsesEnvKeyAndRefusesWithoutIt() throws {
        let dir = try scratchDir()
        defer {
            unsetenv(DatabaseKey.envVar)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("shifu.db")

        // With the env key set, a fresh open() creates an encrypted DB.
        setenv(DatabaseKey.envVar, "env-test-key", 1)
        let db = try ShifuDatabase.open(at: url)
        try db.queue.write { sqlite in
            var obs = Observation(startedAt: 1, appBundle: "com.a", captureKind: .meta)
            try obs.insert(sqlite)
        }
        try db.queue.close()
        #expect(ShifuDatabase.isEncrypted(at: url))

        // Without any key, plain open() reports missing-key loudly.
        unsetenv(DatabaseKey.envVar)
        #expect(throws: ShifuDatabase.OpenError.self) {
            _ = try ShifuDatabase.open(at: url)
        }

        // The daemon's rotating opener rotates the unreadable file aside
        // (renamed, never deleted) and continues with a fresh database.
        let (fresh, rotatedTo) = try ShifuDatabase.openRotatingOnCorruption(at: url)
        #expect(rotatedTo != nil)
        #expect(try fresh.queue.read { try Observation.fetchCount($0) } == 0)
        try fresh.queue.close()

        // The original encrypted data survives at the rotated path.
        setenv(DatabaseKey.envVar, "env-test-key", 1)
        let recovered = try ShifuDatabase(at: rotatedTo!, passphrase: "env-test-key")
        #expect(try recovered.queue.read { try Observation.fetchCount($0) } == 1)
        try recovered.queue.close()
    }

    @Test func migratorEncryptsInPlaceAndPreservesRows() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shifu.db")

        // Plaintext DB with content.
        let plain = try ShifuDatabase(at: url)
        try plain.queue.write { sqlite in
            for index in 0..<25 {
                var obs = Observation(startedAt: Int64(index), appBundle: "com.a",
                                      captureKind: .ax, text: "row \(index)")
                try obs.insert(sqlite)
            }
            var act = Activity(startedAt: 0, endedAt: 60_000, appBundle: "com.a", category: .work)
            try act.insert(sqlite)
        }
        try plain.queue.close()
        #expect(!ShifuDatabase.isEncrypted(at: url))

        try EncryptionMigrator.encrypt(at: url, passphrase: "migrate-key")

        #expect(ShifuDatabase.isEncrypted(at: url))
        let encrypted = try ShifuDatabase(at: url, passphrase: "migrate-key")
        #expect(try encrypted.queue.read { try Observation.fetchCount($0) } == 25)
        #expect(try encrypted.queue.read { try Activity.fetchCount($0) } == 1)
        try encrypted.queue.close()

        // Re-running is a no-op error, not data loss.
        #expect(throws: EncryptionMigrator.MigrationError.self) {
            try EncryptionMigrator.encrypt(at: url, passphrase: "migrate-key")
        }
    }
}
