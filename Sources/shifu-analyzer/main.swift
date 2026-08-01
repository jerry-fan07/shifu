import Foundation
import IOKit.ps
import ShifuCore

// shifu-analyzer — batch analysis worker (design.md §4). Runs opportunistically
// (invoked hourly by shifud, or on demand); skips on battery unless forced.
// This is the only Shifu binary allowed to touch the network, and only to the
// configured LLM endpoint — DeepSeek directly, or the hosted Shifu Cloud
// proxy — once the user has opted in (§8).

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

// Shifu Cloud provisioning: the hosted backend's device token is minted on
// first use — choosing that backend was the opt-in (§8), the token is just
// plumbing. Must happen before any backend is built, including --build-deck's.
if case .shifuCloud(nil) = (try? Settings.llmCredential(database: database)) ?? nil {
    _ = await ShifuCloud.ensureToken(database: database)
}

// `--build-deck <key>`: the app asking for one deck to be built (§5.2). Only
// this binary may reach the network, so a deck build is a launch of it. This
// runs before the ledger rebuild and exits — the request is interactive, the
// user is watching a "Building…" row, and the hourly rebuild would both delay
// it and give the concurrent hourly run something to fight over.
if let flagIndex = args.firstIndex(of: "--build-deck"), flagIndex + 1 < args.count {
    let deckKey = args[flagIndex + 1]
    guard let deckBackend = try DeepSeekBackend.ifConfigured(database: database) else {
        // The UI gates this path on a configured backend, so reaching here
        // means the opt-in was revoked mid-flight. The deck stays `pending`
        // and the drain picks it up once a backend exists — never a failure.
        print("no LLM backend — deck \(deckKey) stays pending")
        exit(0)
    }
    let deckVault = VaultStore(database: database)
    do {
        if let cards = try await DeckBuilder.build(
            deckKey: deckKey, database: database, vault: deckVault,
            backend: deckBackend.labeled("deck-build")) {
            print("deck \(deckKey): \(cards) cards")
        } else {
            print("deck \(deckKey): already building elsewhere")
        }
    } catch {
        print("deck build failed (retries on the next drain): \(error)")
    }
    exit(0)
}

let classifier = try RulesClassifier(database: database)

let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
// Incremental window: last 48 h, rebuilt idempotently. Cheap (a few thousand
// rows) and self-heals if a previous run was interrupted.
let from: Int64 = rebuildAll ? 0 : nowMs - 48 * 3_600_000

let summary = try LedgerBuilder.rebuild(
    database: database, classifier: classifier, from: from, to: nowMs)
// Read per run, not per release: shortening the window in Settings has to
// take effect at the next scrub, which is the only thing that makes it a
// promise rather than a preference.
let scrubbed = try Retention.scrubExpiredText(
    database: database,
    olderThanDays: Settings.value(SettingsCatalog.textRetentionDays, database: database))

print("analyzed \(summary.observationsProcessed) observations → "
    + "\(summary.blocksWritten) activities"
    + (rebuildAll ? " (full rebuild)" : "")
    + (scrubbed > 0 ? "; scrubbed text from \(scrubbed) expired rows" : ""))

// One wire protocol, three ways in — the user's own DeepSeek key, the
// hosted Shifu Cloud proxy, or a local server they run themselves. Without
// an opt-in (or with backend "off") every LLM stage is skipped and the
// rules-only ledger stands (§10 fallback). Two model slots share the one
// opt-in (§4.2): the fast model runs everything hourly — cards, grouping,
// themes, notes — over card evidence; the reasoning model is reserved for
// the daily roster reconciliation and the weekly radar, the judgment calls
// where its billed chain-of-thought earns its price. On the local tier both
// slots are the one model the server has loaded.
// The local tier means the GPU doing analysis sits under the user's hands,
// so its calls are paced (LLMPacer): rest between bursts, harder while the
// user is present, gentler once the screen locks or input goes idle — except
// when a flag says someone is watching this very run, where sleeping between
// calls would punish the person who asked. Cloud tiers get no pacer; the
// `--build-deck` path above builds its own backend and stays unpaced for the
// same someone-is-watching reason.
let watched = args.contains("--radar") || args.contains("--digest")
let pacer: LLMPacer? = watched
    ? nil : LLMPacer.ifLocal(database: database, userIsAway: { Presence.userIsAway() })
