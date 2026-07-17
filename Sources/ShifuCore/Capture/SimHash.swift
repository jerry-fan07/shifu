/// 64-bit SimHash over text tokens, used to detect near-duplicate observations
/// of the same window (design.md §3.3). Stable screens cost one row.
public enum SimHash {
    /// Computes a 64-bit SimHash of the text. Empty/whitespace-only text hashes to 0.
    public static func hash(_ text: String) -> UInt64 {
        var votes = [Int](repeating: 0, count: 64)
        var tokenCount = 0
        for token in tokens(of: text) {
            tokenCount += 1
            let tokenHash = fnv1a(token)
            for bit in 0..<64 {
                votes[bit] += (tokenHash >> UInt64(bit)) & 1 == 1 ? 1 : -1
            }
        }
        guard tokenCount > 0 else { return 0 }
        var result: UInt64 = 0
        for bit in 0..<64 where votes[bit] > 0 {
            result |= 1 << UInt64(bit)
        }
        return result
    }

    public static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Near-duplicate threshold: ≤ this many differing bits means "same content".
    public static let nearDuplicateThreshold = 3

    public static func isNearDuplicate(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        hammingDistance(lhs, rhs) <= nearDuplicateThreshold
    }

    private static func tokens(of text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { Substring($0) }
    }

    private static func fnv1a(_ token: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
