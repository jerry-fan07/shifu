import Foundation
import GRDB
import ShifuCore

// shifu — CLI (implementation.md Phase 1 item 8). Reads the same DB and
// control files as the daemon; no IPC needed.

let usage = """
usage: shifu <command>
  log [days]     observations (default: today)
  log export [days]
                 write full logs, including captured text, to
                 ~/Shifu/logs/log-<date>.md (one file per day)
  status         daemon pause state and today's counts
  pause [dur]    pause capture: 30m, 1h (default), 2h, tomorrow
  resume         resume capture
  work on|off    toggle Work Mode (focus contract with glow nudges)
  review         spaced-repetition session over due vault notes
  forget last <2h|1d> | app <bundle-id> | all --yes
                 delete captured data (range, per-app, or everything)
  vault search <query> [--task <name>] [--project <name>] [--kind <kind>] [--since <7d>]
                 full-text search over the vault
  vault reindex  rebuild the vault search index from the Markdown files
  encrypt        encrypt the database with SQLCipher (key in Keychain)
"""

func openDatabase() throws -> ShifuDatabase {
    try ShifuDatabase.open(at: ShifuPaths.database)
}

func startOfToday() -> Int64 {
    Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
}

func formatClock(_ unixMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(unixMs) / 1_000)
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

func formatDuration(_ ms: Int64) -> String {
    let seconds = ms / 1_000
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return "\(seconds / 60)m\(seconds % 60 == 0 ? "" : "\(seconds % 60)s")" }
    return "\(seconds / 3_600)h\((seconds % 3_600) / 60)m"
}

func commandLog(days: Int) throws {
    let db = try openDatabase()
    let since = days <= 1
        ? startOfToday()
        : startOfToday() - Int64(days - 1) * 86_400_000
    let observations = try db.queue.read { sqlite in
        try Observation
            .filter(Column("last_seen") >= since)
            .order(Column("started_at"))
            .fetchAll(sqlite)
    }
    guard !observations.isEmpty else {
        print("no observations since \(formatClock(since)) — is shifud running?")
        return
    }
    for obs in observations {
        let duration = formatDuration(obs.lastSeen - obs.startedAt)
        let app = obs.appBundle.split(separator: ".").last.map(String.init) ?? obs.appBundle
        var line = "\(formatClock(obs.startedAt))  \(duration.padding(toLength: 7, withPad: " ", startingAt: 0))"
        line += " \(obs.captureKind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
        line += " \(app)"
        if let title = obs.windowTitle, !title.isEmpty {
            line += " — \(title.prefix(60))"
        }
        if let url = obs.url {
            line += "  <\(url.prefix(60))>"
        }
        if let text = obs.text {
            line += "  [\(text.utf8.count) B text]"
        }
        print(line)
    }
    print("\n\(observations.count) observations")
}

func commandLogExport(days: Int) throws {
    let db = try openDatabase()
    let since = days <= 1
        ? startOfToday()
        : startOfToday() - Int64(days - 1) * 86_400_000
    let observations = try db.queue.read { sqlite in
        try Observation
            .filter(Column("last_seen") >= since)
            .order(Column("started_at"))
            .fetchAll(sqlite)
    }
    guard !observations.isEmpty else {
        print("no observations since \(formatClock(since)) — nothing to export")
        return
    }

    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let byDay = Dictionary(grouping: observations) { obs in
        dayFormatter.string(from: Date(timeIntervalSince1970: Double(obs.startedAt) / 1_000))
    }

    try FileManager.default.createDirectory(
        at: ShifuPaths.logs, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )

    for (day, dayObservations) in byDay.sorted(by: { $0.key < $1.key }) {
        var doc = "# Shifu log — \(day)\n"
        for obs in dayObservations {
            let duration = formatDuration(obs.lastSeen - obs.startedAt)
            doc += "\n## \(formatClock(obs.startedAt)) — \(obs.appBundle)\n"
            doc += "- kind: \(obs.captureKind.rawValue) · duration: \(duration)\n"
            if let title = obs.windowTitle, !title.isEmpty {
                doc += "- title: \(title)\n"
            }
            if let url = obs.url {
                doc += "- url: \(url)\n"
            }
            if let text = obs.text, !text.isEmpty {
                doc += "\n\(fencedBlock(text))\n"
            }
        }
        let file = ShifuPaths.logs.appendingPathComponent("log-\(day).md")
        try doc.write(to: file, atomically: true, encoding: .utf8)
        print("wrote \(file.path) (\(dayObservations.count) observations)")
    }
}

