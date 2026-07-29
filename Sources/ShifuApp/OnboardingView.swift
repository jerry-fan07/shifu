import AppKit
import ShifuCore
import SwiftUI

/// First-run onboarding (design.md §7): the sensei introduces himself, then
/// four screens — what's captured, permissions, exclusions, analysis backend.
/// Local-only is the default. Rendered as one card centered on the paper.
struct OnboardingView: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var page = 0
    @State private var backend = "deepseek"
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 18) {
            SenseiFigure(size: 92, mood: page == 3 ? .proud : .serene)
            Group {
                switch page {
                case 0: whatPage
                case 1: permissionsPage
                case 2: exclusionsPage
                default: backendPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(26)
        .frame(width: 560, height: 540)
        .dojoCard(padding: 0)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Dojo.paper)
    }

    private var footer: some View {
        HStack {
            if page > 0 { Button("Back") { page -= 1 } }
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { dot in
                    Circle()
                        .fill(dot == page ? Dojo.accent : Dojo.well)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page < 3 {
                Button("Next") { page += 1 }.buttonStyle(.borderedProminent)
            } else {
                Button("Begin the practice") { finish() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var whatPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I am Shifu. I watch you work.").font(.title2).bold()
            // Literal strings, not concatenations: Text only parses the
            // **markdown** through its LocalizedStringKey initializer.
            Text("""
            Not to judge — to remember. I capture **text and metadata** about \
            what's on your screen — app, window title, visible text — and turn it \
            into a time ledger, a knowledge vault, and automation suggestions.
            """)
            Text("""
            Raw captured text is deleted after 14 days; the distilled work notes \
            in your vault persist beyond that window.
            """)
            Text("""
            What I never do:
            • never record keystrokes
            • never save screenshots — pixels live in memory only for OCR
            • never send raw captures anywhere — analysis sends only redacted \
            text samples to DeepSeek, and only after you add an API key
            """)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two permissions").font(.title2).bold()
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
            Text("What stays unseen").font(.title2).bold()
            Text("""
            Exclusions are enforced **before** capture — excluded content is never \
            read, only opaque "private time" duration is counted:

            • password managers and Keychain
            • banking, payment, and health sites
            • private/incognito browser windows (always, not configurable)
            • credit cards, SSNs, and secret-shaped strings are redacted from all \
            text before it ever touches disk
            """)
        }
    }

    private var backendPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A mentor may consult").font(.title2).bold()
            Text("Task naming, ambiguous-time classification, and knowledge "
                + "extraction use DeepSeek. Without an API key those stages are "
                + "skipped and Shifu runs on rules alone.")
            Picker("", selection: $backend) {
                Text("DeepSeek — sends redacted text samples once a key is set").tag("deepseek")
                Text("Rules only — no AI, nothing ever leaves this Mac").tag("off")
            }
            .pickerStyle(.radioGroup)
            if backend == "deepseek" {
                SecureField("DeepSeek API key (or set DEEPSEEK_API_KEY)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Defaults: deepseek-v4-flash for classification, deepseek-v4-pro "
                    + "for task grouping; change either in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only derived text samples are sent, after exclusions and redaction. Never pixels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        if let database = try? ShifuDatabase.open(at: ShifuPaths.database) {
            try? Settings.set(Settings.analysisBackendKey, to: backend, database: database)
            if backend == "deepseek" && !apiKey.isEmpty {
                try? Settings.set(Settings.deepseekAPIKeyKey, to: apiKey, database: database)
            }
        }
        onboarded = true
    }
}
