import Foundation
import GRDB

/// Tier-1 classification (design.md §4.2): a mapping of bundle IDs and URL
/// domains → categories. Instant, covers most blocks; `*`-marked ambiguous
/// entries always escalate to the LLM tier (Phase 3).
public struct RulesClassifier: Sendable {
    public struct Rule: Sendable {
        public var category: Category
        public var ambiguous: Bool

        public init(_ category: Category, ambiguous: Bool = false) {
            self.category = category
            self.ambiguous = ambiguous
        }
    }

    public struct Result: Equatable, Sendable {
        public var category: Category
        public var ambiguous: Bool
        public var source: String   // "rules" | "user"
    }

    // MARK: - Seed defaults (user-overridable via the `rules` table)

    static let seedBundles: [String: Rule] = [
        // work
        "com.apple.dt.Xcode": Rule(.work),
        "com.microsoft.VSCode": Rule(.work),
        "com.todesktop.230313mzl4w4u92": Rule(.work),      // Cursor
        "com.googlecode.iterm2": Rule(.work),
        "com.apple.Terminal": Rule(.work),
        "dev.warp.Warp": Rule(.work),
        "com.figma.Desktop": Rule(.work),
        "com.anthropic.claudefordesktop": Rule(.work),
        "com.jetbrains.intellij": Rule(.work),
        "com.sublimetext.4": Rule(.work),
        // communication
        "com.tinyspeck.slackmacgap": Rule(.communication),
        "com.hnc.Discord": Rule(.communication, ambiguous: true),
        "com.apple.MobileSMS": Rule(.communication),
        "us.zoom.xos": Rule(.communication),
        "com.microsoft.teams2": Rule(.communication),
        "com.facebook.archon": Rule(.communication),        // Messenger
        // admin
        "com.apple.mail": Rule(.admin),
        "com.apple.iCal": Rule(.admin),
        "com.apple.finder": Rule(.admin),
        "com.apple.systempreferences": Rule(.admin),
        "com.apple.ActivityMonitor": Rule(.admin),
        // entertainment
        "com.spotify.client": Rule(.entertainment),
        "com.apple.Music": Rule(.entertainment),
        "com.apple.TV": Rule(.entertainment),
        "com.colliderli.iina": Rule(.entertainment),
        "org.videolan.vlc": Rule(.entertainment),
        // learning
        "com.apple.iBooksX": Rule(.learning),
        "com.kindle.Kindle": Rule(.learning),
        // browsers are classified by domain; the bundle alone is ambiguous
        "com.apple.Safari": Rule(.unclassified, ambiguous: true),
        "com.google.Chrome": Rule(.unclassified, ambiguous: true),
        "org.mozilla.firefox": Rule(.unclassified, ambiguous: true),
        "company.thebrowser.Browser": Rule(.unclassified, ambiguous: true)
    ]

    static let seedDomains: [String: Rule] = [
        // work
        "github.com": Rule(.work),
        "linear.app": Rule(.work),
        "notion.so": Rule(.work),
        "figma.com": Rule(.work),
        "docs.google.com": Rule(.work),
        "vercel.com": Rule(.work),
        "localhost": Rule(.work),
        "stackoverflow.com": Rule(.work, ambiguous: true),
        "claude.ai": Rule(.work, ambiguous: true),
        "chatgpt.com": Rule(.work, ambiguous: true),
        // learning
        "developer.apple.com": Rule(.learning),
        "wikipedia.org": Rule(.learning),
        "arxiv.org": Rule(.learning),
        "coursera.org": Rule(.learning),
        "khanacademy.org": Rule(.learning),
        "medium.com": Rule(.learning, ambiguous: true),
        "news.ycombinator.com": Rule(.learning, ambiguous: true),
        // entertainment
        "youtube.com": Rule(.entertainment, ambiguous: true),
        "netflix.com": Rule(.entertainment),
        "twitch.tv": Rule(.entertainment),
        "hulu.com": Rule(.entertainment),
        "disneyplus.com": Rule(.entertainment),
        "spotify.com": Rule(.entertainment),
        // social
        "twitter.com": Rule(.social, ambiguous: true),
        "x.com": Rule(.social, ambiguous: true),
        "instagram.com": Rule(.social),
        "facebook.com": Rule(.social),
        "tiktok.com": Rule(.social),
        "linkedin.com": Rule(.social, ambiguous: true),
        "reddit.com": Rule(.social, ambiguous: true),
        // communication
        "slack.com": Rule(.communication),
        "discord.com": Rule(.communication, ambiguous: true),
        "web.whatsapp.com": Rule(.communication),
        "meet.google.com": Rule(.communication),
        // admin (design.md example: mail → admin)
        "mail.google.com": Rule(.admin),
        "gmail.com": Rule(.admin),
        "outlook.live.com": Rule(.admin),
        "calendar.google.com": Rule(.admin),
        "amazon.com": Rule(.admin, ambiguous: true)
    ]

    private var userBundles: [String: Rule]
    private var userDomains: [String: Rule]

    public init(userBundles: [String: Rule] = [:], userDomains: [String: Rule] = [:]) {
        self.userBundles = userBundles
        self.userDomains = userDomains
    }

    /// Loads user overrides from the `rules` table.
    public init(database: ShifuDatabase) throws {
        var bundles: [String: Rule] = [:]
        var domains: [String: Rule] = [:]
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT kind, value, category, ambiguous FROM rules")
            for row in rows {
                let kind: String = row["kind"]
                let value: String = row["value"]
                guard let category = Category(rawValue: row["category"]) else { continue }
                let rule = Rule(category, ambiguous: (row["ambiguous"] as Int64? ?? 0) != 0)
                if kind == "bundle" { bundles[value] = rule } else { domains[value.lowercased()] = rule }
            }
        }
        self.init(userBundles: bundles, userDomains: domains)
    }

    public func classify(block: Sessionizer.Block) -> Result {
        // Excluded blocks are opaque private time, never inspected (§13.5).
        if block.excluded {
            return Result(category: .privateTime, ambiguous: false, source: "rules")
        }
        // Domain beats bundle (a browser is just a vehicle); user beats seed.
        if let domain = block.domain {
            if let rule = lookupDomain(domain, in: userDomains) {
                return Result(category: rule.category, ambiguous: rule.ambiguous, source: "user")
            }
            if let rule = lookupDomain(domain, in: Self.seedDomains) {
                return Result(category: rule.category, ambiguous: rule.ambiguous, source: "rules")
            }
        }
        if let rule = userBundles[block.appBundle] {
            return Result(category: rule.category, ambiguous: rule.ambiguous, source: "user")
        }
        if let rule = Self.seedBundles[block.appBundle] {
            return Result(category: rule.category, ambiguous: rule.ambiguous, source: "rules")
        }
        return Result(category: .unclassified, ambiguous: true, source: "rules")
    }

    /// Exact match, then parent domains (`docs.google.com` → `google.com` misses,
    /// but `gist.github.com` → `github.com` hits).
    private func lookupDomain(_ domain: String, in table: [String: Rule]) -> Rule? {
        if let rule = table[domain] { return rule }
        var parts = domain.split(separator: ".")
        while parts.count > 2 {
            parts.removeFirst()
            if let rule = table[parts.joined(separator: ".")] { return rule }
        }
        return nil
    }
}
