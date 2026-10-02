import Foundation
import ShifuCore
import UserNotifications

/// Delivering deadline reminders (design.md §4.5).
///
/// **Why the app and not the daemon.** `UNUserNotificationCenter.current()`
/// needs a real bundle identity; `shifud` is a bare LaunchAgent executable with
/// none, so the call traps there rather than failing soft. Shifu.app has one
/// (`com.shifu.app`) and already stays resident for its menu bar item, so the
/// notifier lives here — and `shifud` keeps the property that makes invariant 1
/// auditable, which is that it links nothing that can speak to the outside.
///
/// **Why poll and not schedule.** See `DeadlineReminders`: the pending-request
/// queue would be a second state store `shifu due` cannot reach.
///
/// Everything about *what* to say is in `ShifuCore`. This file is the wiring:
/// a timer, an authorization request, and the two-line banner.
@MainActor
final class DeadlineNotifier: NSObject {
    /// Five minutes. The hour gate in `DeadlineHorizon` decides the minute a
    /// date notice lands on, so polling faster buys nothing; progress notices
    /// follow the ledger, which the analyzer rewrites hourly. One indexed read
    /// of `deadlines` per tick.
    static let interval: TimeInterval = 300

    private var timer: Timer?
    private var askedForAuthorization = false
    private var started = false
    /// Lazy, not stored eagerly: `UNUserNotificationCenter.current()` traps in a
    /// process with no bundle identity, and this type is constructed before the
    /// onboarding gate decides whether to use it — so a bare
    /// `swift run ShifuApp` must be able to build one and never touch it.
    private lazy var center = UNUserNotificationCenter.current()

    /// Starts the poll and takes one tick immediately — a reminder whose moment
    /// passed while Shifu was closed should arrive on launch, not five minutes
    /// into it.
    ///
    /// Idempotent: launch calls it, and so does finishing onboarding, which is
    /// the one path where launch declined to.
    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        tick()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
        // `.common` so the poll keeps running while a menu or a drag has the
        // run loop in a tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Traces the delivery path to stdout when `SHIFU_NOTIFY_TRACE` is set.
    ///
    /// This exists because the last three inches of this feature —
    /// authorization, `center.add`, `willPresent` — cannot be reached from a
    /// test: `UNUserNotificationCenter` needs a signed bundle, and whether the
    /// user pressed Allow is not something a test can decide. A silent reminder
    /// is otherwise indistinguishable from a reminder that was never due, so the
    /// only way to tell them apart is to ask the binary.
    /// Written to stderr rather than `print`: stdout is block-buffered when it
    /// is a pipe, so a `print` trace from a GUI app that never exits cleanly is
    /// a trace you never see.
    private func trace(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["SHIFU_NOTIFY_TRACE"] != nil else { return }
        FileHandle.standardError.write(Data("deadline-notifier: \(message())\n".utf8))
    }

    private func tick() {
        guard let database = try? ShifuDatabase.open(at: ShifuPaths.database) else {
            trace("no database at \(ShifuPaths.database.path)")
            return
        }
        trace("tick — home \(ShifuPaths.database.path)")
        center.getNotificationSettings { [weak self] settings in
            // Read the one field out here: `UNNotificationSettings` is not
            // Sendable, so hopping it to the main actor is a data race.
            let status = settings.authorizationStatus.rawValue
            Task { @MainActor in self?.trace("authorization status \(status)") }
        }
        // Permission is asked for on the first tick that has something to
        // remind about, never at launch: a user who has typed no dates has
        // nothing to grant, and being asked anyway is how the answer becomes no.
        if !askedForAuthorization,
           DeadlineReminders.preferences(database: database).enabled,
           (try? DeadlineReminders.hasSomethingToRemind(database: database)) == true {
            askedForAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                Task { @MainActor in
                    self?.trace("authorization requested — granted \(granted)"
                        + (error.map { ", error \($0)" } ?? ""))
                }
            }
        }
        let announcements = (try? DeadlineReminders.due(database: database)) ?? []
        // Spotted dates (design.md §4.7) ride the same poll and the same
        // ledger discipline: at most one roll-up a day, each proposal named
        // once, stamped after the post.
        let notices = (try? SpottedNotices.due(database: database)) ?? []
        guard !announcements.isEmpty || !notices.isEmpty else {
            trace("nothing due")
            return
        }
        trace("\(announcements.count) due, \(notices.count) spotted")
        for announcement in announcements {
            deliver(announcement, database: database)
        }
        for notice in notices {
            deliver(notice, database: database)
        }
    }

    private func deliver(_ notice: SpottedNotice, database: ShifuDatabase) {
        // A spotted date never beeps, urgent or not: it is a guess, and a
        // guess that makes a sound is the one people switch the feature off
        // over.
        post(identifier: notice.identifier, title: notice.title, body: notice.body, sound: false) {
            try? SpottedNotices.record(notice, database: database)
        }
    }

    private func deliver(
        _ announcement: DeadlineAnnouncement, database: ShifuDatabase
    ) {
        // Overdue is the one that earns a sound. The rest are news, and news
        // that beeps is the thing people switch reminders off over.
        var overdue = false
        if case .overdue = announcement.kind { overdue = true }
        post(identifier: Self.identifier(for: announcement), title: announcement.title,
             body: announcement.body, sound: overdue) {
            try? DeadlineReminders.record(announcement, database: database)
        }
    }

    /// The two-line banner. `trigger: nil` is deliver-now. The identifier is
    /// stable per notice so a duplicate add can only ever replace, never
    /// stack — a second belt behind each row's own ledger. `stamp` runs only
    /// on a successful hand-over, and off the main actor's critical path: a
    /// reminder the system refused must stay unsaid so the next tick can try
    /// again.
    private func post(
        identifier: String, title: String, body: String, sound: Bool,
        stamp: @escaping @MainActor () -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            Task { @MainActor in
                guard let error else {
                    self?.trace("posted \(identifier)")
                    stamp()
                    return
                }
                self?.trace("post refused: \(error)")
            }
        }
    }

    /// `shifu.deadline.<id>.lead.-1` / `.notch.50` — stable, so re-adding the
    /// same notice replaces the banner instead of adding a second one.
    static func identifier(for announcement: DeadlineAnnouncement) -> String {
        let suffix: String
        if let lead = announcement.lead {
            suffix = "lead.\(lead)"
        } else if let notch = announcement.notch {
            suffix = "notch.\(notch)"
        } else {
            suffix = "notice"
        }
        return "shifu.deadline.\(announcement.deadlineID).\(suffix)"
    }
}

extension DeadlineNotifier: UNUserNotificationCenterDelegate {
    /// macOS suppresses banners while the posting app is frontmost, which would
    /// hide every reminder that lands while the dashboard is open — the times
    /// the user is most likely to act on one. This opts back in.
    ///
    /// `nonisolated` rather than an isolated conformance: the method touches no
    /// instance state, so there is nothing for the main actor to protect, and
    /// the alternative is `@preconcurrency` — which silences the check instead
    /// of answering it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