/// Wrap text in a code fence longer than any backtick run it contains,
/// so captured content can never break out of the block.
func fencedBlock(_ text: String) -> String {
    var longestRun = 0
    var currentRun = 0
    for character in text {
        currentRun = character == "`" ? currentRun + 1 : 0
        longestRun = max(longestRun, currentRun)
    }
    let fence = String(repeating: "`", count: max(3, longestRun + 1))
    return "\(fence)text\n\(text)\n\(fence)"
}

func commandStatus() throws {
    if let raw = try? String(contentsOf: ShifuPaths.pauseFile, encoding: .utf8),
       let expiry = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
       Date(timeIntervalSince1970: expiry) > Date() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        print("capture: PAUSED until \(formatter.string(from: Date(timeIntervalSince1970: expiry)))")
    } else {
        print("capture: active (if shifud is running)")
    }

    if FileManager.default.fileExists(atPath: ShifuPaths.workModeFile.path) {
        print("work mode: ON")
    }

    let db = try openDatabase()
    let since = startOfToday()
    let counts = try db.queue.read { sqlite in
        try Row.fetchAll(sqlite, sql: """
            SELECT capture_kind, COUNT(*) AS n FROM observations
            WHERE last_seen >= ? GROUP BY capture_kind ORDER BY n DESC
            """, arguments: [since])
    }
    if counts.isEmpty {
        print("today: no observations")
    } else {
        let parts = counts.map { "\($0["n"] as Int64) \($0["capture_kind"] as String)" }
        print("today: \(parts.joined(separator: ", "))")
    }
    if let size = try? FileManager.default.attributesOfItem(atPath: ShifuPaths.database.path)[.size] as? Int64 {
        let encryption = ShifuDatabase.isEncrypted(at: ShifuPaths.database)
            ? "encrypted" : "plaintext"
        print("db: \(String(format: "%.1f", Double(size) / 1_048_576)) MB, \(encryption), "
            + "at \(ShifuPaths.database.path)")
    }
}

func commandPause(_ spec: String) throws {
    let seconds: TimeInterval
    switch spec {
    case "30m": seconds = 1_800
    case "1h": seconds = 3_600
    case "2h": seconds = 7_200
    case "tomorrow":
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        seconds = tomorrow.timeIntervalSinceNow
    default:
        print("unknown duration '\(spec)' — use 30m, 1h, 2h, or tomorrow")
        exit(1)
    }
    try ShifuPaths.ensureHomeExists()
    let expiry = Date().addingTimeInterval(seconds).timeIntervalSince1970
    try String(Int(expiry)).write(to: ShifuPaths.pauseFile, atomically: true, encoding: .utf8)
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    print("paused until \(formatter.string(from: Date(timeIntervalSince1970: expiry)))")
}

func commandResume() throws {
    try? FileManager.default.removeItem(at: ShifuPaths.pauseFile)
    // Touch the directory so the daemon's watcher re-evaluates immediately.
    print("resumed")
}

