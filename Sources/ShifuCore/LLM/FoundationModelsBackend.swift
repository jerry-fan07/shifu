import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Foundation Models backend (design.md §4.2 tier 2).
/// Zero bundle cost; available on macOS 26+ with Apple Intelligence enabled.
public struct FoundationModelsBackend: LLMBackend {
    public let name = "foundation-models"

    public init() {}

    /// Nil when the OS or hardware can't provide the system model.
    public static func ifAvailable() -> FoundationModelsBackend? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            return FoundationModelsBackend()
        }
        #endif
        return nil
    }

    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession()
            let options = GenerationOptions(maximumResponseTokens: maxTokens)
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        }
        #endif
        throw LLMError.unavailable("FoundationModels requires macOS 26+")
    }
}
