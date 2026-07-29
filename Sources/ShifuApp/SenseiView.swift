import SwiftUI

/// The miniature sensei (design.md §7) — Shifu himself, drawn as a 20 × 22 pixel
/// sprite so he reads the same from a 30 pt sidebar mark to a 108 pt hero. A round
/// little master in a terracotta gi and a straw kasa, hands folded into his
/// sleeves. Fixed illustration colors, chosen to sit on both surfaces.
struct SenseiFigure: View {
    enum Mood {
        /// Eyes closed, present. The default — the watching master.
        case serene
        /// Hat tipped over the eyes — capture is paused, the master naps.
        case resting
        /// Bright eyes and a smile — a session finished, a streak kept.
        case proud
    }

    var size: CGFloat = 96
    var mood: Mood = .serene

    /// Illustration palette (fixed in both appearances). Three tones per material
    /// — light, base, shade — plus one outline, the way a 16-bit sprite sheet is
    /// ramped. The light tones all sit up and to the left.
    private static let palette: [Character: Color] = [
        "X": Color(red: 0.20, green: 0.14, blue: 0.12),   // outline
        "L": Color(red: 0.93, green: 0.82, blue: 0.58),   // straw light
        "S": Color(red: 0.85, green: 0.71, blue: 0.46),   // straw
        "R": Color(red: 0.68, green: 0.54, blue: 0.31),   // straw shade
        "P": Color(red: 0.98, green: 0.85, blue: 0.71),   // skin light
        "K": Color(red: 0.95, green: 0.78, blue: 0.62),   // skin
        "M": Color(red: 0.87, green: 0.66, blue: 0.50),   // skin shade
        "B": Color(red: 0.93, green: 0.66, blue: 0.55),   // blush
        "H": Color(red: 0.97, green: 0.96, blue: 0.95),   // beard
        "W": Color(red: 0.80, green: 0.78, blue: 0.76),   // beard shade
        "E": Color(red: 0.91, green: 0.58, blue: 0.45),   // gi light
        "G": Color(red: 0.85, green: 0.47, blue: 0.34),   // gi (#D97757)
        "D": Color(red: 0.73, green: 0.36, blue: 0.24),   // gi shade
        "C": Color(red: 0.92, green: 0.86, blue: 0.72),   // collar
        "O": Color(red: 0.38, green: 0.23, blue: 0.15)    // obi
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let cell = Self.cellSize(in: canvasSize)
            let originX = Self.snap((canvasSize.width - cell * CGFloat(Self.columns)) / 2)
            let originY = Self.snap((canvasSize.height - cell * CGFloat(Self.rows)) / 2)
            for (row, line) in sprite().enumerated() {
                // Fill runs of one color as a single rect — no seams between
                // neighbouring pixels, and ~60 fills instead of 440.
                var column = 0
                while column < line.count {
                    guard let fill = Self.palette[line[column]] else {
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
        .frame(width: size, height: size * CGFloat(Self.rows) / CGFloat(Self.columns))
        .accessibilityLabel("Shifu, the miniature sensei")
    }

    // MARK: - Sprite (20 × 22 design space)

    private static let columns = 20
    private static let rows = 22

    /// Head, beard, and gi. The kasa and the eyes are blitted over this, so a
    /// mood only has to restate the pixels it actually changes.
    private static let bodyRows = [
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "......XPKKKKKX......",
        ".....XHHKKKKHHX.....",
        ".....XPKKKKKKMX.....",
        ".....XBKKMMKKBX.....",
        ".....XHHHKKHHHX.....",
        ".....XWHHHHHHWX.....",
        "...XEGCHHHHHHCGDX...",
        "...XEGCCHHHHCCGDX...",
        "...XEGGCCHHCCGGDX...",
        "...XEGGGCWWCGGGDX...",
        "..XDDDDXKKKKXDDDDX..",
        "..XDDDDXKMMKXDDDDX..",
        "..XOOOOOOOOOOOOOOX..",
        "..XEGGGGOOOOGGGGDX..",
        "..XEGGGGGGGGGGGGDX..",
        "..XXXXXXXXXXXXXXXX.."
    ]

    /// The straw kasa, drawn last. Dropping it a couple of rows tips it over the eyes.
    private static let hatRows = [
        ".........XX.........",
        "........XLSX........",
        ".......XLLSSX.......",
        ".....XLLLLSSSSX.....",
        "...XLLLLLLSSSSSSX...",
        ".XLLLLLLLLSSSSSSSSX.",
        "XRRRRRRRRRRRRRRRRRRX"
    ]

    /// Two-pixel lids: shut, but awake behind them.
    private static let sereneEyes = [(8, ".......XX..XX.......")]
    /// Open eyes and a mouth in the moustache's gap.
    private static let proudEyes = [(8, ".......X....X......."), (10, ".........XX.........")]

    private func sprite() -> [[Character]] {
        var grid = Self.bodyRows.map { Array($0) }
        for (row, line) in eyeRows {
            blit(line, into: &grid, atRow: row)
        }
        let hatDrop = mood == .resting ? 2 : 0   // far enough to sit on the brows
        for (index, line) in Self.hatRows.enumerated() {
            blit(line, into: &grid, atRow: index + hatDrop)
        }
        return grid
    }

    private var eyeRows: [(Int, String)] {
        switch mood {
        case .serene: return Self.sereneEyes
        case .proud: return Self.proudEyes
        case .resting: return []   // hidden under the tipped hat
        }
    }

    private func blit(_ line: String, into grid: inout [[Character]], atRow row: Int) {
        guard grid.indices.contains(row) else { return }
        for (column, pixel) in line.enumerated() where pixel != "." {
            grid[row][column] = pixel
        }
    }

    /// Whole half-points per pixel, so every cell lands on a device pixel at 2×
    /// and the sprite stays hard-edged instead of resampling to mush.
    private static func cellSize(in canvasSize: CGSize) -> CGFloat {
        let raw = min(canvasSize.width / CGFloat(columns), canvasSize.height / CGFloat(rows))
        return max(1, (raw * 2).rounded(.down) / 2)
    }

    private static func snap(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

/// A themed empty state: the sensei, a title, and one line in his voice.
/// Replaces `ContentUnavailableView` on Shifu's own pages so an empty screen
/// still feels inhabited.
struct SenseiEmptyState<Actions: View>: View {
    let title: String
    let message: String
    var mood: SenseiFigure.Mood = .serene
    @ViewBuilder var actions: Actions

    init(
        _ title: String, message: String, mood: SenseiFigure.Mood = .serene,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.mood = mood
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            SenseiFigure(size: 72, mood: mood)
            Text(title)
                .font(.headline)
            Text(message)
                .font(Dojo.voice())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            actions
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
