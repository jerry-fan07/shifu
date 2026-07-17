import Testing
@testable import ShifuCore

@Suite struct SimHashTests {
    @Test func identicalTextIdenticalHash() {
        #expect(SimHash.hash("hello world foo bar") == SimHash.hash("hello world foo bar"))
    }

    @Test func emptyTextHashesToZero() {
        #expect(SimHash.hash("") == 0)
        #expect(SimHash.hash("   \n\t") == 0)
    }

    @Test func smallEditIsNearDuplicate() {
        let base = Array(repeating: "the quick brown fox jumps over the lazy dog", count: 20)
            .joined(separator: " ")
        let edited = base + " extra word"
        #expect(SimHash.isNearDuplicate(SimHash.hash(base), SimHash.hash(edited)))
    }

    @Test func differentTextIsNotNearDuplicate() {
        let a = SimHash.hash("swift concurrency actors sendable isolation runtime")
        let b = SimHash.hash("formula one qualifying results verstappen hamilton monza")
        #expect(!SimHash.isNearDuplicate(a, b))
    }

    @Test func hammingDistance() {
        #expect(SimHash.hammingDistance(0b1010, 0b1010) == 0)
        #expect(SimHash.hammingDistance(0b1010, 0b0101) == 4)
    }
}

@Suite struct DHashTests {
    @Test func flatFrameHashesToZero() {
        let flat = [UInt8](repeating: 128, count: 72)
        #expect(DHash.hash(luminance: flat) == 0)
    }

    @Test func gradientProducesBits() {
        // Each row descends left→right, so every left pixel > right pixel: all 64 bits set.
        var grid = [UInt8]()
        for _ in 0..<8 {
            for col in 0..<9 {
                grid.append(UInt8(255 - col * 20))
            }
        }
        #expect(DHash.hash(luminance: grid) == UInt64.max)
    }

    @Test func singlePixelChangeIsUnchanged() {
        var grid = [UInt8]()
        for row in 0..<8 {
            for col in 0..<9 {
                grid.append(UInt8((row * 9 + col) * 2))
            }
        }
        let a = DHash.hash(luminance: grid)
        grid[40] = grid[40] &+ 200
        let b = DHash.hash(luminance: grid)
        #expect(DHash.isUnchanged(a, b))
    }
}
