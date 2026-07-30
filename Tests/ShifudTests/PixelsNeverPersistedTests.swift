import CoreGraphics
import Foundation
import GRDB
import ShifuCore
import Testing
@testable import shifud

/// Invariant 4 (CLAUDE.md, design.md §3.2): **pixels are never persisted.**
/// The screenshot exists only for the length of the OCR call.
///
/// ARCHITECTURE.md §5 recorded this as "structural only — no automated guard".
/// It cannot be tested by driving the daemon — the guarantee is about what a
/// type is *able* to carry, not about one run's behavior — so it is asserted
/// two ways instead: nothing image-shaped can leave the OCR rung, and nothing
/// image-shaped can be stored if it did.
@Suite struct PixelsNeverPersistedTests {
    @Test func theOCRRungReturnsTextAndAHashAndNothingElse() {
        let result = OCRCapture.Result(text: "hello", dhash: 0)
        let fields = Mirror(reflecting: result).children.map {
            ($0.label ?? "", type(of: $0.value))
        }

        // A `CGImage` (or any reference type) added here would be a bitmap
        // escaping the function that captured it.
        #expect(fields.count == 2)
        #expect(fields.contains { $0.0 == "text" && $0.1 == String.self })
        #expect(fields.contains { $0.0 == "dhash" && $0.1 == UInt64.self })
    }

    @Test func nothingTheRecorderAcceptsCanCarryABitmap() {
        let candidate = ObservationRecorder.Candidate(
            timestamp: 0, appBundle: "com.example.app", captureKind: .ocr, text: "read text")
        for child in Mirror(reflecting: candidate).children {
            let described = String(describing: type(of: child.value))
            #expect(!described.contains("CGImage"), "\(child.label ?? "?") carries pixels")
            #expect(!described.contains("Data"), "\(child.label ?? "?") could carry pixels")
        }
    }

    @Test func theObservationsTableHasNoColumnAnImageCouldFitIn() throws {
        let database = try ShifuDatabase.inMemory()
        let columns = try database.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(observations)")
        }
        #expect(!columns.isEmpty)
        for column in columns {
            let type = (column["type"] as String).uppercased()
            #expect(!type.contains("BLOB"),
                    "observations.\(column["name"] as String) is a BLOB")
        }
    }

    /// The dHash is 64 bits of an 8×8 luminance reduction — a perceptual
    /// fingerprint, not a thumbnail. It has to stay too small to reconstruct
    /// anything from, which is what makes storing it different from storing
    /// pixels.
    @Test func theStoredHashIsSixtyFourBitsOfAnEightByEightReduction() {
        let gradient = (0..<(9 * 8)).map { UInt8(($0 % 9) * 28) }
        let hash = DHash.hash(luminance: gradient)
        #expect(MemoryLayout.size(ofValue: hash) == 8)
    }
}
