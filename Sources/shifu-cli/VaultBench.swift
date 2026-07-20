import Foundation
import GRDB
import ShifuCore

// Perf-harness hook (vault-features.md §V8): `shifu vault bench <n>` builds a
// synthetic vault, then times reconcile and both search paths. Not
// user-facing; scripts/perf-vault.sh parses the printed line and asserts
// budgets. Kept out of main.swift to hold that file under the length limit.

func commandVaultBench(count: Int, db: ShifuDatabase) throws {
    let words = ["capture", "daemon", "sqlite", "swift", "vision", "ocr", "window",
                 "focus", "battery", "schedule", "index", "vault", "review", "fsrs",
                 "pattern", "digest", "session", "topic", "ledger", "radar"]
    try FileManager.default.createDirectory(at: ShifuPaths.vault, withIntermediateDirectories: true)
    var generator = SystemRandomNumberGenerator()
    for serial in 0..<count {
        let topic = "\(words[serial % words.count]) note \(serial)"
        var body = (0..<40).map { _ in words.randomElement(using: &generator) ?? "note" }
            .joined(separator: " ")
        if serial % 1_000 == 0 { body += " zanzibar" }   // rare term to search for
        let note = Note(topic: topic, state: .kept, body: body)
        let file = ShifuPaths.vault.appendingPathComponent("bench/\(note.id.lowercased()).md")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.serialize().write(to: file, atomically: true, encoding: .utf8)
    }

    func measureMs(_ block: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    let initialMs = try measureMs { try VaultIndexer.reconcile(root: ShifuPaths.vault, database: db) }
    let reconcileMs = try measureMs {
        let summary = try VaultIndexer.reconcile(root: ShifuPaths.vault, database: db)
        precondition(summary.indexed == 0 && summary.removed == 0, "bench vault changed underfoot")
    }
    var hitCount = 0
    let searchMs = try measureMs {
        hitCount = try VaultSearch.search("zanzibar", limit: 50, database: db).count
    }

    // Hybrid budget covers the query path (brute-force vector scan + RRF,
    // §V8) — synthetic unit vectors stand in for NLEmbedding output, whose
    // generation cost lives on the analyzer path, not the query path.
    let bench = BenchEmbedder()
    try db.queue.write { sqlite in
        for noteID in try String.fetchAll(sqlite, sql: "SELECT note_id FROM vault_index") {
            guard let vector = bench.embed(noteID) else { continue }
            try sqlite.execute(sql: """
                INSERT OR REPLACE INTO vault_vectors (note_id, embedding) VALUES (?, ?)
                """, arguments: [noteID, EmbedMath.blob(from: vector)])
        }
    }
    var hybridHits = 0
    let hybridMs = try measureMs {
        hybridHits = try VaultSearch.search(
            "zanzibar", limit: 50, database: db, embedder: bench).count
    }
    print("vault bench: \(count) notes, initial \(Int(initialMs)) ms, "
        + "reconcile \(Int(reconcileMs)) ms, search \(String(format: "%.1f", searchMs)) ms "
        + "(\(hitCount) hits), hybrid \(String(format: "%.1f", hybridMs)) ms "
        + "(\(hybridHits) hits)")
}

/// Deterministic pseudo-embedder for the bench: FNV-seeded splitmix values,
/// 512 dims — the scan cost is real even though the semantics aren't.
struct BenchEmbedder: Embedder {
    func embed(_ text: String) -> [Float]? {
        var state: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { state = (state ^ UInt64(byte)) &* 0x100000001b3 }
        var vector = [Float](repeating: 0, count: 512)
        for index in vector.indices {
            state = state &+ 0x9E3779B97F4A7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
            mixed ^= mixed >> 31
            vector[index] = Float(Int64(bitPattern: mixed) % 1_000) / 1_000
        }
        return EmbedMath.normalize(vector)
    }
}
