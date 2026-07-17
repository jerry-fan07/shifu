import Foundation

/// Regex redaction pass over all extracted text — the single choke point
/// before anything touches disk (design.md §8, CLAUDE.md invariant 2).
public enum Redactor {
    /// Patterns applied in order. PEM blocks first so their contents can't
    /// partially match later patterns.
    private static let patterns: [(regex: NSRegularExpression, replacement: String)] = {
        func re(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants; a failure here is a programmer error.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [])
        }
        return [
            // PEM private key / certificate blocks
            (re(#"-----BEGIN[ A-Z]{0,40}-----[\s\S]*?(?:-----END[ A-Z]{0,40}-----|\z)"#),
             "[REDACTED:PEM]"),
            // JWTs (three base64url segments starting with eyJ)
            (re(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\b"#),
             "[REDACTED:JWT]"),
            // AWS access key IDs
            (re(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
             "[REDACTED:KEY]"),
            // Other long secret-looking tokens with well-known prefixes
            (re(#"\b(?:sk-|ghp_|gho_|github_pat_|xoxb-|xoxp-|glpat-)[A-Za-z0-9_-]{10,}\b"#),
             "[REDACTED:KEY]"),
            // US SSNs
            (re(#"\b\d{3}-\d{2}-\d{4}\b"#),
             "[REDACTED:SSN]"),
            // Payment card numbers: 13–19 digits, optionally space/dash separated
            (re(#"\b(?:\d[ -]?){12,18}\d\b"#),
             "[REDACTED:CARD]"),
        ]
    }()

    /// Returns the text with all sensitive matches replaced. Card matches are
    /// Luhn-checked to avoid eating ordinary long numbers.
    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, replacement) in patterns {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            // Replace back-to-front so earlier ranges stay valid.
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                if replacement == "[REDACTED:CARD]" && !passesLuhn(String(result[range])) {
                    continue
                }
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    static func passesLuhn(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
