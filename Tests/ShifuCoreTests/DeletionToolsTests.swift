import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct DeletionToolsTests {
    private func seeded() throws -> ShifuDatabase {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            var obs1 = Observation(startedAt: 1_000, appBundle: "com.a", captureKind: .ax, text: "x")
            var obs2 = Observation(startedAt: 500_000, appBundle: "com.b", captureKind: .ax, text: "y")
            try obs1.insert(sqlite); try obs2.insert(sqlite)
            var act1 = Activity(startedAt: 1_000, endedAt: 60_000, appBundle: "com.a", category: .work)
            var act2 = Activity(startedAt: 500_000, endedAt: 560_000, appBundle: "com.b", category: .social)
            try act1.insert(sqlite); try act2.insert(sqlite)
        }
        return db
    }

    @Test func forgetRangeRemovesRawAndDerived() throws {
        let db = try seeded()
        let counts = try DeletionTools.forgetRange(
            database: db,
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 100))
        #expect(counts == .init(observations: 1, activities: 1))
        let remaining = try db.queue.read { try Observation.fetchAll($0) }
        #expect(remaining.map(\.appBundle) == ["com.b"])
    }

    @Test func purgeAppRemovesOnlyThatBundle() throws {
        let db = try seeded()
        let counts = try DeletionTools.purgeApp(database: db, bundleID: "com.b")
        #expect(counts == .init(observations: 1, activities: 1))
        let observations = try db.queue.read { try Observation.fetchAll($0) }
        let activities = try db.queue.read { try Activity.fetchAll($0) }
        #expect(observations.map(\.appBundle) == ["com.a"])
        #expect(activities.map(\.appBundle) == ["com.a"])
    }

    @Test func deleteEverythingSparesBinaries() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-delete-test-\(UUID().uuidString)")
        for sub in ["vault/2026", "digests", "bin"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("db".utf8).write(to: home.appendingPathComponent("shifu.db"))
        try Data("d".utf8).write(to: home.appendingPathComponent("bin/shifud"))
        defer { try? FileManager.default.removeItem(at: home) }

        try DeletionTools.deleteEverything(home: home)
        let left = try FileManager.default.contentsOfDirectory(atPath: home.path)
        #expect(left == ["bin"])
    }
}

@Suite struct CorruptionRotationTests {
    @Test func corruptFileIsRotatedAsideAndFreshDBOpens() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-corrupt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shifu.db")
        try Data("this is not a sqlite database, not even close".utf8).write(to: url)

        let (db, rotated) = try ShifuDatabase.openRotatingOnCorruption(at: url)
        #expect(rotated != nil)
        #expect(FileManager.default.fileExists(atPath: rotated!.path))
        // The fresh database is usable.
        let count = try db.queue.read { try Observation.fetchCount($0) }
        #expect(count == 0)
    }
}
