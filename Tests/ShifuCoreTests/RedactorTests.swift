import Testing
@testable import ShifuCore

@Suite struct RedactorTests {
    @Test func redactsCreditCard() {
        let redacted = Redactor.redact("pay with 4111 1111 1111 1111 today")
        #expect(redacted == "pay with [REDACTED:CARD] today")
    }

    @Test func redactsDashedCard() {
        #expect(Redactor.redact("4111-1111-1111-1111") == "[REDACTED:CARD]")
    }

    @Test func keepsNonLuhnNumbers() {
        // Order IDs, tracking numbers etc. that fail Luhn stay intact.
        let text = "order 1234 5678 9012 3456"
        #expect(Redactor.redact(text) == text)
    }

    @Test func redactsSSN() {
        #expect(Redactor.redact("ssn: 123-45-6789.") == "ssn: [REDACTED:SSN].")
    }

    @Test func redactsAWSKey() {
        #expect(Redactor.redact("key=AKIAIOSFODNN7EXAMPLE") == "key=[REDACTED:KEY]")
    }

    @Test func redactsTokenPrefixes() {
        #expect(Redactor.redact("ghp_abcdefghijklmnop123") == "[REDACTED:KEY]")
        #expect(Redactor.redact("sk-proj-abcdef1234567890") == "[REDACTED:KEY]")
    }

    @Test func redactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9P"
        #expect(Redactor.redact("token \(jwt) end") == "token [REDACTED:JWT] end")
    }

    @Test func redactsPEMBlock() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA7
        -----END RSA PRIVATE KEY-----
        """
        #expect(Redactor.redact("before\n\(pem)\nafter") == "before\n[REDACTED:PEM]\nafter")
    }

    @Test func redactsUnterminatedPEMBlock() {
        let redacted = Redactor.redact("x -----BEGIN PRIVATE KEY-----\nMIIEpAIBAAKCAQEA7")
        #expect(redacted == "x [REDACTED:PEM]")
    }

    @Test func plainTextUntouched() {
        let text = "Reading about SQLite WAL mode, phone 555-1234, year 2026."
        #expect(Redactor.redact(text) == text)
    }
}
