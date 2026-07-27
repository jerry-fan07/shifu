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
let database = try ShifuDatabase.open(at: ShifuPaths.database)
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

// Tier-2 LLM pass over ambiguous blocks (§4.2). Backend selection: an explicit
// cloud opt-in wins ("claude", or "openai" for DeepSeek/OpenAI-compatible);
// otherwise on-device Foundation Models if the OS has it; otherwise rules-only
// (nothing to do — §10 fallback). "off" disables every LLM stage.
let backendChoice = try Settings.get(Settings.analysisBackendKey, database: database)
let backend: (any LLMBackend)?
if backendChoice == "off" {
    backend = nil
} else if let claude = try ClaudeBackend.ifConfigured(database: database) {
    backend = claude
} else if let openAI = try OpenAIBackend.ifConfigured(database: database) {
    backend = openAI
} else {
    backend = FoundationModelsBackend.ifAvailable()
}
if let backend {
    do {
        let relabeled = try await AmbiguousClassifier.run(
            database: database, backend: backend, from: from, to: nowMs)
        if relabeled > 0 {
            print("llm (\(backend.name)): relabeled \(relabeled) ambiguous blocks")
        }
    } catch {
        // LLM problems never block the ledger (§10); blocks stay queued.
        print("llm (\(backend.name)) failed, blocks stay queued: \(error)")
    }
}

// Semantic task grouping (§5.3): the LLM assigns the window's blocks to
// intent-level tasks before the mechanical grouper runs, so `sem_key` exists
// when TaskGrouper picks keys. Fail-soft: on any failure blocks keep their
// mechanical grouping and stay queued for the next run (§10).
if let backend {
    do {
        let semSummary = try await SemanticTaskGrouper.run(
            database: database, backend: backend, from: from, to: nowMs)
        if semSummary.assigned > 0 {
            print("semantic tasks (\(backend.name)): \(semSummary.assigned) blocks assigned, "
                + "\(semSummary.tasksCreated) tasks created")
        }
    } catch {
        print("semantic grouping failed, blocks stay mechanically grouped: \(error)")
    }
}

// Tasks & work logs (§5.3): group the window's activities into ongoing tasks
// and compile per-day logs. Runs after the LLM passes so semantic keys and
// topics exist, and *before* extraction so `activities.task_id` exists when
// notes are born (vault-features.md §3).
let taskSummary = try TaskGrouper.run(database: database, from: from, to: nowMs)
if taskSummary.tasksTouched > 0 {
    print("tasks: \(taskSummary.tasksTouched) touched, \(taskSummary.logsWritten) day logs")
}

// Theme layer (§5.3): the second, independent clustering into broad
// initiatives. Runs after TaskGrouper so task names exist as evidence.
// Fail-soft like every LLM stage.
if let backend {
    do {
        let themeSummary = try await ThemeClusterer.run(
            database: database, backend: backend, from: from, to: nowMs)
        if themeSummary.assigned > 0 {
            print("themes (\(backend.name)): \(themeSummary.assigned) blocks assigned, "
                + "\(themeSummary.themesCreated) themes created")
        }
        let narrated = try await ThemeClusterer.refreshNarratives(
            database: database, backend: backend)
        if narrated > 0 { print("themes: \(narrated) narratives refreshed") }
    } catch {
        print("theme clustering failed, themes stay as they were: \(error)")
    }
}

// Durable block signatures (vault-features.md §5.1): re-derived each run
// while the source titles still exist, they outlive observation retention
// and feed the weekly merge-suggestion centroids.
try TaskMerges.writeSignatures(database: database, from: from, to: nowMs)

let vault = VaultStore(database: database)

// Knowledge extraction over learning/novel-work blocks (§5.1).
if let backend {
    do {
        let candidates = try await KnowledgeExtractor.run(
            database: database, vault: vault, backend: backend, from: from, to: nowMs)
        if candidates > 0 {
            print("vault: \(candidates) new inbox candidates")
        }
    } catch {
        print("extraction failed (blocks stay unprocessed next run): \(error)")
    }
}