let backend: DeepSeekBackend? =
    try DeepSeekBackend.ifConfigured(database: database)?.paced(pacer)
let reasoningBackend: DeepSeekBackend? =
    try DeepSeekBackend.ifConfigured(database: database, role: .reasoning)?.paced(pacer)
if let pacer {
    print("local endpoint — pacing LLM calls at \(pacer.activeDutyPercent)% duty "
        + "(\(pacer.idleDutyPercent)% away)")
}

// With a backend, `domain:`/`app:` container keys mint and attach only as a
// last resort (§5.3): the semantic pass gets first claim on their time, and a
// container becomes a task only from blocks the model finished declining.
// Derived from configuration, never from whether this pass's calls succeed —
// one network timeout must not mint container rows the next pass has to
// prune. With no backend the mechanical fallback stands whole (§10).
let minting: TaskGrouper.MechanicalMinting = backend == nil ? .always : .lastResort

// Tier-2 LLM pass (§4.2) — fast model. One call per batch of closed blocks
// distills each into a structured card (category, topic, entities, gist);
// the same card relabels blocks the rules tier marked ambiguous. Every later
// *grouping* stage renders cards instead of re-sampling raw text, so this is
// where OCR text meets a prompt on the hourly path — with one exception the
// ledger stages don't own: WorkNoteCompiler still samples `observations.text`
// directly for its day narratives (design.md §12).
if let backend {
    do {
        let cardSummary = try await CardBuilder.run(
            database: database, backend: backend.labeled("cards"), from: from, to: nowMs)
        if cardSummary.built > 0 {
            print("cards (\(backend.name)): \(cardSummary.built) built, "
                + "\(cardSummary.relabeled) ambiguous blocks relabeled")
        }
    } catch {
        // LLM problems never block the ledger (§10); blocks stay queued.
        print("cards (\(backend.name)) failed, blocks stay queued: \(error)")
    }
}

// The free half of semantic grouping (§5.3), before the model pass so the
// sliver pool it sweeps is already smaller: an unplaced glance with the same
// task running on both sides of it, inside one sitting, adopts that task —
// zero tokens. Outside `if let backend` on purpose: the claim rests on the
// neighbours, not on a model being configured.
do {
    let inherited = try SemanticTaskGrouper.inheritFromNeighbors(
        database: database, from: from, to: nowMs)
    if inherited > 0 {
        print("semantic tasks: \(inherited) blocks inherited from neighbours")
    }
} catch {
    print("semantic inheritance failed (retries next run): \(error)")
}

// Semantic task grouping (§5.3): the LLM assigns the window's blocks to
// intent-level tasks before the mechanical grouper runs, so `sem_key` exists
// when TaskGrouper picks keys. Fast slot, hourly: with card evidence the
// common case is matching a block against the roster, which doesn't need
// billed chain-of-thought — minting is held to a higher floor and the daily
// reconciliation audits the results. Fail-soft: on any failure blocks keep
// their mechanical grouping and stay queued for the next run (§10).
if let backend {
    do {
        let semSummary = try await SemanticTaskGrouper.run(
            database: database, backend: backend.labeled("semantic-tasks"),
            from: from, to: nowMs)
        // Printed whenever the stage had anything to judge, declines
        // included: gating this on `assigned > 0` made the two failures
        // that matter — a model placing nothing, and a model that was
        // never asked — look identical from the outside, which is most of
        // why "the LLM isn't inferring my tasks" was unanswerable from the
        // logs. Each decline also burns one of `maxAttempts`, so the count
        // is the early warning that blocks are about to give up for good.
        if semSummary.assigned > 0 || semSummary.declined > 0 || semSummary.unparsed > 0 {
            var line = "semantic tasks (\(backend.name)): \(semSummary.assigned) "
                + "blocks assigned, \(semSummary.tasksCreated) tasks created, "
                + "\(semSummary.declined) declined"
            // Worth its own word: these blocks were paid for and not judged,
            // which is the signature of a batch outgrowing its answer reserve.
            if semSummary.unparsed > 0 { line += ", \(semSummary.unparsed) unreadable" }
            print(line)
        }
    } catch {
        print("semantic grouping failed, blocks stay mechanically grouped: \(error)")
    }
}

