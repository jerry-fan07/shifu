import Foundation
import Testing
@testable import ShifuCore

/// Control files are toggled by create/delete, and the daemon's directory
/// watcher is edge-triggered while its handler samples state when it runs. A
/// plain `fileExists` check therefore cannot see an off→on that completes
/// between two handler runs. These tests pin the identity comparison that can.
@Suite struct ControlFileTokenTests {
    private func scratchDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("token-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func missingFileHasNoToken() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ControlFileToken(at: dir.appendingPathComponent("absent")) == nil)
    }

    @Test func sameFileKeepsTheSameToken() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("focus_mode")
        try Data().write(to: file)
        #expect(ControlFileToken(at: file) == ControlFileToken(at: file))
    }

    /// The regression this type exists for: delete + recreate with no delay is
    /// exactly what `shifu focus off && shifu focus on` does. `fileExists` reports
    /// true both before and after, so only the token distinguishes them.
    @Test func recreatedFileGetsADifferentToken() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("focus_mode")

        try Data().write(to: file)
        let before = ControlFileToken(at: file)

        try FileManager.default.removeItem(at: file)
        try Data().write(to: file)
        let after = ControlFileToken(at: file)

        #expect(before != nil)
        #expect(after != nil)
        #expect(before != after, "a recreated control file must read as a new session")
        // The check the old boolean logic did, showing why it missed this.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deletingTheFileClearsTheToken() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("focus_mode")
        try Data().write(to: file)
        #expect(ControlFileToken(at: file) != nil)
        try FileManager.default.removeItem(at: file)
        #expect(ControlFileToken(at: file) == nil)
    }
}
