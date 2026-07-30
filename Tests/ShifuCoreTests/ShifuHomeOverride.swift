import Foundation

/// Test-only serialization for `SHIFU_HOME`.
///
/// The variable is process-global, and `@Suite(.serialized)` only orders one
/// suite's own cases — swift-testing still runs *different* suites in parallel.
/// So two suites that both move `SHIFU_HOME` will interleave: `ShifuPathsTests`
/// restoring the variable between `DigestGeneratorTests` writing a digest and
/// reading it back is enough to make the read find nothing, which surfaced as a
/// force-unwrap crash rather than a failed expectation.
///
/// Every test that moves the variable goes through here, so they take turns and
/// each one puts back whatever it found. Prefer *not* needing this at all —
/// `PauseFile`, `WorkModeFile` and `VaultStore(root:)` all take an explicit
/// directory precisely so a test can stay off the environment.
enum ShifuHomeOverride {
    private static let lock = NSLock()

    /// Runs `body` with `SHIFU_HOME` set to `path` — or unset, for `nil` — and
    /// restores the previous value afterwards. Serialized against every other
    /// caller, including on the throwing path.
    static func with<T>(_ path: String?, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = ProcessInfo.processInfo.environment["SHIFU_HOME"]
        defer {
            if let previous {
                setenv("SHIFU_HOME", previous, 1)
            } else {
                unsetenv("SHIFU_HOME")
            }
            lock.unlock()
        }
        if let path {
            setenv("SHIFU_HOME", path, 1)
        } else {
            unsetenv("SHIFU_HOME")
        }
        return try body()
    }
}
