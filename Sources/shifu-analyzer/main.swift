import Foundation
import IOKit.ps
import ShifuCore

// shifu-analyzer — batch analysis worker (design.md §4). Runs opportunistically
// (invoked hourly by shifud, or on demand); skips on battery unless forced.
// This is the only Shifu binary allowed to touch the network, and only when
// cloud analysis is opted in (Phase 3+; nothing here yet).

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let force = args.contains("--force")
let rebuildAll = args.contains("--rebuild")

if args.contains("--version") {
    print("shifu-analyzer \(Shifu.version)")
    exit(0)
}

func onACPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
    else { return true }  // desktops/unknown: treat as AC
    return type == kIOPMACPowerKey
}

// Keep analysis invisible: never compete with foreground work (§2.2).
setpriority(PRIO_PROCESS, 0, 10)

guard force || onACPower() else {
    print("on battery — skipping analysis (use --force to override)")
    exit(0)
}

try ShifuPaths.ensureHomeExists()
let database = try ShifuDatabase(at: ShifuPaths.database)
let classifier = try RulesClassifier(database: database)

let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
// Incremental window: last 48 h, rebuilt idempotently. Cheap (a few thousand
// rows) and self-heals if a previous run was interrupted.
let from: Int64 = rebuildAll ? 0 : nowMs - 48 * 3_600_000

let summary = try LedgerBuilder.rebuild(
    database: database, classifier: classifier, from: from, to: nowMs)
let scrubbed = try Retention.scrubExpiredText(database: database)

print("analyzed \(summary.observationsProcessed) observations → "
    + "\(summary.blocksWritten) activities"
    + (rebuildAll ? " (full rebuild)" : "")
    + (scrubbed > 0 ? "; scrubbed text from \(scrubbed) expired rows" : ""))
