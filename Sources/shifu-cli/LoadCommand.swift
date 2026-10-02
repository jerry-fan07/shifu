import Foundation
import ShifuCore

// `shifu load` (design.md §4.6): the week's hours across every front at
// once, and whether that is holding — the same reading the Load page draws,
// in the terminal. Kept out of main.swift for length, like DueCommand.swift.

func commandLoad(_ arguments: [String]) throws {
    let unit: Workload.Unit = arguments.contains("--themes") ? .theme : .task
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    let reading = try WorkloadStore.reading(database: try openDatabase(), unit: unit, now: now)

    print("Load — \(WorkloadCopy.title(reading.verdict))")
    print("  " + WorkloadCopy.line(reading))
    print()
    print("  " + loadFigures(reading))

    if !reading.giveTime.isEmpty {
        print("\nGive time")
        for front in reading.giveTime {
            print("  \(front.name)")
            print("    \(WorkloadCopy.reason(front))")
        }
    }
    if !reading.quiet.isEmpty {
        print("\nQuiet — finished, or dropped?")
        for front in reading.quiet {
            print("  \(front.name)")
            print("    \(WorkloadCopy.quietReason(front, now: now))")
        }
    }

    guard !reading.fronts.isEmpty else {
        print("\nNo fronts yet: a front is a task (or, with --themes, a theme) whose time "
            + "is mostly work or learning, with an hour or more in the last four weeks.")
        return
    }
    print("\nFronts by \(unit.rawValue)")
    print("  " + loadColumns("", "this wk", "4-wk avg", "status", "deadline"))
    for front in reading.fronts {
        let pace = front.pace.map(WorkloadCopy.pace) ?? ""
        print("  " + loadColumns(
            String(front.name.prefix(38)), WorkloadCopy.hours(front.thisWeekMs),
            WorkloadCopy.hours(front.meanMs), WorkloadCopy.status(front.status), pace))
    }
    if !reading.unattached.isEmpty {
        let titles = reading.unattached.map(\.deadline.title).joined(separator: ", ")
        print("\n  Not paced — no task behind the deadline: \(titles)")
    }
}

/// The figures line under the verdict: everything the verdict was read from.
private func loadFigures(_ reading: Workload.Reading) -> String {
    var parts = [
        "\(WorkloadCopy.hours(reading.capacity[0])) focused this week",
        "\(WorkloadCopy.hours(reading.tracked[0])) tracked"
    ]
    if let baseline = reading.baselineMs {
        parts.append("baseline \(WorkloadCopy.hours(baseline))/wk")
    }
    parts.append(String(format: "%.1f effective fronts", reading.effectiveFronts))
    if reading.demandMsPerWeek > 0 {
        parts.append("deadlines need \(WorkloadCopy.hours(reading.demandMsPerWeek))/wk")
    }
    return parts.joined(separator: " · ")
}

private func loadColumns(
    _ name: String, _ week: String, _ mean: String, _ status: String, _ pace: String
) -> String {
    name.padding(toLength: 40, withPad: " ", startingAt: 0)
        + week.padding(toLength: 10, withPad: " ", startingAt: 0)
        + mean.padding(toLength: 10, withPad: " ", startingAt: 0)
        + status.padding(toLength: 10, withPad: " ", startingAt: 0)
        + pace
}
