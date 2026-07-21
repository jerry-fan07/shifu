import AppKit

/// The glow pulse (design.md §4.4): a full-screen, click-through overlay that
/// breathes a soft colored vignette at the screen edges for ~2 s, then fades,
/// with a translucent motivational line centered on the main screen.
@MainActor
final class GlowOverlay {
    static let message = "Believe in yourself"

    private var windows: [NSWindow] = []

    func pulse() {
        guard windows.isEmpty else { return }   // one pulse at a time
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless,
                backing: .buffered, defer: false
            )
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let contentView = VignetteView(frame: screen.frame)
            if screen == NSScreen.main {
                contentView.addSubview(makeMessageLabel(in: screen.frame))
            }
            window.contentView = contentView
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Breathe in (1.6 s), hold implicitly, breathe out (2.4 s).
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1.6
            for window in windows { window.animator().alphaValue = 1 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 2.4
                    for window in self.windows { window.animator().alphaValue = 0 }
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        for window in self.windows { window.orderOut(nil) }
                        self.windows = []
                    }
                })
            }
        })
    }

    private func makeMessageLabel(in screenFrame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: Self.message)
        label.font = .systemFont(ofSize: 84, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.55)
        label.alignment = .center
        label.sizeToFit()
        let size = label.frame.size
        label.frame = NSRect(
            x: (screenFrame.width - size.width) / 2,
            y: (screenFrame.height - size.height) / 2,
            width: size.width, height: size.height
        )
        return label
    }
}

/// Amber vignette: transparent center, bold color at the edges.
private final class VignetteView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let edge = NSColor.systemOrange.withAlphaComponent(0.55)
        guard let gradient = NSGradient(
            colorsAndLocations: (.clear, 0.0), (.clear, 0.25), (edge, 1.0)
        ) else { return }
        gradient.draw(in: bounds, relativeCenterPosition: .zero)
    }
}
