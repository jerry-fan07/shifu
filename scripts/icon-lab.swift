// Icon iterations, side by side at the sizes that actually matter.
//
//     swift scripts/icon-lab.swift            # /tmp/icon-lab/sheet.png, context.png, one PNG each
//     swift scripts/icon-lab.swift 12         # cut candidate 12 and install it as the app icon
//
// An app icon is judged at 32 points in a Dock and 16 in a Finder list, where
// hairlines vanish and anything under ~12% of the tile is a speck. `sheet.png`
// draws every candidate at 128, 64, 32 and 16, each blown back up with no
// smoothing, so what survives is what you see. `context.png` then sets the two
// small sizes on white, grey and near-black, because "hard to see" is a
// statement about a background, not about an icon.

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

// The Instrument palette (Sources/ShifuApp/Instrument.swift), plus the warm
// paper and seal the first icon was cut from.
enum Ink {
    static let paper = Color(hex: 0xF4F0E6)
    static let bright = Color(hex: 0xFBFBFA)
    static let ink = Color(hex: 0x1C1C1A)
    static let slate = Color(hex: 0x1F2430)
    static let accent = Color(hex: 0x3A5F8A)
    static let deep = Color(hex: 0x27405F)
    static let seal = Color(hex: 0xB5401F)
}

/// A ridge filled down to the bottom of its frame. Unit-space peaks, y from
/// the top.
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

/// The menu bar mark's own polyline, as a stroke.
struct RidgeStroke: Shape {
    var peaks: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, peak) in peaks.enumerated() {
            let point = CGPoint(
                x: rect.minX + peak.x * rect.width,
                y: rect.minY + peak.y * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The mountain as the design actually describes it (§7): a stair of terraces
/// climbing to a summit, not a smooth cone. `treads` steps up, then one face
/// straight back down.
struct Terraces: Shape {
    var treads: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rise = rect.height / CGFloat(treads)
        let run = rect.width * 0.62 / CGFloat(treads)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for step in 0..<treads {
            let top = rect.maxY - rise * CGFloat(step + 1)
            let left = rect.minX + run * CGFloat(step)
            path.addLine(to: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left + run, y: top))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Apple's grid: an 824 pt body on a 1,024 pt canvas, the rest left to the
/// shadow.
struct Tile<Content: View>: View {
    static var body_: CGFloat { 824 }
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        ZStack {
            Color.clear
            content(Self.body_)
                .frame(width: Self.body_, height: Self.body_)
                .clipShape(
                    RoundedRectangle(cornerRadius: Self.body_ * 0.2237, style: .continuous))
                .shadow(
                    color: .black.opacity(0.28),
                    radius: Self.body_ * 0.030, y: Self.body_ * 0.014)
        }
        .frame(width: 1_024, height: 1_024)
    }
}

// MARK: - Shared silhouettes

/// The app's own ridge: one dominant peak left of centre, a shoulder, and a
/// second summit — asymmetric on purpose. A symmetric three-peak range with a
/// disc beside it is the universal "image file" glyph, which is what round one
/// kept accidentally drawing.
let appRidge: [CGPoint] = [
    .init(x: 0.00, y: 1.00), .init(x: 0.34, y: 0.02),
    .init(x: 0.55, y: 0.50), .init(x: 0.72, y: 0.20),
    .init(x: 1.00, y: 1.00)
]

let markPeaks: [CGPoint] = [
    .init(x: 0.06, y: 0.74), .init(x: 0.36, y: 0.20), .init(x: 0.58, y: 0.54),
    .init(x: 0.74, y: 0.34), .init(x: 0.94, y: 0.74)
]

func silhouette(_ fill: Color, on ground: some View, height: CGFloat = 0.66) -> some View {
    ZStack {
        ground
        GeometryReader { proxy in
            Ridge(peaks: appRidge)
                .fill(fill)
                .frame(height: proxy.size.height * height)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - The candidates

/// Where it started: pale paper, a small ridge, an outline moon and a seal the
/// size of a full stop. Everything but the ridge is gone by 32 points.
struct Current: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.paper
                Circle()
                    .strokeBorder(Ink.ink.opacity(0.10), lineWidth: side * 0.012)
                    .frame(width: side * 0.60)
                    .offset(y: -side * 0.04)
                Ridge(peaks: [
                    .init(x: 0.00, y: 0.90), .init(x: 0.36, y: 0.30),
                    .init(x: 0.52, y: 0.55), .init(x: 0.68, y: 0.40),
                    .init(x: 1.00, y: 0.90)
                ])
                .fill(Ink.slate)
                .frame(width: side * 0.78, height: side * 0.60)
                .offset(y: side * 0.06)
                RoundedRectangle(cornerRadius: side * 0.012)
                    .fill(Ink.seal)
                    .frame(width: side * 0.065, height: side * 0.065)
                    .offset(x: side * 0.30, y: side * 0.42)
            }
        }
    }
}

/// 1 — The menu bar mark, blown up: the same stroked ridge the bar wears, on
/// ink. The icon and the mark become one drawing.
struct MarkInk: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.ink
                RidgeStroke(peaks: markPeaks)
                    .stroke(
                        Ink.bright,
                        style: StrokeStyle(
                            lineWidth: side * 0.115, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.82, height: side * 0.82)
            }
        }
    }
}

