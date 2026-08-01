import Foundation
import ServiceManagement
import ShifuCore

/// Registers the bundled capture daemon as a LaunchAgent via SMAppService
/// (macOS 13+): one toggle in System Settings → Login Items, and the
/// registration survives the app being moved because launchd resolves the
/// daemon through the bundle, not an absolute path.
///
/// Only a bundled build carries Contents/Library/LaunchAgents — a dev run
/// (swift run, the bare build product) has none, so every call here is a
/// no-op and a dogfood daemon installed by install-daemon.sh keeps running
/// untouched until the bundled app takes over.
enum DaemonService {
    private static let agentPlistName = "com.shifu.shifud.plist"

    /// The dev installer's registration: a plist written into the user's
    /// LaunchAgents pointing at ~/Shifu/bin/shifud. SMAppService keeps its
    /// plist inside the bundle, so a file here can only be the legacy install.
    private static var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.shifu.shifud.plist")
    }

    /// Whether this process runs from a bundle that ships the daemon — the
    /// gate on everything else here.
    static var isBundled: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlistName)").path)
    }

    static var status: SMAppService.Status {
        SMAppService.agent(plistName: agentPlistName).status
    }

    /// True once the agent needs the user's nod in System Settings → General
    /// → Login Items — the one state registration can't get itself out of.
    static var requiresApproval: Bool {
        isBundled && status == .requiresApproval
    }

    /// Registers the bundled daemon, migrating a legacy dev install out of
    /// the way first — both registrations share the com.shifu.shifud label,
    /// so the old one must be gone before the new one can exist. Safe to call
    /// on every launch: an enabled agent is left alone.
    static func syncRegistration() {
        guard isBundled else { return }
        migrateLegacyInstall()
        let agent = SMAppService.agent(plistName: agentPlistName)
        switch agent.status {
        case .enabled, .requiresApproval:
            return
        default:
            do {
                try agent.register()
            } catch {
                NSLog("shifu: daemon registration failed: \(error)")
            }
        }
    }

    /// Boots out the ~/Shifu/bin LaunchAgent and deletes its plist and the
    /// scattered binaries. User data (db, vault, digests, logs) lives beside
    /// bin/ in ~/Shifu and is not touched.
    private static func migrateLegacyInstall() {
        guard FileManager.default.fileExists(atPath: legacyPlist.path) else { return }
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/com.shifu.shifud"]
        try? bootout.run()
        bootout.waitUntilExit()
        try? FileManager.default.removeItem(at: legacyPlist)
        try? FileManager.default.removeItem(
            at: ShifuPaths.home.appendingPathComponent("bin", isDirectory: true))
        NSLog("shifu: migrated legacy ~/Shifu/bin daemon to the bundled agent")
    }
}
