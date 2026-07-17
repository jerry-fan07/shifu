import CoreGraphics
import Foundation

/// 8×8 perceptual difference hash over a downscaled grayscale frame,
/// used to gate OCR: if the screen hasn't visibly changed, skip it (design.md §3.3).
public enum DHash {
    /// Hash of a 9×8 luminance grid (row-major, 72 values). Each bit is
    /// "is pixel brighter than its right neighbor".
    public static func hash(luminance: [UInt8]) -> UInt64 {
        precondition(luminance.count == 9 * 8, "dHash needs a 9×8 luminance grid")
        var result: UInt64 = 0
        var bit = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = luminance[row * 9 + col]
                let right = luminance[row * 9 + col + 1]
                if left > right {
                    result |= 1 << UInt64(bit)
                }
                bit += 1
            }
        }
        return result
    }

    /// Downscales a CGImage to 9×8 grayscale and hashes it.
    public static func hash(image: CGImage) -> UInt64? {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return hash(luminance: pixels)
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Frames within this distance are "the same screen" — skip OCR.
    public static let unchangedThreshold = 5

    public static func isUnchanged(_ a: UInt64, _ b: UInt64) -> Bool {
        hammingDistance(a, b) <= unchangedThreshold
    }
}
