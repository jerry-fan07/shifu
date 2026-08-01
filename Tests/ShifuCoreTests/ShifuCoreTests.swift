import Testing
@testable import ShifuCore

/// The test runner is not the app bundle, so this exercises the fallback: if the
/// identifier guard is ever dropped we would report the test host's version here
/// instead, which is exactly the drift the bundle lookup exists to prevent.
@Test func versionIsSet() {
    #expect(!Shifu.version.isEmpty)
    #expect(Shifu.version == Shifu.fallbackVersion)
}
