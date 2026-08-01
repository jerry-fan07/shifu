import ShifuCore
import SwiftUI

/// First run (design.md §7): six beats — what is captured, the two permissions,
/// what stays unseen, whether a model may be consulted, what Focus Mode does,
/// and what the first hour looks like. Local-only is the default, and every
/// screen's job is to make the next one unsurprising.
///
/// It is laid out as the window it hands you: a rail on the left listing the
/// six beats, a page on the right. Onboarding is the one place a permanent
/// source list can be *taught* rather than discovered, so it wears one — by
/// "Begin" the user has already used the window's single navigation idea, and
/// found the rail's foot, which is where Focus Mode and the capture line live
/// for the rest of the app's life.
///
/// The beats themselves are in OnboardingBeats.swift; what is decided is here.
struct OnboardingView: View {
    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var step: Int
    /// Off until chosen — the consent gate (§8). For a screen observer,
    /// sending anything anywhere must be the user's affirmative act, so the
    /// cloud options are never preselected.
    @State private var backend: String
    @State private var apiKey = ""
    /// The rail's foot carries the real switch on the Focus Mode beat, writing
    /// the same control file the app and the CLI read. Off is where it starts,
    /// and running the demonstration does not change it.
    @State private var focusModeOn = FocusModeFile.isOn()
    @StateObject private var demo = NudgeDemo()

    /// The panel's own size, centred in whatever window hosts it. Fixed rather
    /// than filling: a first-run flow stretched to 1280 pt would set forty-word
    /// lines and preview a rail three times the width of the real one.
    private static let panelWidth: CGFloat = 660
    private static let panelHeight: CGFloat = 460
    private static let railWidth: CGFloat = 196

    /// The parameters exist for WindowShots, which can't click through the
    /// flow; the app always starts at the first step with analysis off.
    init(step: Int = 0, backend: String = "off") {
        _step = State(initialValue: step)
        _backend = State(initialValue: backend)
    }

    private var beat: Beat { Beat.allCases[min(max(step, 0), Beat.allCases.count - 1)] }

    var body: some View {
        HStack(spacing: 0) {
            rail
            page
        }
        .frame(maxWidth: Self.panelWidth, maxHeight: Self.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Instrument.edge, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Instrument.ground)
    }

    // MARK: - The rail

    private var rail: some View {
        RailColumn {
            VStack(alignment: .leading, spacing: 1) {
                Text("Shifu")
                    .font(Instrument.sans(14, .semibold))
                    .tracking(-0.14)
                    .foregroundStyle(Instrument.ink)
                Figure(
                    "first run · \(Beat.allCases.count) steps",
                    size: 10.5, color: Instrument.faint)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            ForEach(Beat.allCases) { entry in
                BeatRow(
                    beat: entry, current: entry == beat,
                    // Backwards only. The rail is navigation, not a way past a
                    // page you haven't read.
                    action: entry.rawValue < step ? { step = entry.rawValue } : nil)
            }
        } footer: {
            railFoot
        }
        .frame(width: Self.railWidth)
        .background(Instrument.rail)
    }

    /// What the rail's foot says on each beat. It is the app's status corner,
    /// so it carries the promise that most needs saying here — and on the last
    /// two beats, the two things that will actually live there.
    @ViewBuilder private var railFoot: some View {
        switch beat {
        case .focus:
            HStack(spacing: 8) {
                Text("Focus Mode")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.railInk)
                Spacer(minLength: 0)
                ToggleSwitch(isOn: focusModeOn) { toggleFocusMode() }
            }
            Figure("the switch lives here too", size: 10.5, color: Instrument.ghost)
        case .firstHour:
            HStack(spacing: 6) {
                StatusDot()
                Text("Watching")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.railInk)
            }
            Figure("ledger empty", size: 10.5, color: Instrument.ghost)
        default:
            if let promise = beat.promise {
                Text(promise)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.railInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if beat == .capture {
                Figure("ledger empty", size: 10.5, color: Instrument.ghost)
            }
        }
    }

    // MARK: - The page

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(beat.ordinal, tracking: 1)
                .padding(.bottom, 6)
            Text(beat.title)
                .font(Instrument.sans(24, .semibold))
                .tracking(-0.36)
                .foregroundStyle(Instrument.ink)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content(of: beat) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Rule(weight: .section)
            footer
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Instrument.ground)
    }

    @ViewBuilder private func content(of beat: Beat) -> some View {
        switch beat {
        case .capture: CaptureBeat()
        case .permissions: PermissionsBeat()
        case .exclusions: ExclusionsBeat()
        case .backend: BackendBeat(backend: $backend, apiKey: $apiKey)
        case .focus: FocusBeat(demo: demo)
        case .firstHour: FirstHourBeat()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                InlineLink("Back", size: 12.5) { step -= 1 }
            }
            if let note = beat.note {
                Figure(note, size: 11, color: Instrument.ghost)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if beat == .firstHour {
                SolidButton(title: "Begin", action: finish)
            } else {
                SolidButton(title: "Next") { step += 1 }
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func toggleFocusMode() {
        if focusModeOn {
            FocusModeFile.turnOff()
        } else {
            try? FocusModeFile.turnOn()
        }
        focusModeOn = FocusModeFile.isOn()
    }

    private func finish() {
        if let database = try? ShifuDatabase.open(at: ShifuPaths.database) {
            try? Settings.set(Settings.analysisBackendKey, to: backend, database: database)
            if backend == "deepseek" && !apiKey.isEmpty {
                try? Settings.set(Settings.deepseekAPIKeyKey, to: apiKey, database: database)
            }
        }
        onboarded = true
        // Now — and only now — the daemon may start watching.
        DaemonService.syncRegistration()
    }
}
