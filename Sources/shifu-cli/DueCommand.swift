import Foundation
import GRDB
import ShifuCore

// `shifu due` (design.md §4.5): the terminal half of deadlines — the surface
// that exists because the fastest way to record a promise is to type it where
// you already are. Kept out of main.swift to hold that file under the length
// limit, like VaultBench.swift.

func commandDue(_ arguments: [String]) throws {
    let db = try openDatabase()
    let verb = arguments.first ?? "list"
    switch verb {
    case "list", "--all":
        try dueList(all: arguments.contains("--all"), db: db)
    case "add":
        try dueAdd(Array(arguments.dropFirst()), db: db)
    case "set":
        try dueSet(Array(arguments.dropFirst()), db: db)
    case "done":
        try dueMark(Array(arguments.dropFirst()), done: true, db: db)
    case "open":
        try dueMark(Array(arguments.dropFirst()), done: false, db: db)
    case "rm":
        try dueRemove(Array(arguments.dropFirst()), db: db)
    default:
        print(dueUsage)
    }
}

let dueUsage = """
usage: shifu due [list|add|set|done|open|rm]
  due [--all]                 what is coming up (--all includes kept promises)
  due add "<title>" <when> [--task <id|name>] [--target <hours>]
  due set <id> [<when>] [--title <t>] [--task <id|name>] [--target <h>]
              [--no-task] [--no-target]
  due done <id>               mark it kept — goes quiet immediately
  due open <id>               reopen it
  due rm <id>                 forget it entirely

  <when>  2026-08-30 · 2026-08-30 17:00 · today · tomorrow · friday · +10d · +2w
  hours   20 · 20h · 90m — the effort you mean to put in, which is what turns
          logged time into progress you can be told about
"""

// MARK: - Reads

