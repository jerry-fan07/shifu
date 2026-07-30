import SwiftUI

// The four controls the whole app is built from: one solid button per
// screen, outlined buttons for everything else, a segmented strip for
// exclusive choices, and a menu for the long ones.

/// The one loud control on a screen: ink-filled, small, and never more than
/// one per page.
struct SolidButton: View {
    let title: String
    var action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Instrument.sans(12, .medium))
                .foregroundStyle(Instrument.solidInk)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Instrument.solidFill, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Everything else: outlined, quiet, the same height as the solid one.
struct OutlineButton: View {
    let title: String
    var tinted: Bool
    var action: () -> Void

    init(title: String, tinted: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.tinted = tinted
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Instrument.sans(12))
                .foregroundStyle(tinted ? Instrument.accentDeep : Instrument.railInk)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    tinted ? Instrument.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            tinted ? Instrument.accent : Instrument.edge, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

/// A word that acts like a button — "file it", "All 31", "3 more". The
/// instrument's link register.
struct InlineLink: View {
    let title: String
    var size: CGFloat
    var action: () -> Void

    init(_ title: String, size: CGFloat = 11.5, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Instrument.sans(size))
                .foregroundStyle(Instrument.accentText)
        }
        .buttonStyle(.plain)
    }
}

/// Two or three exclusive choices, joined into one bordered strip: the
/// Day/Week span, the Category/Theme/Task lens. The selected one is filled,
/// because on a page this dense a tint would not survive.
struct SegmentedBar<Option: Hashable>: View {
    let options: [(label: String, value: Option)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                if index > 0 {
                    Rectangle().fill(Instrument.edge).frame(width: 1)
                }
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(Instrument.sans(12, isOn ? .medium : .regular))
                        .foregroundStyle(isOn ? Instrument.solidInk : Instrument.railInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(isOn ? Instrument.solidFill : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Instrument.edge, lineWidth: 1)
        }
        .fixedSize()
    }
}

/// A menu of options with a check on the current one, wearing the outlined
/// pill. Neither a `Picker` nor a `Menu`: menu-style Pickers don't commit
/// their selection on this machine's macOS, and AppKit's menu can't be
/// dressed — so it is a `DropdownButton`, which draws its own panel.
struct FilterMenu<Option: Hashable>: View {
    /// Shown before the value — "Sort: this week". Omitted when nil.
    var prefix: String?
    let options: [(label: String, value: Option)]
    @Binding var selection: Option

    init(
        prefix: String? = nil, options: [(label: String, value: Option)],
        selection: Binding<Option>
    ) {
        self.prefix = prefix
        self.options = options
        self._selection = selection
    }

    var body: some View {
        DropdownButton(
            label: label,
            entries: options.map { option in
                DropdownEntry(option.label, isOn: option.value == selection) {
                    selection = option.value
                }
            })
    }

    private var label: String {
        let current = options.first { $0.value == selection }?.label ?? ""
        guard let prefix else { return current }
        return "\(prefix): \(current)"
    }
}

/// A menu of actions wearing the same outlined pill as `FilterMenu` — "New
/// deck" over the tasks one could be made from. Nothing is checked: none of
/// these is a current state.
struct ActionMenu: View {
    let title: String
    let options: [(label: String, action: () -> Void)]

    var body: some View {
        DropdownButton(
            label: title,
            entries: options.map { DropdownEntry($0.label, action: $0.action) })
    }
}

/// A small outlined tag — a theme on a task row, a filter that is on.
struct Tag: View {
    let text: String
    var tinted: Bool
    var dashed: Bool

    init(_ text: String, tinted: Bool = false, dashed: Bool = false) {
        self.text = text
        self.tinted = tinted
        self.dashed = dashed
    }

    var body: some View {
        Text(text)
            .font(Instrument.sans(11))
            .foregroundStyle(tinted ? Instrument.accentDeep : Instrument.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                tinted ? Instrument.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        tinted ? Instrument.accent : Instrument.edge,
                        style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            }
    }
}
