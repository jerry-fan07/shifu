import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// A camera pointed at the rail's foot in both of its states, plus the one
/// measurement that says whether they agree.
///
/// Focus Mode off is a plain row; on, it is the ink slab. They are different
/// views of different heights, and the whole point of the layout is that the
/// name and the switch don't move between them — the slab opens *upward* into
/// the rail's spacer. Two pictures settle whether it looks right; only pixels
/// settle whether the switch is on the same line, and a few points of drift is
/// exactly the amount an eye forgives and a pointer doesn't.
///
/// Opt-in, and only against a copy: turning Focus Mode on writes the control
/// file that *is* the session start, and this must never do that to ~/Shifu.
///
///     SHIFU_SHOTS=/tmp/shifu-shots SHIFU_HOME=/tmp/shifu-verify \
///         swift test --filter FocusFootShots
@Suite struct FocusFootShots {
    @MainActor @Test func theSwitchStaysPutWhenTheSlabOpens() throws {
        guard let raw = ProcessInfo.processInfo.environment["SHIFU_SHOTS"],
              ProcessInfo.processInfo.environment["SHIFU_HOME"] != nil
        else { return }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let store = LedgerStore()
        store.refresh()
        let wasOn = store.focusModeOn
        defer {
            if store.focusModeOn != wasOn { store.toggleFocusMode() }
        }

        if store.focusModeOn { store.toggleFocusMode() }
        let off = try #require(shoot(store: store, as: "focus-foot-off", into: directory))
        store.toggleFocusMode()
        #expect(store.focusModeOn)
        let on = try #require(shoot(store: store, as: "focus-foot-on", into: directory))

        let offSwitch = try #require(off.switchBox())
        let onSwitch = try #require(on.switchBox())
        let offText = try #require(off.inkLeft(rows: offSwitch))
        let onText = try #require(on.inkLeft(rows: onSwitch))
        print("""
            off switch y \(offSwitch.lowerBound)…\(offSwitch.upperBound), text x \(offText)
            on  switch y \(onSwitch.lowerBound)…\(onSwitch.upperBound), text x \(onText)
            """)

        // One point of slack for rounding, and no more: the claim in
        // `FocusModeRailRow` is that these land on the same pixel.
        #expect(abs(offSwitch.lowerBound - onSwitch.lowerBound) <= 1)
        #expect(abs(offSwitch.upperBound - onSwitch.upperBound) <= 1)
        #expect(abs(offText - onText) <= 1)
    }

    /// The window, filed and handed back as a probe over its own pixels.
    @MainActor private func shoot(
        store: LedgerStore, as name: String, into directory: URL
    ) -> RailFoot? {
        // `SHIFU_SHOT_HEIGHT`, as everywhere else: the slab is 53 pt taller
        // than the row it replaces and it grows into the rail's spacer, so
        // 620 — the `minHeight` the shell declares — is the height that says
        // whether the places above it still fit.
        let raw = ProcessInfo.processInfo.environment["SHIFU_SHOT_HEIGHT"]
        let height = raw.flatMap { Double($0) } ?? 760
        let size = CGSize(width: 1_180, height: height)
        let router = Router()
        router.go(to: .breakdown)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: MainWindow(router: router).environmentObject(store))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
        return RailFoot(bitmap: bitmap, points: size)
    }
}

/// The rail's foot, read off the film in *points* — the units the layout was
/// written in, whatever the backing scale of the Mac that ran it.
private struct RailFoot {
    let bitmap: NSBitmapImageRep
    let points: CGSize

    private var scale: CGFloat { CGFloat(bitmap.pixelsWide) / points.width }

    /// `ToggleSwitch` is 28 × 16 pt hung on the rail's right inset, so its band
    /// is known before anything is measured; what isn't known is the row it
    /// sits on. Every pixel in the band is compared against the ground just
    /// outside it on the same row — which is the rail in one state and the
    /// slab's surface in the other, so neither needs naming.
    ///
    /// The band is filled by more than the switch: the section rule crosses it,
    /// and in the open state so do the right-hand candles. Both are answered by
    /// taking the *last* run tall enough to be a switch — the rule is one row,
    /// and the chart is above the foot by construction.
    /// Returns the switch's top and bottom in points from the top of the film.
    func switchBox() -> ClosedRange<CGFloat>? {
        let left = Int((Instrument.railWidth - 22 - 28) * scale) + 2
        let right = Int((Instrument.railWidth - 22) * scale) - 2
        let band = left...right
        var runs: [ClosedRange<Int>] = []
        for row in rows {
            let filled = band.filter { differs(column: $0, row: row) }.count > band.count / 2
            if filled, let last = runs.last, last.upperBound == row - 1 {
                runs[runs.count - 1] = last.lowerBound...row
            } else if filled {
                runs.append(row...row)
            }
        }
        guard let box = runs.last(where: { $0.count >= Int(8 * scale) }) else { return nil }
        return CGFloat(box.lowerBound) / scale...CGFloat(box.upperBound) / scale
    }

    /// The leftmost ink on the switch's own rows: the "Focus Mode" label.
    func inkLeft(rows box: ClosedRange<CGFloat>) -> CGFloat? {
        for column in Int(10 * scale)...Int(120 * scale) {
            for row in Int(box.lowerBound * scale)...Int(box.upperBound * scale)
            where differs(column: column, row: row) {
                return CGFloat(column) / scale
            }
        }
        return nil
    }

    /// The bottom third of the film, where the rail's foot lives — high enough
    /// to clear the capture line, low enough to miss the places.
    private var rows: StrideThrough<Int> {
        stride(
            from: Int((points.height - 200) * scale),
            through: bitmap.pixelsHigh - 1, by: 1)
    }

    /// Against the ground on the same row, sampled between the switch and the
    /// rail's edge: clear of the rule (which stops at 210) and inside the
    /// slab's straight edge (its corner curve starts at 214), so the sample is
    /// the plain ground in both states.
    private func differs(column: Int, row: Int) -> Bool {
        guard let ink = color(column: column, row: row),
              let ground = color(column: Int(212 * scale), row: row)
        else { return false }
        let delta = abs(ink.redComponent - ground.redComponent)
            + abs(ink.greenComponent - ground.greenComponent)
            + abs(ink.blueComponent - ground.blueComponent)
        return delta > 0.05
    }

    private func color(column: Int, row: Int) -> NSColor? {
        guard column >= 0, row >= 0, column < bitmap.pixelsWide, row < bitmap.pixelsHigh
        else { return nil }
        return bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
    }
}
