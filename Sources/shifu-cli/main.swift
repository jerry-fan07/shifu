import Foundation
import GRDB
import ShifuCore

// shifu — CLI (implementation.md Phase 1 item 8). Reads the same DB and
// control files as the daemon; no IPC needed.

let usage = """
usage: shifu <command>
  log [days]     observations (default: today)
  status         daemon pause state and today's counts
  pause [dur]    pause capture: 30m, 1h (default), 2h, tomorrow
  resume         resume capture
  work on|off    toggle Work Mode (focus contract with glow nudges)
  review         spaced-repetition session over due vault notes
  forget last <2h|1d> | app <bundle-id> | all --yes
                 delete captured data (range, per-app, or everything)
"""

func openDatabase() throws -> ShifuDatabase {
    try ShifuDatabase(at: ShifuPaths.database)
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
        print("db: \(String(format: "%.1f", Double(size) / 1_048_576)) MB at \(ShifuPaths.database.path)")
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
        guard let spec = arguments.dropFirst().first, spec.count >= 2,
              let amount = Double(spec.dropLast()) else {
            print("usage: shifu forget last <2h|30m|1d>")
            exit(1)
        }
        let unit: TimeInterval
        switch spec.last {
        case "m": unit = 60
        case "h": unit = 3_600
        case "d": unit = 86_400
        default:
            print("unknown unit '\(spec.last!)' — use m, h, or d")
            exit(1)
        }
        let counts = try DeletionTools.forgetRange(
            database: try openDatabase(),
            from: Date().addingTimeInterval(-amount * unit), to: Date())
        print("forgot last \(spec): \(counts.observations) observations, \(counts.activities) activities")
    default:
        print("usage: shifu forget last <2h|1d> | app <bundle-id> | all --yes")
    }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "log":
    let days = args.dropFirst().first.flatMap(Int.init) ?? 1
    try commandLog(days: days)
case "status":
    try commandStatus()
case "pause":
    try commandPause(args.dropFirst().first ?? "1h")
case "resume":
    try commandResume()
case "review":
    try commandReview()
case "forget":
    try commandForget(Array(args.dropFirst()))
case "work":
    switch args.dropFirst().first {
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
case "--version":
    print("shifu \(Shifu.version)")
default:
    print(usage)
}
