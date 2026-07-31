// The app icon, drawn rather than painted, and cut once per size.
//
//     swift scripts/icon-source.swift          # writes Sources/ShifuApp/AppIcon.icns
//     swift scripts/icon-source.swift /tmp     # ...and the .iconset beside it, to look at
//
// One mountain in daylight: the warm ground the app started on, a slate ridge
// filling the tile edge to edge, and the vermilion seal risen into a sun.
// `scripts/icon-lab.swift 9` is this same drawing — the lab is where it was
// chosen, out of sixteen, at the sizes below.
//
// **Every slice is drawn at its own size**, rather than resampled from one
// 1,024 master the way `generate-icon.sh` does it. That is not fussiness: the
// same drawing rendered natively at 16 px keeps edges that a downsample turns
// to porridge. Two things follow from the size:
//
//   - **A floor under the sun.** It is 24% of the body, which is 3 px at Dock
//     size and falls to 2 with the wrong rounding; below 32 px it is nudged up
//     until it is at least 3 px across, because a 2 px disc reads as dirt. The
//     icon this replaced carried its seal at 6.5% — 1.7 px — which is what
//     "hard to see" looked like up close.
//   - **No shadow under 128 px.** At 16 it is two rows of mud beneath the tile.
//
// Everything else is deliberately absent. Detail below about a tenth of the
// tile is not small, it is gone.

import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

let paper = Color(hex: 0xF4F0E6)
let slate = Color(hex: 0x1F2430)
let seal = Color(hex: 0xB5401F)

/// The ridge, filled down to the bottom of its frame: one dominant summit left
/// of centre, a saddle, and a second peak. Unit-space points, y from the top.
struct Ridge: Shape {
    var peaks: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for peak in peaks {
            path.addLine(to: CGPoint(
                x: rect.minX + peak.x * rect.width,
                y: rect.minY + peak.y * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

let ridge: [CGPoint] = [
    .init(x: 0.00, y: 1.00), .init(x: 0.40, y: 0.06),
    .init(x: 0.62, y: 0.44), .init(x: 0.78, y: 0.22),
    .init(x: 1.00, y: 1.00)
]

/// One slice. Apple's grid puts an 824 pt body on a 1,024 pt canvas and leaves
/// the margin to the shadow; that ratio holds at every size, snapped so the
/// tile lands on whole pixels.
struct AppIcon: View {
    let pixels: CGFloat

    /// The body, grown by a pixel where the ratio would leave an odd margin —
    /// 16 × 0.805 is 12.875, and a 13 px tile inside a 16 px canvas is centred
    /// on the half pixel, which smears its own rounded edge and everything
    /// drawn against it. Only 16 and 128 need the nudge.
    private var side: CGFloat {
        let ideal = (pixels * 824 / 1_024).rounded()
        return (pixels - ideal).truncatingRemainder(dividingBy: 2) == 0 ? ideal : ideal + 1
    }

    /// 24% of the body, and never under 4 px: a 3 px circle is not a small
    /// disc, it is a plus sign — the centre pixel plus its four neighbours,
    /// with the corners antialiased away.
    private var sun: CGFloat { max((side * 0.24).rounded(), 4) }

    var body: some View {
        ZStack {
            Color.clear
            tile
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
                .shadow(
                    color: .black.opacity(pixels >= 128 ? 0.28 : 0),
                    radius: side * 0.030, y: side * 0.014)
        }
        .frame(width: pixels, height: pixels)
    }

    private var tile: some View {
        ZStack {
            paper
            Circle()
                .fill(seal)
                .frame(width: sun)
                .offset(x: (side * 0.21).rounded(), y: -(side * 0.21).rounded())
            Ridge(peaks: ridge)
                .fill(slate)
                .frame(width: side, height: (side * 0.62).rounded())
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// The ten slices an `.icns` carries, by the names `iconutil` expects.
let slices: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1_024)
]

@MainActor func png(_ pixels: Int) -> Data? {
    let renderer = ImageRenderer(content: AppIcon(pixels: CGFloat(pixels)))
    renderer.scale = 1
    guard let image = renderer.nsImage,
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    return rep.representation(using: .png, properties: [:])
}

@MainActor func run() {
    let keep = CommandLine.arguments.dropFirst().first
    let iconset = URL(
        fileURLWithPath: keep ?? NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    do {
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for slice in slices {
            guard let data = png(slice.pixels) else {
                print("Could not render \(slice.name).")
                exit(1)
            }
            try data.write(to: iconset.appendingPathComponent("\(slice.name).png"))
        }
    } catch {
        print("Could not write \(iconset.path): \(error)")
        exit(1)
    }

    let icns = "Sources/ShifuApp/AppIcon.icns"
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns]
    do {
        try iconutil.run()
        iconutil.waitUntilExit()
    } catch {
        print("Could not run iconutil: \(error)")
        exit(1)
    }
    guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
    if keep == nil { try? FileManager.default.removeItem(at: iconset) }
    print("Wrote \(icns) — \(slices.count) slices, each drawn at its own size."
        + (keep == nil ? "" : "\nSlices kept in \(iconset.path)"))
}

MainActor.assumeIsolated { run() }