func commandReview() throws {
    let vault = VaultStore(database: try openDatabase())
    let due = try vault.due()
    guard !due.isEmpty else {
        print("nothing due — come back tomorrow")
        return
    }
    print("\(due.count) due · grade with 1=again 2=hard 3=good 4=easy · q quits\n")
    var done = 0
    for note in due {
        guard let qa = note.questionAnswer else { continue }
        print("— \(note.topic)")
        print("Q: \(qa.question)")
        print("  [enter to reveal] ", terminator: "")
        guard readLine() != nil else { break }
        print("A: \(qa.answer)")
        var graded = false
        while !graded {
            print("  grade [1-4, q]: ", terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else { return }
            if input == "q" {
                print("\nreviewed \(done)/\(due.count)")
                return
            }
            if let raw = Int(input), let grade = FSRS.Grade(rawValue: raw) {
                let updated = try vault.review(note, grade: grade)
                if let days = updated.srs?.intervalDays {
                    print("  next: \(days == 0 ? "today" : "in \(Int(days))d")\n")
                }
                done += 1
                graded = true
            }
        }
    }
    print("done — \(done) reviewed 🎉")
}

func parseForgetRangeSpec(_ spec: String) -> TimeInterval? {
    guard spec.count >= 2, let amount = Double(spec.dropLast()) else { return nil }
    let unit: TimeInterval
    switch spec.last {
    case "m": unit = 60
    case "h": unit = 3_600
    case "d": unit = 86_400
    default: return nil
    }
    return amount * unit
}

func commandForget(_ arguments: [String]) throws {
    switch arguments.first {
    case "all":
        guard arguments.contains("--yes") else {
            print("this deletes the database, vault, and digests. Re-run with --yes to confirm.")
            exit(1)
        }
        try DeletionTools.deleteEverything()
        print("all Shifu data deleted")
    case "app":
        guard let bundle = arguments.dropFirst().first else {
            print("usage: shifu forget app <bundle-id>")
            exit(1)
        }
        let counts = try DeletionTools.purgeApp(database: try openDatabase(), bundleID: bundle)
        print("purged \(bundle): \(counts.observations) observations, \(counts.activities) activities")
    case "last":
        guard let spec = arguments.dropFirst().first,
              let interval = parseForgetRangeSpec(spec) else {
            print("usage: shifu forget last <2h|30m|1d>")
            exit(1)
        }
        let database = try openDatabase()
        let counts = try DeletionTools.forgetRange(
            database: database,
            from: Date().addingTimeInterval(-interval), to: Date(),
            vault: VaultStore(database: database))
        print("forgot last \(spec): \(counts.observations) observations, \(counts.activities) activities")
    default:
        print("usage: shifu forget last <2h|1d> | app <bundle-id> | all --yes")
    }
}

struct VaultSearchOptions {
    var query: [String] = []
    var kind: FrontMatter.Kind?
    var taskID: Int64?
    var projectID: Int64?
    var since: Date?
}

/// Parses `vault search` flags; prints a hint and exits on a bad flag value.
func parseVaultSearchOptions(_ arguments: [String], db: ShifuDatabase) throws -> VaultSearchOptions {
    var options = VaultSearchOptions()
    var rest = arguments.makeIterator()
    while let arg = rest.next() {
        switch arg {
        case "--kind":
            guard let value = rest.next().flatMap(FrontMatter.Kind.init(rawValue:)) else {
                print("--kind takes knowledge, work, or project")
                exit(1)
            }
            options.kind = value
        case "--task":
            guard let name = rest.next(), let id = try db.queue.read({ sqlite in
                try Int64.fetchOne(sqlite, sql:
                    "SELECT id FROM tasks WHERE name = ? COLLATE NOCASE OR key = ?",
                    arguments: [name, name])
            }) else {
                print("no task named that — see the Vault tab for names")
                exit(1)
            }
            options.taskID = id
        case "--project":
            guard let name = rest.next(), let id = try db.queue.read({ sqlite in
                try Int64.fetchOne(sqlite, sql:
                    "SELECT id FROM projects WHERE name = ? COLLATE NOCASE",
                    arguments: [name])
            }) else {
                print("no project named that")
                exit(1)
            }
            options.projectID = id
        case "--since":
            guard let spec = rest.next(), let interval = parseForgetRangeSpec(spec) else {
                print("--since takes a range like 2h, 7d")
                exit(1)
            }
            options.since = Date().addingTimeInterval(-interval)
        default:
            options.query.append(arg)
        }
    }
    return options
}

func commandVaultSearch(_ arguments: [String], db: ShifuDatabase) throws {
    let options = try parseVaultSearchOptions(arguments, db: db)
    guard !options.query.isEmpty else {
        print("usage: shifu vault search <query> [--task] [--project] [--kind] [--since]")
        exit(1)
    }
    let hits = try VaultSearch.search(
        options.query.joined(separator: " "), kind: options.kind, taskID: options.taskID,
        projectID: options.projectID, since: options.since, database: db)
    guard !hits.isEmpty else {
        print("no matches")
        return
    }
    for (rank, hit) in hits.enumerated() {
        print("\(rank + 1). \(hit.title)")
        print("   \(hit.snippet.replacingOccurrences(of: "\n", with: " "))")
        print("   \(ShifuPaths.vault.appendingPathComponent(hit.path).path)")
    }
}

func commandVault(_ arguments: [String]) throws {
    let db = try openDatabase()
    switch arguments.first {
    case "reindex":
        let summary = try VaultIndexer.reconcile(root: ShifuPaths.vault, database: db)
        print("reindexed: \(summary.indexed) updated, \(summary.removed) removed, "
            + "\(summary.unchanged) unchanged")
    case "search":
        try commandVaultSearch(Array(arguments.dropFirst()), db: db)
    case "bench":
        // Perf-harness hook (vault-features.md §V8), not user-facing: build a
        // synthetic vault under SHIFU_HOME, then time a no-change reconcile
        // and one search. scripts/perf-vault.sh parses and asserts budgets.
        let count = arguments.dropFirst().first.flatMap(Int.init) ?? 10_000
        try commandVaultBench(count: count, db: db)
    default:
        print("usage: shifu vault search <query> … | reindex")
    }
}

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
    print("vault bench: \(count) notes, initial \(Int(initialMs)) ms, "
        + "reconcile \(Int(reconcileMs)) ms, search \(String(format: "%.1f", searchMs)) ms "
        + "(\(hitCount) hits)")
}