// Work notes (vault-features.md §2.1): deterministic parts always compile;
// narratives need a backend and regenerate only when a day's activities
// changed (content-hash gate).
do {
    let workSummary = try await WorkNoteCompiler.run(
        database: database, vault: vault, backend: backend, from: from, to: nowMs)
    if workSummary.notesWritten > 0 {
        print("work notes: \(workSummary.notesWritten) compiled, "
            + "\(workSummary.narrativesGenerated) narratives")
    }
} catch {
    print("work notes failed (retries next run): \(error)")
}

// Vault search index reconcile (vault-features.md §4): write-through hooks
// cover Shifu's own writes; this catches external edits (Obsidian) and runs
// after task grouping so task_key → task/project resolution is current.
// The embedder keeps vault_vectors in step for hybrid search (V4);
// nil (no OS model) leaves search bm25-only.
let embedder = SentenceEmbedder()
do {
    let indexSummary = try VaultIndexer.reconcile(
        root: ShifuPaths.vault, database: database, embedder: embedder)
    if indexSummary.indexed > 0 || indexSummary.removed > 0 {
        print("vault index: \(indexSummary.indexed) updated, \(indexSummary.removed) removed")
    }
} catch {
    print("vault index reconcile failed (retries next run): \(error)")
}

// Radar: mine patterns weekly (§6.1), or on demand with --radar.
let lastMined = Int64((try? Settings.get("radar.last_mined", database: database)) ?? "0") ?? 0
if args.contains("--radar") || nowMs - lastMined > 6 * 86_400_000 {
    let mineFrom = nowMs - 14 * 86_400_000
    let recent = try database.queue.read { db in
        try Activity
            .filter(sql: "ended_at > ? AND category != 'private'", arguments: [mineFrom])
            .order(sql: "started_at")
            .fetchAll(db)
    }
    let patterns = PatternMiner.mine(recent)
    let inserted = try Radar.upsert(patterns: patterns, database: database)
    try Settings.set("radar.last_mined", to: String(nowMs), database: database)
    if !patterns.isEmpty {
        print("radar: \(patterns.count) patterns mined, \(inserted) new")
    }
    if let backend {
        do {
            let described = try await Radar.describe(database: database, backend: backend)
            if described > 0 { print("radar: described \(described) suggestions") }
        } catch {
            print("radar describer failed (retries next run): \(error)")
        }
    }

    // Task merge + project suggestions (vault-features.md §5.2–5.3), same
    // weekly cadence. No embedder ⇒ no-op; all actions are user-confirmed.
    if let embedder {
        do {
            let suggested = try TaskMerges.suggest(database: database, embedder: embedder)
            if suggested > 0 { print("tasks: \(suggested) merge suggestions") }
            let projectSuggested = try TaskMerges.suggestProjects(
                database: database, embedder: embedder)
            if projectSuggested > 0 {
                print("projects: \(projectSuggested) assignment suggestions")
            }
        } catch {
            print("suggesters failed (retry next week): \(error)")
        }
    }

    // Project notes (vault-features.md §2.2): weekly recompile; the LLM
    // status paragraph is hash-gated like work-note narratives.
    do {
        let compiled = try await ProjectNoteCompiler.run(
            database: database, vault: vault, backend: backend)
        if compiled > 0 { print("projects: \(compiled) notes compiled") }
    } catch {
        print("project notes failed (retries next week): \(error)")
    }
}

// Daily digest at/after the configured hour (default 18:00, §4.3).
let digestHour = Int((try? Settings.get(Settings.digestHourKey, database: database)) ?? "18") ?? 18
if Calendar.current.component(.hour, from: Date()) >= digestHour || args.contains("--digest") {
    if let url = try DigestGenerator.generate(database: database, force: args.contains("--digest")) {
        print("digest written: \(url.path)")
    }
}