/// 2 — The same mark on the Instrument accent, so the tile carries a colour of
/// its own in a Dock of grey ones.
struct MarkSlate: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.accent
                RidgeStroke(peaks: markPeaks)
                    .stroke(
                        Ink.bright,
                        style: StrokeStyle(
                            lineWidth: side * 0.115, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.82, height: side * 0.82)
            }
        }
    }
}

/// 3 — The mark drawn the way the app draws everything else: ink on paper.
struct MarkPaper: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.paper
                RidgeStroke(peaks: markPeaks)
                    .stroke(
                        Ink.ink,
                        style: StrokeStyle(
                            lineWidth: side * 0.115, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.82, height: side * 0.82)
            }
        }
    }
}

/// 4 — The mountain as a stair of terraces (§7), which is what the app's world
/// actually is. Four treads is as many as 16 points can hold.
struct TerraceInk: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.ink
                Terraces(treads: 4)
                    .fill(Ink.bright)
                    .frame(width: side * 0.82, height: side * 0.60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, side * 0.10)
            }
        }
    }
}

/// 5 — The same stair on the accent.
struct TerraceSlate: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.accent
                Terraces(treads: 4)
                    .fill(Ink.bright)
                    .frame(width: side * 0.82, height: side * 0.60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, side * 0.10)
            }
        }
    }
}

/// 6 — Silhouette, asymmetric, full bleed: the ridge runs off both edges so
/// the shape is a mountain rather than a picture of one.
struct PeakInk: View {
    var body: some View {
        Tile { _ in silhouette(Ink.bright, on: Ink.ink) }
    }
}

/// 7 — The same silhouette against the accent, with the moon high in the
/// corner where the ridge can't crowd it.
struct PeakSlate: View {
    var body: some View {
        Tile { side in
            ZStack {
                LinearGradient(
                    colors: [Ink.accent, Ink.deep], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Ink.bright.opacity(0.92))
                    .frame(width: side * 0.20)
                    .offset(x: side * 0.26, y: -side * 0.27)
                GeometryReader { proxy in
                    Ridge(peaks: appRidge)
                        .fill(Ink.bright)
                        .frame(height: proxy.size.height * 0.66)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

/// 8 — The seal as the whole tile: the ridge knocked out of vermilion, like a
/// stamp pressed on the page. Nothing else in a Dock is this colour.
struct Stamp: View {
    var body: some View {
        Tile { _ in silhouette(Ink.paper, on: Ink.seal) }
    }
}

/// 9 — Day, and the one adopted (`scripts/icon-source.swift` cuts it): the warm
/// ground kept, the mountain grown to fill the tile edge to edge, and the seal
/// grown from a 1.7 px speck into a sun.
struct Day: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.paper
                Circle()
                    .fill(Ink.seal)
                    .frame(width: side * 0.24)
                    .offset(x: side * 0.21, y: -side * 0.21)
                Ridge(peaks: [
                    .init(x: 0.00, y: 1.00), .init(x: 0.40, y: 0.06),
                    .init(x: 0.62, y: 0.44), .init(x: 0.78, y: 0.22),
                    .init(x: 1.00, y: 1.00)
                ])
                .fill(Ink.slate)
                .frame(width: side, height: side * 0.62)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// 10 — The mark with more weight in the line: at 16 points a stroke thinner
/// than an eighth of the tile starts to thin out in the valleys.
struct MarkBold: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.accent
                RidgeStroke(peaks: markPeaks)
                    .stroke(
                        Ink.bright,
                        style: StrokeStyle(
                            lineWidth: side * 0.145, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.76, height: side * 0.76)
            }
        }
    }
}

/// 11 — The stair cut to three treads. Four is one more than 16 points can
/// separate; three still reads as a climb rather than a triangle.
struct TerraceThree: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.accent
                Terraces(treads: 3)
                    .fill(Ink.bright)
                    .frame(width: side * 0.84, height: side * 0.62)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, side * 0.09)
            }
        }
    }
}

