import AppKit
import ShifuCore
import SwiftUI

/// First-run onboarding (design.md §7): four screens — what's captured,
/// permissions, exclusions, analysis backend. Local-only is the default.
struct OnboardingView: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var page = 0
    @State private var backend = "auto"
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 20) {
            Group {
                switch page {
                case 0: whatPage
                case 1: permissionsPage
                case 2: exclusionsPage
                default: backendPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                Text("\(page + 1) / 4").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if page < 3 {
                    Button("Next") { page += 1 }.buttonStyle(.borderedProminent)
                } else {
                    Button("Start watching") { finish() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
    }

    private var whatPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shifu watches you work").font(.title2).bold()
            Text("""
            Shifu captures **text and metadata** about what's on your screen — app, \
            window title, visible text — and turns it into a time ledger, a knowledge \
            vault, and automation suggestions.

            What it never does:
            • never records keystrokes
            • never saves screenshots — pixels live in memory only for OCR
            • never sends raw captures anywhere — everything stays on this Mac
            """)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions").font(.title2).bold()
            Text("""
            The capture daemon (`shifud`, installed at ~/Shifu/bin) needs two \
            permissions, granted in System Settings → Privacy & Security:

            • **Accessibility** — window titles and visible text (the cheap path)
            • **Screen Recording** — the OCR fallback for apps that expose no text

            Without them Shifu degrades gracefully to app-switch metadata only.
            """)
            HStack {
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("Open Screen Recording Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    private var exclusionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded by default").font(.title2).bold()
            Text("""
            Exclusions are enforced **before** capture — excluded content is never \
            read, only opaque "private time" duration is counted:

            • password managers and Keychain
            • banking, payment, and health sites
            • private/incognito browser windows (always, not configurable)
            • credit cards, SSNs, and secret-shaped strings are redacted from all \
            text before it ever touches disk

            Add your own exclusions with the `exclusions` table (UI arrives later).
            """)
        }
    }

    private var backendPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysis backend").font(.title2).bold()
            Text("Ambiguous time blocks and knowledge extraction can use a language model.")
            Picker("", selection: $backend) {
                Text("Local only (on-device Apple model when available)").tag("auto")
                Text("Claude API — sends text samples to Anthropic, opt-in").tag("claude")
            }
            .pickerStyle(.radioGroup)
            if backend == "claude" {
                SecureField("Anthropic API key (or set ANTHROPIC_API_KEY)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Only derived text samples are sent, after exclusions and redaction. Never pixels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        if let database = try? ShifuDatabase.open(at: ShifuPaths.database) {
            try? Settings.set(Settings.analysisBackendKey, to: backend, database: database)
            if backend == "claude" && !apiKey.isEmpty {
                try? Settings.set(Settings.claudeAPIKeyKey, to: apiKey, database: database)
            }
        }
        onboarded = true
    }
}
