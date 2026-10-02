import Foundation
import ShifuCore

// `shifu due spotted|accept|dismiss|scan` (design.md §4.7): the terminal half
// of spotted dates. Split from DueCommand.swift for that file's length.

/// The verbs `commandDue` hands over. Prints the usage for one it does not know.
func commandDueSpotted(_ verb: String, _ arguments: [String], db: ShifuDatabase) throws {
    switch verb {
    case "spotted": try dueSpotted(arguments, db: db)
    case "accept": try dueAccept(arguments, db: db)
    case "dismiss": try dueDismiss(arguments, db: db)
    case "scan": try dueScan(arguments, db: db)
    default: print(dueUsage)
    }
}

func dueSpotted(_ arguments: [String], db: ShifuDatabase) throws {
    let all = arguments.contains("--all")
    let rows = all
        ? try DeadlineProposalStore.all(database: db)
        : try DeadlineProposalStore.pending(database: db, minimumTier: .normal)
    guard !rows.isEmpty else {
        print(all ? "nothing spotted yet — the analyzer scans each pass; `shifu due scan` runs one now"
                  : "nothing spotted that looks important. `shifu due spotted --all` shows everything")
        return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    var lastTier: DeadlineScout.Tier?
    for row in rows where all || row.status == .new {
        if row.tier != lastTier {
            print(lastTier == nil ? row.tier.label : "\n\(row.tier.label)")
            lastTier = row.tier
        }
        print(spottedLine(row, now: now, verbose: all))
    }
    let openCount = rows.filter { $0.status == .new }.count
    print("\n\(openCount) open · `shifu due accept <id>` records one, `shifu due dismiss <id>` forgets it")
}

func spottedLine(_ row: DeadlineProposal, now: Int64, verbose: Bool) -> String {
    let id = row.id.map(String.init) ?? "?"
    var line = "\(id.padding(toLength: 5, withPad: " ", startingAt: 0))"
    line += "\(row.title) — \(SpottedNotices.when(row, now: now))"
    line += "  [\(row.category.label.lowercased())"
    if let context = row.context { line += " · \(context)" }
    line += "]"
    if verbose {
        line += "  score \(row.score), seen \(row.sightings)× over \(row.seenDays)d"
        if row.status != .new { line += " · \(row.status.rawValue)" }
    }
    return line
}

func dueAccept(_ arguments: [String], db: ShifuDatabase) throws {
    guard let id = arguments.first.flatMap(Int64.init) else {
        print(dueUsage)
        return
    }
    guard let proposal = try DeadlineProposalStore.find(id, database: db) else {
        print("shifu due: nothing spotted as #\(id)")
        return
    }
    guard proposal.status == .new else {
        print("shifu due: #\(id) was already \(proposal.status.rawValue)")
        return
    }
    let flags = DueFlags(Array(arguments.dropFirst()))
    let whenText = flags.value("on") ?? ""
    var when: DeadlineDate.Parsed?
    if !whenText.isEmpty {
        guard let parsed = DeadlineDate.parse(whenText) else { throw DeadlineError.unreadableDate(whenText) }
        when = parsed
    }
    let target = flags.value("target").flatMap(DeadlineDate.parseEffort)
    guard let deadline = try DeadlineProposalStore.accept(
        id, title: flags.value("title"), dueAt: when?.dueAt, allDay: when?.allDay,
        taskID: try flags.value("task").flatMap { try resolveTask($0, db: db) },
        targetMs: target, database: db)
    else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let standing = try DeadlineStore.find(deadline.id ?? 0, database: db)
    print("#\(deadline.id ?? 0)  " + (standing.map { DeadlineCopy.summary($0, now: now) } ?? deadline.title))
}

func dueDismiss(_ arguments: [String], db: ShifuDatabase) throws {
    if arguments.first == "all" {
        let count = try DeadlineProposalStore.dismissAll(database: db)
        print("dismissed \(count) spotted date\(count == 1 ? "" : "s")")
        return
    }
    guard let id = arguments.first.flatMap(Int64.init) else {
        print(dueUsage)
        return
    }
    guard let proposal = try DeadlineProposalStore.find(id, database: db) else {
        print("shifu due: nothing spotted as #\(id)")
        return
    }
    try DeadlineProposalStore.dismiss(id, database: db)
    print("dismissed: \(proposal.title)")
}

/// `shifu due scan [--all] [--dry]`: run the scout now. `--all` starts over
/// from the oldest text still kept; `--dry` prints what it would record,
/// with every signal behind the score, and writes nothing — the calibration
/// harness, run against a copy of the real database.
func dueScan(_ arguments: [String], db: ShifuDatabase) throws {
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    if arguments.contains("--dry") {
        let found = try DeadlineScoutRun.preview(database: db, now: now)
        struct DryRow {
            var hit: DeadlineScout.Hit
            var source: DeadlineScout.Source
            var count: Int
        }
        var byKey: [String: DryRow] = [:]
        for (sighting, hit) in found {
            if var entry = byKey[hit.key] {
                entry.count += 1
                if hit.score > entry.hit.score {
                    entry.hit = hit
                    entry.source = sighting.source
                }
                byKey[hit.key] = entry
            } else {
                byKey[hit.key] = DryRow(hit: hit, source: sighting.source, count: 1)
            }
        }
        let rows = byKey.values.sorted { ($0.hit.score, $0.hit.dueAt) > ($1.hit.score, $1.hit.dueAt) }
        var counts: [DeadlineScout.Tier: Int] = [:]
        for row in rows {
            counts[row.hit.tier, default: 0] += 1
            let app = SemanticTaskGrouper.shortBundle(row.source.appBundle)
            print("[\(row.hit.score)] \(row.hit.tier.label.lowercased()) \(row.hit.category.rawValue) ×\(row.count)"
                + " \(app)\(row.source.domain.map { "/" + $0 } ?? "")")
            print("    \(row.hit.title)" + (row.hit.context.map { "  ⟨\($0)⟩" } ?? ""))
            print("    \(row.hit.evidence.prefix(140))")
            print("    \(row.hit.signals.joined(separator: " "))")
        }
        print("\n\(found.count) sightings → \(rows.count) distinct · "
            + DeadlineScout.Tier.allCases.reversed()
                .map { "\($0.label.lowercased()) \(counts[$0] ?? 0)" }.joined(separator: " · "))
        return
    }
    let summary = try DeadlineScoutRun.run(database: db, now: now, reset: arguments.contains("--all"))
    print("scanned \(summary.observationsRead) observations → \(summary.hits) sightings, "
        + "\(summary.created) new, \(summary.expired) expired")
}
