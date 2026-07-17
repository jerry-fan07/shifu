import AppKit

/// The glow pulse (design.md §4.4): a full-screen, click-through overlay that
/// breathes a soft colored vignette at the screen edges for ~2 s, then fades.
/// No sound, no modal, no text — a nudge, not a scold.
@MainActor
final class GlowOverlay {
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
            window.contentView = VignetteView(frame: screen.frame)
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }

        // Breathe in (0.8 s), hold implicitly, breathe out (1.2 s).
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.8
            for window in windows { window.animator().alphaValue = 1 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 1.2
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
}

/// Soft amber vignette: transparent center, gentle color at the edges.
private final class VignetteView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let edge = NSColor.systemOrange.withAlphaComponent(0.30)
        guard let gradient = NSGradient(
            colorsAndLocations: (.clear, 0.0), (.clear, 0.62), (edge, 1.0)
        ) else { return }
        gradient.draw(in: bounds, relativeCenterPosition: .zero)
    }
}
