import ShifuCore
import SwiftUI

/// The shape every Settings row takes, and the four catalog rows built on it.
///
/// One shape, one column: what the setting is on the left, the control that
/// changes it on a fixed right-hand edge. The old page let each row size its
/// own control, so a stepper, a segmented strip and a text field started at
/// three different x positions and the page read as a form rather than as a
/// panel of dials. Alignment is the whole point — a column of controls is
/// scannable, a staircase of them is not.

/// A row: title (with an optional standing note beside it), one line of what
/// it does, and the control. `control` may be `EmptyView` — a row with no dial
/// is a statement, and those are load-bearing on this page.
struct SettingRow<Control: View>: View {
    let title: String
    var note: String?
    let help: String
    /// A second paragraph about the *state the control is in*, under the help
    /// about the control itself. One register quieter, because it changes as
    /// you turn the dial and the line above it doesn't.
    var detail: String?
    @ViewBuilder var control: Control

    /// The right-hand edge every control on the page shares. Wide enough for
    /// the widest of them — the four-segment retention strip — and no wider,
    /// since every point here comes off the help text.
    static var controlWidth: CGFloat { 224 }

    init(
        _ title: String, note: String? = nil, help: String, detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.note = note
        self.help = help
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(title)
                            .font(Instrument.sans(13.5, .semibold))
                            .foregroundStyle(Instrument.ink)
                        if let note {
                            Eyebrow(note, size: 9.5, tracking: 0.6)
                        }
                    }
                    Text(help)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(Instrument.muted)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) { control }
                    .frame(width: Self.controlWidth, alignment: .trailing)
            }
            .padding(.vertical, 13)
        }
    }
}

/// The field the text rows share: outlined, mono, and right-aligned so the
/// value ends on the same edge the steppers and strips do.
struct SettingField: View {
    var placeholder: String
    var secure = false
    @Binding var text: String

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(Instrument.mono(11.5))
        .multilineTextAlignment(.trailing)
        .foregroundStyle(Instrument.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Instrument.edge, lineWidth: 1)
        }
    }
}

/// Stepper bounded by the descriptor's own range, with a track under it
/// showing where in that range the value sits. The UI states no limits of its
/// own — it can't drift from what the daemon enforces — but a bare "60 min"
/// doesn't say whether that is nearly nothing or nearly everything, and the
/// track answers that without spending a line of prose on bounds.
struct IntSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: IntSetting

    var body: some View {
        let value = store.value(for: setting)
        SettingRow(setting.title, help: setting.help) {
            HStack(spacing: 8) {
                Figure(setting.display(value), color: Instrument.ink)
                HStack(spacing: 0) {
                    nudge("−", from: value, by: -setting.step)
                    Rectangle().fill(Instrument.edge).frame(width: 1)
                    nudge("+", from: value, by: setting.step)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Instrument.edge, lineWidth: 1)
                }
            }
            RangeTrack(fraction: fraction(of: value))
            Figure(
                "\(setting.display(setting.range.lowerBound)) – "
                    + setting.display(setting.range.upperBound),
                size: 10, color: Instrument.ghost)
        }
    }

    private func fraction(of value: Int) -> Double {
        let span = setting.range.upperBound - setting.range.lowerBound
        guard span > 0 else { return 1 }
        return Double(value - setting.range.lowerBound) / Double(span)
    }

    private func nudge(_ glyph: String, from value: Int, by step: Int) -> some View {
        let next = value + step
        let allowed = setting.range.contains(next)
        return Button {
            store.set(setting, to: next)
        } label: {
            Text(glyph)
                .font(Instrument.sans(12))
                .foregroundStyle(Instrument.railInk)
                .frame(width: 24)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.35)
        .accessibilityLabel(step > 0 ? "Increase \(setting.title)" : "Decrease \(setting.title)")
    }
}