func commandEncrypt() throws {
    guard FileManager.default.fileExists(atPath: ShifuPaths.database.path) else {
        print("no database yet — it will be created encrypted once a key exists.")
        _ = try DatabaseKey.getOrCreate()
        print("key stored in Keychain; the next daemon start creates an encrypted database")
        return
    }
    guard !ShifuDatabase.isEncrypted(at: ShifuPaths.database) else {
        print("database is already encrypted")
        return
    }
    print("""
    stop the daemon first so nothing writes during migration:
      launchctl bootout gui/$(id -u)/com.shifu.shifud   (restart it afterwards)
    encrypting…
    """)
    let passphrase = try DatabaseKey.getOrCreate()
    try EncryptionMigrator.encrypt(at: ShifuPaths.database, passphrase: passphrase)
    if ProcessInfo.processInfo.environment[DatabaseKey.envVar] != nil {
        print("done — database is SQLCipher-encrypted with the \(DatabaseKey.envVar) key")
    } else {
        print("done — database is SQLCipher-encrypted, key is in your login Keychain")
        print("note: unsigned binaries each prompt once for Keychain access; sign them to share silently")
    }
}

let args = CommandLine.arguments.dropFirst()
func commandWork(_ toggle: String?) throws {
    switch toggle {
    case "on":
        try ShifuPaths.ensureHomeExists()
        try Data().write(to: ShifuPaths.workModeFile)
        print("work mode on")
    case "off":
        try? FileManager.default.removeItem(at: ShifuPaths.workModeFile)
        print("work mode off")
    default:
        let on = FileManager.default.fileExists(atPath: ShifuPaths.workModeFile.path)
        print("work mode: \(on ? "ON" : "off")")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("shifu: \(error)\n".utf8))
    exit(1)
}

func run() throws {
    let commands: [String: () throws -> Void] = [
        "log": {
            let rest = args.dropFirst()
            if rest.first == "export" {
                try commandLogExport(days: rest.dropFirst().first.flatMap(Int.init) ?? 1)
            } else {
                try commandLog(days: rest.first.flatMap(Int.init) ?? 1)
            }
        },
        "status": commandStatus,
        "pause": { try commandPause(args.dropFirst().first ?? "1h") },
        "resume": commandResume,
        "review": commandReview,
        "forget": { try commandForget(Array(args.dropFirst())) },
        "vault": { try commandVault(Array(args.dropFirst())) },
        "encrypt": commandEncrypt,
        "work": { try commandWork(args.dropFirst().first) },
        "--version": { print("shifu \(Shifu.version)") }
    ]
    guard let name = args.first, let command = commands[name] else {
        print(usage)
        return
    }
    try command()
}
