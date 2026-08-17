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
    private let center = UNUserNotificationCenter.current()

    /// Starts the poll and takes one tick immediately — a reminder whose moment
    /// passed while Shifu was closed should arrive on launch, not five minutes
    /// into it.
    func start() {
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

    private func tick() {
        guard let database = try? ShifuDatabase.open(at: ShifuPaths.database) else { return }
        // Permission is asked for on the first tick that has something to
        // remind about, never at launch: a user who has typed no dates has
        // nothing to grant, and being asked anyway is how the answer becomes no.
        if !askedForAuthorization,
           DeadlineReminders.preferences(database: database).enabled,
           (try? DeadlineReminders.hasSomethingToRemind(database: database)) == true {
            askedForAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        guard let announcements = try? DeadlineReminders.due(database: database),
              !announcements.isEmpty
        else { return }
        for announcement in announcements {
            deliver(announcement, database: database)
        }
    }

    private func deliver(
        _ announcement: DeadlineAnnouncement, database: ShifuDatabase
    ) {
        let content = UNMutableNotificationContent()
        content.title = announcement.title
        content.body = announcement.body
        // Overdue is the one that earns a sound. The rest are news, and news
        // that beeps is the thing people switch reminders off over.
        if case .overdue = announcement.kind { content.sound = .default }
        // `trigger: nil` is deliver-now. The identifier is stable per
        // (deadline, notice) so a duplicate add can only ever replace, never
        // stack — a second belt behind the row's own ledger.
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: announcement), content: content, trigger: nil)
        center.add(request) { error in
            guard error == nil else { return }
            // Stamped only on a successful hand-over, and off the main actor's
            // critical path: a reminder the system refused must stay unsaid so
            // the next tick can try again.
            Task { @MainActor in
                try? DeadlineReminders.record(announcement, database: database)
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
