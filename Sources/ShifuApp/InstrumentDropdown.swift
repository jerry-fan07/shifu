import AppKit
import SwiftUI

// The instrument's own drop-down (design.md §7).
//
// AppKit's menu can't be dressed: its material, its corner radius, its row
// height and its type are all the system's, and a borderless `Menu`
// additionally throws away everything but the text of its label. So the panel
// is drawn here instead — square-cornered, hairline-bordered, on the
// instrument's own paper, in the instrument's own face.
//
// It hangs in a borderless child window rather than a SwiftUI overlay because
// every control that opens one sits inside a page head, a rail, or a scroll
// view, and a list of thirty decks is taller than all three.

/// One line of a drop-down: what it says, whether it is the current one, and
/// what picking it does.
struct DropdownEntry {
    let label: String
    /// Wears the check, and where the keyboard starts.
    var isOn: Bool
    let action: () -> Void

    init(_ label: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isOn = isOn
        self.action = action
    }
}

/// The control that opens one: the outlined pill by default, a bare word in
/// the rail. Every "pick one of these" in the app is built from this.
struct DropdownButton: View {
    let label: String
    var bordered = true
    var font = Instrument.sans(12)
    var color = Instrument.railInk
    let entries: [DropdownEntry]

    @State private var isOpen = false
    /// Set when the click that closed the panel landed on this pill. Without
    /// it that one click would close the panel on mouse-down and reopen it on
    /// mouse-up, and the control would read as stuck open.
    @State private var closedByPill = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(font)
                .foregroundStyle(isOpen ? Instrument.accentDeep : color)
                .lineLimit(1)
            // Swapped, not rotated: a rotated "⌄" lands in the top half of
            // its own em box and floats above the word beside it.
            Text(isOpen ? "⌃" : "⌄")
                .font(Instrument.sans(10))
                .foregroundStyle(isOpen ? Instrument.accent : Instrument.faint)
                .baselineOffset(isOpen ? 0 : 2)
        }
        .padding(.horizontal, bordered ? 10 : 0)
        .padding(.vertical, bordered ? 4 : 0)
        // The pill wears `OutlineButton`'s radius, not the panel's square
        // corners: it stands beside those buttons in every header.
        .background(
            bordered && isOpen ? Instrument.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if bordered {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOpen ? Instrument.accent : Instrument.edge, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if closedByPill {
                closedByPill = false
            } else {
                isOpen = true
            }
        }
        .background(
            DropdownAnchor(isOpen: $isOpen, closedByPill: $closedByPill, entries: entries))
        .fixedSize(horizontal: bordered, vertical: false)
    }
}

// MARK: - The panel

/// The panel's geometry. Fixed rather than measured by SwiftUI: the window
/// has to be sized before its content is laid out, and a `ScrollView` reports
/// no width of its own.
enum DropdownMetrics {
    static let rowHeight: CGFloat = 23
    static let labelSize: CGFloat = 12
    /// The check's column, so every label starts on the same vertical.
    static let checkWidth: CGFloat = 15
    static let sidePadding: CGFloat = 9
    static let endPadding: CGFloat = 4
    /// Past this the panel scrolls. Counted in rows, not points, so the last
    /// visible one is never sliced by the bottom rule.
    static let maxRows = 12
    static let minWidth: CGFloat = 118
    static let maxWidth: CGFloat = 420
    /// Between the pill and the panel hanging off it.
    static let gap: CGFloat = 3

