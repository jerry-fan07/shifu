import Testing
@testable import ShifuCore

@Test func versionIsSet() {
    #expect(!Shifu.version.isEmpty)
}
