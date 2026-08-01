import Foundation
import Testing
@testable import shifu_analyzer

/// The launch line the bundled server gets (design.md §4.2) — pinned so the
/// measured profile can't drift out from under the spike that justified it.
@Suite struct LlamaServerTests {
    @Test func launchLineIsTheMeasuredProfile() {
        let arguments = LlamaServer.arguments(
            weightsPath: "/tmp/model.gguf", contextTokens: 16_000)
        // The window every stage sizes its batches to (invariant 7) is the
        // window the server actually serves.
        #expect(arguments.contains("-c"))
        #expect(arguments[arguments.firstIndex(of: "-c")! + 1] == "16000")
        #expect(arguments[arguments.firstIndex(of: "-m")! + 1] == "/tmp/model.gguf")
        // Loopback only — this server exists for one local caller.
        #expect(arguments[arguments.firstIndex(of: "--host")! + 1] == "127.0.0.1")
        #expect(arguments[arguments.firstIndex(of: "--port")! + 1] == "8080")
        // One sequential caller, whole window per request.
        #expect(arguments[arguments.firstIndex(of: "--parallel")! + 1] == "1")
        // The small prefill bursts design.md prescribes for power draw.
        #expect(arguments[arguments.firstIndex(of: "-ub")! + 1] == "256")
        #expect(arguments[arguments.firstIndex(of: "-b")! + 1] == "512")
        #expect(arguments.contains("--no-webui"))
    }
}
