import SwiftUI

/// Shifu himself (design.md §7) — not a person: a small creature in a tied
/// headband, drawn as a **16 × 16 pixel sprite**. Blocky on purpose. The grid is
/// the whole drawing, so a mood is a few characters changed rather than a set of
/// curves, and one render is a few dozen rectangle fills — no layers, no clips,
/// no blur, and nothing that ticks. A sprite costs nothing to keep on screen,
/// which is the point in an app meant to be left open all day.
///
/// State is carried by the face, not by motion: eyes open while capture runs,
/// shut with a `z` while it's paused, arched when a queue is cleared.
struct SenseiFigure: View {
    enum Mood {
        /// Eyes closed, content. The default.
        case serene
        /// Open eyes — capture is running and he is paying attention.
        case watching
        /// Asleep — capture is paused.
        case resting
        /// Arched eyes and a wide grin — a streak kept, a queue cleared.
        case proud
    }

    var size: CGFloat = 96
    var mood: Mood = .serene

    var body: some View {
        Canvas(opaque: false) { context, canvasSize in
            SenseiSprite.draw(mood: mood, into: &context, size: canvasSize)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Shifu")
    }
}

/// The sprite sheet. Rows are read as characters; `palette` maps each to a
/// color and `.` is transparent. Not private: the world paints him straight
/// into its own Canvas rather than compositing a second view over it.
enum SenseiSprite {
    static let columns = 16
    static let rows = 16

    /// Six colors and no more — the discipline that keeps it reading as pixel
    /// art rather than a shrunken illustration. Fixed in both appearances: he is
    /// art, not chrome.
    static let palette: [Character: Color] = [
        "B": Color(red: 0.96, green: 0.93, blue: 0.85),   // body
        "S": Color(red: 0.84, green: 0.78, blue: 0.67),   // body shade
        "R": Color(red: 0.85, green: 0.37, blue: 0.24),   // headband
        "D": Color(red: 0.68, green: 0.26, blue: 0.16),   // headband shade
        "E": Color(red: 0.16, green: 0.13, blue: 0.14),   // ink
        "W": Color(red: 0.55, green: 0.52, blue: 0.50)    // sleep marks
    ]

    /// Body, ears, paws, feet — one blob with two ear stubs on top, a paw
    /// sticking out each side, and the light coming from the upper left. The
    /// band and the face are blitted over this, so a mood only restates the
    /// pixels it actually changes.
    static let bodyRows = [
        "................",
        "................",
        "...BB......BB...",
        "...BB......BB...",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        "..BBBBBBBBBBBB..",
        "...SS......SS...",
        "................"
    ]

    /// The headband: two rows across the brow, knotted past the right temple,
    /// with a tail hanging off the knot. It is the only thing that breaks his
    /// silhouette, which is what makes it the mark.
    static let bandRows = [
        (6, "..RRRRRRRRRRRRRR"),
        (7, "..DDDDDDDDDDDDDD"),
        (8, "..............DD")
    ]

    static let openEyes = [(9, "....EE....EE...."), (10, "....EE....EE....")]
    /// Shut: one flat lid apiece, a pixel wider than the open eye.
    static let shutEyes = [(10, "...EEE....EEE...")]

    static let smallMouth = [(12, ".......EE.......")]
    /// The grin. `proud` keeps the shut lids and just widens this — at sixteen
    /// pixels a drawn smile carries the mood and an arched eyebrow only reads
    /// as noise.
    static let wideMouth = [(12, "......EEEE......")]

    /// A three-by-three `z` off his shoulder — the whole of "asleep", and it
    /// costs nine pixels instead of a render loop.
    static let sleepMark = [
        (0, "............WWW."),
        (1, ".............W.."),
        (2, "............WWW.")
    ]

    static func draw(
        mood: SenseiFigure.Mood, into context: inout GraphicsContext, size: CGSize
    ) {
        draw(mood: mood, into: &context, in: CGRect(origin: .zero, size: size))
    }

    /// Centred in an arbitrary rect — how the world plants him on a step.
    static func draw(
        mood: SenseiFigure.Mood, into context: inout GraphicsContext, in rect: CGRect
    ) {
        let cell = cellSize(in: rect.size)
        let originX = snap(rect.minX + (rect.width - cell * CGFloat(columns)) / 2)
        let originY = snap(rect.minY + (rect.height - cell * CGFloat(rows)) / 2)
        for (row, line) in grid(mood: mood).enumerated() {
            // Fill runs of one color as a single rect — no seams between
            // neighbouring pixels, and ~50 fills instead of 256.
            var column = 0
            while column < line.count {
                guard let fill = palette[line[column]] else {
                    column += 1
                    continue
                }
                var run = 1
                while column + run < line.count, line[column + run] == line[column] { run += 1 }
                context.fill(
                    Path(CGRect(
                        x: originX + CGFloat(column) * cell, y: originY + CGFloat(row) * cell,
                        width: CGFloat(run) * cell, height: cell)),
                    with: .color(fill))
                column += run
            }
        }
    }

    private static func grid(mood: SenseiFigure.Mood) -> [[Character]] {
        var grid = bodyRows.map { Array($0) }
        for (row, line) in bandRows { blit(line, into: &grid, atRow: row) }
        for (row, line) in eyes(mood) { blit(line, into: &grid, atRow: row) }
        for (row, line) in mood == .proud ? wideMouth : smallMouth {
            blit(line, into: &grid, atRow: row)
        }
        if mood == .resting {
            for (row, line) in sleepMark { blit(line, into: &grid, atRow: row) }
        }
        return grid
    }

    private static func eyes(_ mood: SenseiFigure.Mood) -> [(Int, String)] {
        mood == .watching ? openEyes : shutEyes
    }

    private static func blit(_ line: String, into grid: inout [[Character]], atRow row: Int) {
        guard grid.indices.contains(row) else { return }
        for (column, pixel) in line.enumerated() where pixel != "." {
            grid[row][column] = pixel
        }
    }

    /// Whole half-points per pixel, so every cell lands on a device pixel at 2×
    /// and the sprite stays hard-edged instead of resampling to mush.
    private static func cellSize(in size: CGSize) -> CGFloat {
        let raw = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
        return max(1, (raw * 2).rounded(.down) / 2)
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