/// 12 — Both accents at once: the cool sky the app runs on, the warm seal it
/// stamps with. The one candidate no other app's icon will collide with.
struct PeakSeal: View {
    var body: some View {
        Tile { side in
            ZStack {
                LinearGradient(
                    colors: [Ink.accent, Ink.deep], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Ink.seal)
                    .frame(width: side * 0.21)
                    .offset(x: side * 0.26, y: -side * 0.27)
                GeometryReader { proxy in
                    Ridge(peaks: appRidge)
                        .fill(Ink.bright)
                        .frame(height: proxy.size.height * 0.66)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

/// 13 — The mark pressed into the seal: the stroke the menu bar wears, on the
/// one colour nothing else in a Dock is.
struct StampMark: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.seal
                RidgeStroke(peaks: markPeaks)
                    .stroke(
                        Ink.paper,
                        style: StrokeStyle(
                            lineWidth: side * 0.13, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.80, height: side * 0.80)
            }
        }
    }
}

/// 14 — Candidate 4's stair in candidate 9's daylight: ink terraces cut out of
/// warm paper instead of paper out of ink.
struct TerraceDay: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.paper
                Terraces(treads: 4)
                    .fill(Ink.slate)
                    .frame(width: side * 0.82, height: side * 0.60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, side * 0.10)
            }
        }
    }
}

/// 15 — The same, with the seal risen over the summit as a sun.
struct TerraceDaySun: View {
    var body: some View {
        Tile { side in
            ZStack {
                Ink.paper
                Circle()
                    .fill(Ink.seal)
                    .frame(width: side * 0.20)
                    .offset(x: side * 0.24, y: -side * 0.25)
                Terraces(treads: 4)
                    .fill(Ink.slate)
                    .frame(width: side * 0.82, height: side * 0.60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, side * 0.10)
            }
        }
    }
}

// MARK: - Rendering

@MainActor func bitmap(_ view: some View) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

@MainActor func downsample(_ source: NSImage, to size: Int) -> NSImage {
    let small = NSImage(size: NSSize(width: size, height: size))
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
    small.unlockFocus()
    return small
}