private func dueList(all: Bool, db: ShifuDatabase) throws {
    let standings = all
        ? try DeadlineStore.all(database: db)
        : try DeadlineStore.open(database: db)
    guard !standings.isEmpty else {
        print(all ? "no deadlines yet — `shifu due add` records one"
                  : "nothing coming up. `shifu due --all` includes kept promises")
        return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    for standing in standings {
        let id = standing.deadline.id.map(String.init) ?? "?"
        var line = "\(id.padding(toLength: 4, withPad: " ", startingAt: 0))"
        line += DeadlineCopy.summary(standing, now: now)
        if let task = standing.taskName { line += "  [\(task)]" }
        print(line)
    }
    let openCount = standings.filter { !$0.deadline.isDone }.count
    print("\n\(openCount) open" + (all ? " of \(standings.count)" : ""))
}

// MARK: - Writes

private func dueAdd(_ arguments: [String], db: ShifuDatabase) throws {
    let flags = DueFlags(arguments)
    // The title is the first bare word-run; the date is whatever bare text
    // follows it, so `due add "Thesis draft" 2026-08-30 17:00` works without
    // making the user quote the date too.
    guard let title = flags.positional.first, !title.isEmpty else {
        print(dueUsage)
        return
    }
    let whenText = flags.value("on") ?? flags.positional.dropFirst().joined(separator: " ")
    guard !whenText.isEmpty else {
        print("shifu due: when is it due? e.g. 2026-08-30, tomorrow, friday, +10d")
        return
    }
    guard let when = DeadlineDate.parse(whenText) else {
        throw DeadlineError.unreadableDate(whenText)
    }
    let taskID = try flags.value("task").flatMap { try resolveTask($0, db: db) }
    let target = flags.value("target").flatMap(DeadlineDate.parseEffort)
    if flags.value("target") != nil && target == nil {
        print("shifu due: couldn't read --target — try 20, 20h or 90m")
        return
    }
    let created = try DeadlineStore.create(
        title: title, dueAt: when.dueAt, allDay: when.allDay,
        taskID: taskID, targetMs: target, database: db)
    let standing = try DeadlineStore.find(created.id ?? 0, database: db)
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    print("#\(created.id ?? 0)  " + (standing.map { DeadlineCopy.summary($0, now: now) } ?? title))
    if taskID == nil && target != nil {
        print("note: a target without a task can't be measured — add --task to track progress")
    }
}

private func dueSet(_ arguments: [String], db: ShifuDatabase) throws {
    let flags = DueFlags(arguments)
    guard let id = flags.positional.first.flatMap(Int64.init) else {
        print(dueUsage)
        return
    }
    guard try DeadlineStore.find(id, database: db) != nil else {
        print("shifu due: no deadline #\(id)")
        return
    }
    let whenText = flags.value("on") ?? flags.positional.dropFirst().joined(separator: " ")
    var when: DeadlineDate.Parsed?
    if !whenText.isEmpty {
        guard let parsed = DeadlineDate.parse(whenText) else {
            throw DeadlineError.unreadableDate(whenText)
        }
        when = parsed
    }
    try DeadlineStore.update(
        id, title: flags.value("title"), dueAt: when?.dueAt, allDay: when?.allDay,
        taskID: try flags.value("task").flatMap { try resolveTask($0, db: db) },
        clearTask: flags.has("no-task"),
        targetMs: flags.value("target").flatMap(DeadlineDate.parseEffort),
        clearTarget: flags.has("no-target"),
        database: db)
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    if let updated = try DeadlineStore.find(id, database: db) {
        print("#\(id)  \(DeadlineCopy.summary(updated, now: now))")
    }
}

private func dueMark(_ arguments: [String], done: Bool, db: ShifuDatabase) throws {
    guard let id = arguments.first.flatMap(Int64.init) else {
        print(dueUsage)
        return
    }
    guard let standing = try DeadlineStore.find(id, database: db) else {
        print("shifu due: no deadline #\(id)")
        return
    }
    try DeadlineStore.markDone(
        id, at: done ? Int64(Date().timeIntervalSince1970 * 1_000) : nil, database: db)
    if done {
        var line = "kept: \(standing.deadline.title)"
        if let effort = DeadlineCopy.effortClause(standing) { line += " — \(effort)" }
        print(line)
    } else {
        print("reopened: \(standing.deadline.title)")
    }
}

private func dueRemove(_ arguments: [String], db: ShifuDatabase) throws {
    guard let id = arguments.first.flatMap(Int64.init) else {
        print(dueUsage)
        return
    }
    guard let standing = try DeadlineStore.find(id, database: db) else {
        print("shifu due: no deadline #\(id)")
        return
    }
    try DeadlineStore.delete(id, database: db)
    print("forgot: \(standing.deadline.title)")
}

// MARK: - Pieces

/// A task by row id, or by a name match — typing the name is what a person has
/// to hand, and the id is what they have after one `shifu due` listing.
private func resolveTask(_ text: String, db: ShifuDatabase) throws -> Int64? {
    if let id = Int64(text) {
        let exists = try db.queue.read { sqlite in
            try Int.fetchOne(sqlite, sql: "SELECT 1 FROM tasks WHERE id = ?", arguments: [id])
        }
        if exists != nil { return id }
    }
    let matches = try db.queue.read { sqlite in
        try Row.fetchAll(
            sqlite,
            sql: """
                SELECT id, name FROM tasks WHERE name LIKE ?
                ORDER BY last_active_at DESC LIMIT 5
                """,
            arguments: ["%\(text)%"])
    }
    guard let best = matches.first else {
        print("shifu due: no task matching \"\(text)\" — recording the date without one")
        return nil
    }
    if matches.count > 1 {
        let names: [String] = matches.dropFirst().map { $0["name"] }
        print("task: \(best["name"] as String) (also matched \(names.joined(separator: ", ")))")
    }
    return best["id"]
}

/// The flag shapes this command uses: `--key value`, `--flag`, and bare
/// positionals. Small enough to spell out; the CLI has no argument parser and
/// design.md §12 already logs that main.swift's `args` handling wants one.
private struct DueFlags {
    var positional: [String] = []
    private var values: [String: String] = [:]
    private var present: Set<String> = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                index += 1
                continue
            }
            let key = String(argument.dropFirst(2))
            present.insert(key)
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                values[key] = next
                index += 2
            } else {
                index += 1
            }
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { present.contains(key) && values[key] == nil }
}