/// Where a bounded value sits between its own limits. A meter, not a slider —
/// it is not draggable, because the step is the setting's own and a drag would
/// invent values between the steps the daemon was designed around.
private struct RangeTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Instrument.well)
                Capsule()
                    .fill(Instrument.accent)
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// The descriptor's own options as a drop-down; unknown stored values render
/// as the default because reads normalize.
///
/// A drop-down and not the segmented strip these rows used to wear. A strip
/// is `fixedSize` — it takes the width its labels ask for and spills over
/// whatever is beside it — and the AI backend's three labels ask for more than
/// the shared control column, so the strip sat against its own help text with
/// no gutter left between them. A drop-down spends one pill's width whatever
/// the labels say, which is also the right register for the row: this is a
/// setting you pick once, not a lens you flick between while reading a chart.
///
/// The help under the title is the *chosen* option's, not a paragraph about
/// all of them. Where your text goes is the only thing this row is really
/// asking, and a reader who has to find their own answer in a wall covering
/// three backends is being asked to consent to something they half-read. It
/// follows the draft, not the saved value: the description you are reading is
/// the one you are about to Save.
struct ChoiceSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: ChoiceSetting

    var body: some View {
        let picked = store.value(for: setting)
        SettingRow(
            setting.title, help: setting.help,
            detail: setting.options.first { $0.value == picked }?.detail
        ) {
            FilterMenu(
                options: setting.options.map { ($0.label, $0.value) },
                selection: store.binding(for: setting))
                .accessibilityLabel(setting.title)
        }
    }
}

/// Free-text row; secure settings (API keys) render as a SecureField.
struct TextSettingRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: TextSetting

    var body: some View {
        SettingRow(setting.title, help: setting.help) {
            SettingField(
                placeholder: setting.placeholder, secure: setting.secure,
                text: store.binding(for: setting))
        }
    }
}

/// "Type a domain, press Add" — worn by Focus Mode's site list and by Privacy's
/// excluded domains, which write to different tables through the same gesture.
///
/// `isValid` is the same normalization the store will apply, so the control can
/// never be armed on input that would be silently dropped — and `onSubmit`
/// consults it too. Enter used to bypass the disabled button and clear the
/// field, which reads as "added" when nothing was.
struct DomainAddField: View {
    let placeholder: String
    @Binding var draft: String
    let isValid: (String) -> Bool
    let add: () -> Void

    var body: some View {
        let valid = isValid(draft)
        HStack(spacing: 6) {
            SettingField(placeholder: placeholder, text: $draft)
                .onSubmit { if valid { add() } }
            OutlineButton(title: "Add") { add() }
                .opacity(valid ? 1 : 0.35)
                .allowsHitTesting(valid)
        }
    }
}

/// Add-row plus a deletable list: type a value, Add appends it, remove drops
/// it. The add field sits on the shared right edge; the list it feeds runs the
/// full width underneath, because a column of domains squeezed into 224 points
/// would truncate the only thing on the row worth reading.
struct DomainListRow: View {
    @EnvironmentObject private var store: SettingsStore
    let setting: DomainListSetting
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(setting.title, help: setting.help) {
                DomainAddField(
                    placeholder: setting.placeholder, draft: $draft,
                    isValid: { setting.normalize($0) != nil },
                    add: { add() })
            }
            ValueList(
                values: store.domains(for: setting),
                empty: "No sites yet.",
                remove: { store.remove($0, from: setting) })
        }
    }

    private func add() {
        store.add(draft, to: setting)
        draft = ""
    }
}

/// A list of stored values under the row that adds to them, each with the way
/// to take it back out. Shared by the Focus Mode site list and the Privacy
/// exclusions, which are the same gesture over three different tables — and by
/// the built-in lists, which pass no `remove` and so render as the same rows
/// without the link. That is the point: a built-in exclusion should look
/// exactly as real as one you added, because it is.
struct ValueList: View {
    let values: [String]
    var empty: String?
    var label: (String) -> String = { $0 }
    var remove: ((String) -> Void)?

    var body: some View {
        if values.isEmpty {
            if let empty {
                Text(empty)
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.ghost)
                    .padding(.bottom, 13)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Rule()
                    HStack {
                        Figure(label(value), size: 12, color: Instrument.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        if let remove {
                            InlineLink("remove") { remove(value) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 9)
        }
    }
}