@MainActor func run() {
    let candidates: [(String, AnyView)] = [
        ("0-current", AnyView(Current())),
        ("1-mark-ink", AnyView(MarkInk())),
        ("2-mark-slate", AnyView(MarkSlate())),
        ("3-mark-paper", AnyView(MarkPaper())),
        ("4-terrace-ink", AnyView(TerraceInk())),
        ("5-terrace-slate", AnyView(TerraceSlate())),
        ("6-peak-ink", AnyView(PeakInk())),
        ("7-peak-slate", AnyView(PeakSlate())),
        ("8-stamp", AnyView(Stamp())),
        ("9-day", AnyView(Day())),
        ("10-mark-bold", AnyView(MarkBold())),
        ("11-terrace-three", AnyView(TerraceThree())),
        ("12-peak-seal", AnyView(PeakSeal())),
        ("13-stamp-mark", AnyView(StampMark())),
        ("14-terrace-day", AnyView(TerraceDay())),
        ("15-terrace-day-sun", AnyView(TerraceDaySun()))
    ]
    // Wiped, not merged: an earlier run's numbering leaves files like
    // "4-day.png" sitting next to a "4-terrace-ink.png" from this one, and the
    // directory then describes a lineup that no longer exists.
    let directory = URL(fileURLWithPath: "/tmp/icon-lab", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // With a number, cut that one candidate for `scripts/generate-icon.sh`
    // instead of drawing the whole sheet again.
    if let choice = CommandLine.arguments.dropFirst().first {
        guard let picked = candidates.first(where: { $0.0.hasPrefix("\(choice)-") }),
              let rep = bitmap(picked.1),
              let png = rep.representation(using: .png, properties: [:])
        else {
            print("No candidate \(choice). One of: "
                + candidates.map(\.0).joined(separator: ", "))
            exit(1)
        }
        let source = "/tmp/ShifuIcon.png"
        try? png.write(to: URL(fileURLWithPath: source))
        print("Wrote \(picked.0) to \(source). Now:\n"
            + "    scripts/generate-icon.sh \(source)")
        return
    }

    var rendered: [(String, NSImage)] = []
    for (name, view) in candidates {
        guard let rep = bitmap(view) else { continue }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
        let image = NSImage(size: NSSize(width: 1_024, height: 1_024))
        image.addRepresentation(rep)
        rendered.append((name, image))
    }

    sheet(rendered, to: directory.appendingPathComponent("sheet.png"))
    context(rendered, to: directory.appendingPathComponent("context.png"))
    print("Wrote \(rendered.count) icons, sheet.png and context.png to /tmp/icon-lab "
        + "(rows: \(rendered.map(\.0).joined(separator: ", ")))")
}

/// Every candidate at 128 / 64 / 32 / 16, each blown back up so a lost
/// hairline looks lost.
@MainActor func sheet(_ rendered: [(String, NSImage)], to url: URL) {
    let rowHeight: CGFloat = 168
    let image = NSImage(
        size: NSSize(
            width: 176 + 144 * 4 + 24, height: rowHeight * CGFloat(rendered.count) + 24))
    image.lockFocus()
    NSColor(white: 0.55, alpha: 1).setFill()
    NSRect(origin: .zero, size: image.size).fill()
    for (index, entry) in rendered.enumerated() {
        let top = image.size.height - 12 - rowHeight * CGFloat(index + 1)
        var x: CGFloat = 12
        entry.1.draw(in: CGRect(x: x, y: top, width: 160, height: 160))
        x += 176
        for size in [128, 64, 32, 16] {
            NSGraphicsContext.current?.imageInterpolation = .none
            downsample(entry.1, to: size).draw(
                in: CGRect(x: x, y: top + 16, width: 128, height: 128),
                from: .zero, operation: .sourceOver, fraction: 1)
            x += 144
        }
    }
    image.unlockFocus()
    write(image, to: url)
}

/// The two small sizes at their real scale, on the three grounds a macOS icon
/// actually lands on: a white Finder list, a grey desktop, a dark Dock.
@MainActor func context(_ rendered: [(String, NSImage)], to url: URL) {
    let grounds: [NSColor] = [
        .white, NSColor(white: 0.62, alpha: 1), NSColor(white: 0.16, alpha: 1)
    ]
    let cell: CGFloat = 56
    let image = NSImage(
        size: NSSize(
            width: cell * CGFloat(rendered.count) + 24,
            height: cell * CGFloat(grounds.count * 2) + 24))
    image.lockFocus()
    for (band, ground) in grounds.enumerated() {
        for size in 0..<2 {
            let row = band * 2 + size
            let top = image.size.height - 12 - cell * CGFloat(row + 1)
            ground.setFill()
            NSRect(x: 12, y: top, width: cell * CGFloat(rendered.count), height: cell).fill()
            let side: CGFloat = size == 0 ? 32 : 16
            for (index, entry) in rendered.enumerated() {
                NSGraphicsContext.current?.imageInterpolation = .high
                entry.1.draw(
                    in: CGRect(
                        x: 12 + cell * CGFloat(index) + (cell - side) / 2,
                        y: top + (cell - side) / 2, width: side, height: side),
                    from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }
    image.unlockFocus()
    write(image, to: url)
}

@MainActor func write(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
        return
    }
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

MainActor.assumeIsolated { run() }