// Tasks & work logs (§5.3): group the window's activities into ongoing tasks
// and compile per-day logs. Runs after the LLM passes so semantic keys and
// topics exist, and *before* extraction so `activities.task_id` exists when
// notes are born (vault-features.md §3). Fail-soft like the stages around
// it: everything after — themes, prune, work notes, the vault index, the
// digest — is idempotent and self-heals next pass, so a throw here must not
// take them all down.
do {
    let taskSummary = try TaskGrouper.run(
        database: database, from: from, to: nowMs, minting: minting)
    if taskSummary.tasksTouched > 0 {
        print("tasks: \(taskSummary.tasksTouched) touched, \(taskSummary.logsWritten) day logs")
    }
} catch {
    print("task grouping failed (retries next run): \(error)")
}

// Theme layer (§5.3): the second, independent clustering into broad
// initiatives. Runs after TaskGrouper so task assignments exist — which is
// also what makes most of it free: a task's dominant theme takes its
// unthemed blocks in SQL first, and only blocks inheritance couldn't place
// reach the model. Fast slot with card evidence; narratives are hash-gated
// to ~one generation per theme per day and summarize compiled facts, not
// intent, so they ride the fast slot too. Fail-soft like every LLM stage.
do {
    let inherited = try ThemeClusterer.inheritFromTasks(
        database: database, from: from, to: nowMs)
    if inherited > 0 { print("themes: \(inherited) blocks inherited from their tasks") }
} catch {
    print("theme inheritance failed (retries next run): \(error)")
}
if let backend {
    do {
        let themeSummary = try await ThemeClusterer.run(
            database: database, backend: backend.labeled("themes"), from: from, to: nowMs)
        if themeSummary.assigned > 0 || themeSummary.themesProposed > 0 {
            print("themes (\(backend.name)): \(themeSummary.assigned) "
                + "blocks assigned, \(themeSummary.themesProposed) themes suggested")
        }
        let narrated = try await ThemeClusterer.refreshNarratives(
            database: database, backend: backend.labeled("theme-narratives"))
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

// Prune noise tasks (design.md §5.3): sub-threshold, never renamed, never
// hand-filed under a theme, stale for a week — debris the gate now stops at the
// source. Their time stays in the ledger; logs and notes recompile. Shares
// `minting` with the grouper so reap and mint can never disagree about
// container tasks.
do {
    let pruned = try TaskStore.prune(database: database, vault: vault, minting: minting)
    if pruned > 0 { print("tasks: pruned \(pruned) noise tasks") }
} catch {
    print("task prune failed (retries next run): \(error)")
}

// Auto-merge (vault-features.md §5.2) is the other half of roster hygiene, so
// it runs beside prune every pass rather than in the weekly block that mints
// the suggestions: it drains a *stored* queue, which costs one indexed query
// when there is nothing to fold, and folding within the hour beats letting
// duplicates sit in the task list for a week. It needs no embedder.
do {
    let merged = try TaskMerges.autoMerge(database: database, vault: vault)
    if merged > 0 { print("tasks: \(merged) duplicate tasks auto-merged") }
} catch {
    print("auto-merge failed (retries next run): \(error)")
}

// Roster reconciliation (§5.3): the reasoning model's one scheduled call —
// it audits the roster the fast-model stages built (duplicate efforts,
// missing gists) instead of paying its chain-of-thought hourly. Merge
// proposals join the suggestion queue and its gates. Stamped only on
// success, like every LLMStageGate caller.
//
// Every six hours rather than daily (v27): this is the only pass that can
// undo a duplicate mint, and at 24 h a second name for today's work outlived
// the day it was minted in — long enough to collect blocks, a work note and
// a place in the Task log. Four calls a day on the reasoning slot is the
// one place its chain-of-thought measurably earns its price.
if let reasoningBackend,
   LLMStageGate.due("reconcile.last_ran", everyMs: 6 * 3_600_000,
                    now: nowMs, database: database) {
    do {
        let reconciled = try await TaskReconciler.run(
            database: database, backend: reasoningBackend.labeled("reconcile"))
        LLMStageGate.stamp("reconcile.last_ran", now: nowMs, database: database)
        if reconciled.mergesSuggested > 0 || reconciled.gistsFilled > 0 {
            print("reconcile (\(reasoningBackend.name)): "
                + "\(reconciled.mergesSuggested) merge suggestions, "
                + "\(reconciled.gistsFilled) gists filled")
        }
    } catch {
        print("reconcile failed (retries next pass): \(error)")
    }
}

// Nothing writes knowledge notes automatically any more (§5.1): the vault's
// cards come from decks the user asked for, and nothing else.
if let backend {
    // Decks the app asked for but never got built — its `--build-deck` launch
    // hit a machine with no key, or died mid-build (§5.2). Costs one indexed
    // query when there is nothing waiting.
    do {
        let built = try await DeckBuilder.drainPending(
            database: database, vault: vault, backend: backend.labeled("decks"))
        if built > 0 { print("decks: \(built) built") }
    } catch {
        print("deck build failed (retries next run): \(error)")
    }
}

// Work notes (vault-features.md §2.1): deterministic parts always compile;
// narratives need a backend and regenerate only when a day's activities
// changed (content-hash gate). The hash gate alone can't protect the day in
// progress — active work changes it every pass — so the open day's narrative
// additionally waits out an interval gate, while completed days regenerate
// the moment they change. Stamped only on success, like the radar watermark.
let openDayNarrativeIntervalMs: Int64 = 4 * 3_600_000
let openDayDue = LLMStageGate.due(
    "worknotes.open_day", everyMs: openDayNarrativeIntervalMs,
    now: nowMs, database: database)
do {
    let workSummary = try await WorkNoteCompiler.run(
        database: database, vault: vault, backend: backend?.labeled("worknotes"),
        from: from, to: nowMs, regenerateOpenDay: openDayDue)
    if openDayDue, backend != nil {
        LLMStageGate.stamp("worknotes.open_day", now: nowMs, database: database)
    }
    if workSummary.notesWritten > 0 {
        // Failures are printed, not just counted: this stage swallows them
        // with `try?` so one bad day can't take the rest of the vault down,
        // and for three days that silence hid every call it was making.
        print("work notes: \(workSummary.notesWritten) compiled, "
            + "\(workSummary.narrativesGenerated) narratives"
            + (workSummary.narrativesFailed > 0
                ? "; \(workSummary.narrativesFailed) failed, retried next run" : ""))
    }
} catch {
    print("work notes failed (retries next run): \(error)")
}

// Per-task overview documents (vault-features.md §2.1): the day notes are the
// diary, this is the documentation. Runs right after the day notes it reads,
// fast slot, hash-gated on *completed* days — so at most one generation per
// task per day however often the analyzer runs.
if let backend {
    do {
        let overviewSummary = try await TaskOverviewCompiler.run(
            database: database, vault: vault, backend: backend.labeled("task-overviews"))
        if overviewSummary.written > 0 {
            print("task overviews: \(overviewSummary.written) compiled")
        }
    } catch {
        print("task overviews failed (retries next run): \(error)")
    }
}

// Vault search index reconcile (vault-features.md §4): write-through hooks
// cover Shifu's own writes; this catches external edits (Obsidian) and runs
// after task grouping so task_key → task resolution is current.
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

// Radar: mine automation candidates weekly (§6.1), or on demand with --radar.
// The miner does its own filtering now — it walks tasks and their day logs
// rather than raw blocks, so the "everything that isn't private" fetch this
// block used to do is gone with the domain-altitude suggestions it produced.
let lastMined = Int64((try? Settings.get("radar.last_mined", database: database)) ?? "0") ?? 0
if args.contains("--radar") || nowMs - lastMined > 6 * 86_400_000 {
    let mineFrom = nowMs - Int64(PatternMiner.windowDays) * 86_400_000
    let candidates = try PatternMiner.mine(database: database, from: mineFrom, to: nowMs)
    let inserted = try Radar.upsert(candidates: candidates, database: database)
    if !candidates.isEmpty {
        print("radar: \(candidates.count) candidates mined, \(inserted) new")
    }
    // Judging what is worth automating is the reasoning model's kind of call,
    // and this runs at most once a week over a dozen dossiers.
    //
    // The weekly watermark is only stamped once the describer has had its
    // turn. A mined row is invisible until it is described (§6.2), and the
    // dossier behind it lives only for this run — so stamping first would let
    // one timed-out call hide the whole tab until the next weekly window,
    // with nothing the user could do about it. Mining again next hour is
    // local SQL; the describer's own attempt is what retries.
    var described = true
    if let reasoningBackend {
        do {
            let summary = try await Radar.describe(
                database: database, backend: reasoningBackend.labeled("radar"),
                candidates: candidates)
            if summary.accepted > 0 || summary.rejected > 0 {
                print("radar (\(reasoningBackend.name)): \(summary.accepted) suggestions, "
                    + "\(summary.rejected) judged not worth it")
            }
        } catch {
            described = false
            print("radar describer failed (retries next run): \(error)")
        }
    }
    if described { try Settings.set("radar.last_mined", to: String(nowMs), database: database) }

    // Task merge + theme suggestions (vault-features.md §5.2–5.3), same
    // weekly cadence. No embedder ⇒ no new suggestions; theme assignment
    // stays user-confirmed.
    if let embedder {
        do {
            let suggested = try TaskMerges.suggest(database: database, embedder: embedder)
            if suggested > 0 { print("tasks: \(suggested) merge suggestions") }
            let themeSuggested = try TaskMerges.suggestThemes(
                database: database, embedder: embedder)
            if themeSuggested > 0 {
                print("themes: \(themeSuggested) assignment suggestions")
            }
        } catch {
            print("suggesters failed (retry next week): \(error)")
        }
    }

    // Deck proposals (§5.2), same weekly cadence: cards are user-requested
    // now, so without this the feature waits on the user thinking to ask.
    // The fast slot — judging one task against its own evidence is a labeling
    // call, and the caps inside bound it to two per run. Fail-soft: an
    // unevaluated task simply waits for next week.
    if let backend {
        do {
            let proposed = try await DeckSuggester.run(
                database: database, backend: backend.labeled("deck-suggest"))
            if proposed > 0 { print("decks: \(proposed) deck suggestions") }
        } catch {
            print("deck suggester failed (retry next week): \(error)")
        }
    }
}

// Daily digest at/after the configured hour (default 18:00, §4.3).
let digestHour = Int((try? Settings.get(Settings.digestHourKey, database: database)) ?? "18") ?? 18
if Calendar.current.component(.hour, from: Date()) >= digestHour || args.contains("--digest") {
    if let url = try DigestGenerator.generate(database: database, force: args.contains("--digest")) {
        print("digest written: \(url.path)")
    }
}

// What today has cost so far, at the configured per-million rates (LLMPrices).
// Printed every run so the log reads as a running meter; the ⚠ threshold is a
// warning by design, never a governor — the user chose visibility over
// throttling, so no stage above was gated on it. Local midnight is fine here:
// the estimate answers "cheap day or expensive day?", not an invoice.
let dayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1_000)
let priceBook = LLMPriceBook.load(database: database)
let spentToday = priceBook.cost(from: dayStartMs, to: Int64.max, database: database)
if spentToday > 0 {
    let warnAt = LLMPriceBook.dailyWarnUSD(database: database)
    print(String(format: "llm spend today ≈ $%.3f", spentToday)
        + (spentToday > warnAt ? String(format: " ⚠ (warn at $%.2f)", warnAt) : ""))
}
