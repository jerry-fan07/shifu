import AppKit
import ShifuCore
import SwiftUI

/// First-run onboarding (design.md §7): four screens — what's captured,
/// permissions, exclusions, analysis backend — under a scene that walks from
/// dusk to daylight as you go, so finishing the flow lands on a morning.
/// Local-only is the default.
struct OnboardingView: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var page = 0
    @State private var backend = "deepseek"
    @State private var apiKey = ""

    private static let pageCount = 4
    /// One sky per step. The arc is deliberate: you arrive at night and leave
    /// in daylight.
    private static let skies: [SkyTime] = [.dusk, .night, .dawn, .day]

    private var sky: SkyTime { Self.skies[min(page, Self.skies.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            banner
            ScrollView {
                Group {
                    switch page {
                    case 0: whatPage
                    case 1: permissionsPage
                    case 2: exclusionsPage
                    default: backendPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 620)
        .background(Dojo.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Dojo.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Dojo.paper)
    }

    private var banner: some View {
        ShifuScene(
            time: sky, mood: page == Self.pageCount - 1 ? .proud : .serene,
            petSize: 84)
            .frame(height: 190)
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [
                        sky.palette.skyColors[0].opacity(0.55),
                        sky.palette.skyColors[0].opacity(0)
                    ],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 300)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SHIFU · STEP \(page + 1) OF \(Self.pageCount)")
                        .font(Dojo.label())
                        .tracking(1.6)
                        .foregroundStyle(sky.palette.secondaryTextColor)
                    Text(title)
                        .font(Dojo.display(26))
                        // Narrow enough that the longest title wraps before it
                        // reaches the temple on the mid ridge.
                        .frame(maxWidth: 250, alignment: .leading)
                        .foregroundStyle(sky.palette.textColor)
                }
                .padding(22)
            }
            .animation(.easeInOut(duration: 0.45), value: page)
    }

    private var title: String {
        switch page {
        case 0: return "I watch you work."
        case 1: return "Two permissions."
        case 2: return "What stays unseen."
        default: return "A mentor may consult."
        }
    }

    private var footer: some View {
        HStack {
            if page > 0 {
                Button("Back") { withAnimation { page -= 1 } }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { dot in
                    Capsule()
                        .fill(dot == page ? Dojo.accent : Dojo.well)
                        .frame(width: dot == page ? 16 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: page)
            Spacer()
            if page < Self.pageCount - 1 {
                Button("Next") { withAnimation { page += 1 } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Begin the practice") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var whatPage: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            promises
        }
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("what I never do")
            ForEach([
                "never record keystrokes",
                "never save screenshots — pixels live in memory only for OCR",
                "never send raw captures anywhere — analysis sends only redacted "
                    + "text samples to DeepSeek, and only after you add an API key"
            ], id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Dojo.accentText)
                    Text(line)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Dojo.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Task naming, ambiguous-time classification, and knowledge "
                + "extraction use DeepSeek. Without an API key those stages are "
                + "skipped and Shifu runs on rules alone.")
            Picker("", selection: $backend) {
                Text("DeepSeek — sends redacted text samples once a key is set").tag("deepseek")
                Text("Rules only — no AI, nothing ever leaves this Mac").tag("off")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if backend == "deepseek" {
                SecureField("DeepSeek API key (or set DEEPSEEK_API_KEY)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Defaults: deepseek-v4-flash for classification, deepseek-v4-pro "
                    + "for task grouping; change either in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only derived text samples are sent, after exclusions and "
                    + "redaction. Never pixels.")
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
