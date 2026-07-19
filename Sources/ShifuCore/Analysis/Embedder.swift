import Foundation
import NaturalLanguage

/// On-device text embedding behind a protocol (vault-features.md §5), so the
/// merge suggester is testable with a deterministic stub and degrades to a
/// no-op when no embedder is available (nil vectors — never an error branch).
public protocol Embedder: Sendable {
    /// Unit-norm embedding, or nil when the text can't be embedded.
    func embed(_ text: String) -> [Float]?
}

/// NLEmbedding-backed sentence embedder (NaturalLanguage framework — no model
/// download, no network). Nil at init when the OS has no sentence model.
public final class SentenceEmbedder: Embedder, @unchecked Sendable {
    private let embedding: NLEmbedding
    private let lock = NSLock()  // NLEmbedding is not documented thread-safe

    public init?() {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        self.embedding = embedding
    }

    public func embed(_ text: String) -> [Float]? {
        let vector = lock.withLock { embedding.vector(for: text.lowercased()) }
        guard let vector else { return nil }
        return EmbedMath.normalize(vector.map(Float.init))
    }
}

/// Pure vector helpers shared by the suggester (and V4's hybrid search).
public enum EmbedMath {
    /// Unit-normalized copy, or nil for a zero vector.
    public static func normalize(_ vector: [Float]) -> [Float]? {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }

    /// Dot product — cosine similarity when both inputs are unit-norm.
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return 0 }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Unit-normalized mean of unit vectors; nil when the input is empty or
    /// degenerate.
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            for index in vector.indices { sum[index] += vector[index] }
        }
        return normalize(sum)
    }
}