    static func panelSize(for entries: [DropdownEntry]) -> CGSize {
        let font = Instrument.sansFont(labelSize)
        let widest = entries
            .map { $0.label.size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // +2 for the hairline down each side.
        let width = ceil(widest) + checkWidth + sidePadding * 2 + 2
        let rows = min(entries.count, maxRows)
        return CGSize(
            width: min(maxWidth, max(minWidth, width)),
            height: CGFloat(rows) * rowHeight + endPadding * 2 + 2)
    }
}

/// What the open panel is showing. Owned by the coordinator so the key
/// monitor — which lives in AppKit — and the rows can move one highlight.
@MainActor
private final class DropdownState: ObservableObject {
    @Published var entries: [DropdownEntry] = []
    @Published var highlight = 0
    var pick: (Int) -> Void = { _ in }
}

private struct DropdownList: View {
    @ObservedObject var state: DropdownState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.entries.enumerated()), id: \.offset) { index, entry in
                        row(index, entry)
                    }
                }
                .padding(.vertical, DropdownMetrics.endPadding)
            }
            .onChange(of: state.highlight) { _, index in proxy.scrollTo(index) }
            .onAppear { proxy.scrollTo(state.highlight, anchor: .center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Instrument.ground)
        .overlay { Rectangle().strokeBorder(Instrument.edge, lineWidth: 1) }
    }

    private func row(_ index: Int, _ entry: DropdownEntry) -> some View {
        Button { state.pick(index) } label: {
            HStack(spacing: 0) {
                Text(entry.isOn ? "✓" : "")
                    .font(Instrument.mono(10, .medium))
                    .foregroundStyle(Instrument.accentText)
                    .frame(width: DropdownMetrics.checkWidth, alignment: .leading)
                Text(entry.label)
                    .font(Instrument.sans(DropdownMetrics.labelSize))
                    .foregroundStyle(Instrument.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DropdownMetrics.sidePadding)
            .frame(height: DropdownMetrics.rowHeight)
            .background(index == state.highlight ? Instrument.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .onHover { inside in
            if inside { state.highlight = index }
        }
    }
}

// MARK: - The window it hangs in

/// A zero-sized view behind the pill, there only to give the panel a frame to
/// hang off. It never takes a click — the pill above it does.
private final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct DropdownAnchor: NSViewRepresentable {
    @Binding var isOpen: Bool
    @Binding var closedByPill: Bool
    let entries: [DropdownEntry]

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.entries = entries
        coordinator.onClose = { byPill in
            closedByPill = byPill
            isOpen = false
        }
        if isOpen {
            coordinator.present()
        } else {
            coordinator.tearDown()
        }
    }

    func makeCoordinator() -> DropdownCoordinator { DropdownCoordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: DropdownCoordinator) {
        coordinator.tearDown()
    }
}

@MainActor
final class DropdownCoordinator: NSObject {
    weak var anchor: NSView?
    var entries: [DropdownEntry] = []
    var onClose: (Bool) -> Void = { _ in }

    private let state = DropdownState()
    private var panel: NSPanel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    private enum Key {
        static let escape: UInt16 = 53
        static let carriageReturn: UInt16 = 36
        static let enter: UInt16 = 76
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Opens the panel, or — on the re-renders that happen while it is open —
    /// refreshes what it is showing without moving the highlight.
    func present() {
        guard let anchor, let host = anchor.window, !entries.isEmpty else { return }
        state.entries = entries
        let size = DropdownMetrics.panelSize(for: entries)
        if let panel {
            position(panel, size: size, under: anchor, in: host)
            return
        }
        state.highlight = entries.firstIndex { $0.isOn } ?? 0
        state.pick = { [weak self] index in self?.pick(index) }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: DropdownList(state: state))
        // A window of its own doesn't inherit the one it hangs off: without
        // this the panel stays light on a dark page.
        panel.appearance = host.effectiveAppearance
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        self.panel = panel

        position(panel, size: size, under: anchor, in: host)
        host.addChildWindow(panel, ordered: .above)
        watch(host)
    }

    /// Closes the panel and stops listening. Safe to call when nothing is up.
    func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private func dismiss(byPill: Bool = false) {
        guard panel != nil else { return }
        tearDown()
        onClose(byPill)
    }

    private func pick(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let action = entries[index].action
        // Closed first: the action reshapes the tree that owns this panel.
        dismiss()
        action()
    }

    /// Under the pill, or above it when the screen runs out below.
    private func position(_ panel: NSPanel, size: CGSize, under anchor: NSView, in host: NSWindow) {
        let onScreen = host.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame ?? onScreen
        var origin = CGPoint(
            x: min(max(onScreen.minX, visible.minX + 4), max(visible.maxX - size.width - 4, 4)),
            y: onScreen.minY - DropdownMetrics.gap - size.height)
        if origin.y < visible.minY + 4 {
            origin.y = onScreen.maxY + DropdownMetrics.gap
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Dismissal

    /// A panel pinned to a point on screen is wrong the moment that point
    /// moves, so anything that moves it closes it.
    private func watch(_ host: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        if event.type == .keyDown { return handleKey(event) }
        guard event.window !== panel else { return event }
        dismiss(byPill: event.type != .scrollWheel && hitsPill(event))
        return event
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case Key.escape:
            dismiss()
        case Key.down:
            state.highlight = min(state.highlight + 1, max(entries.count - 1, 0))
        case Key.up:
            state.highlight = max(state.highlight - 1, 0)
        case Key.carriageReturn, Key.enter:
            pick(state.highlight)
        default:
            return event
        }
        return nil
    }

    private func hitsPill(_ event: NSEvent) -> Bool {
        guard let anchor, let host = anchor.window, event.window === host else { return false }
        return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }
}
