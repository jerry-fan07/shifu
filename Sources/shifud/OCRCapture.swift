import CoreGraphics
import ScreenCaptureKit
import ShifuCore
import Vision

/// Capture ladder rung 3 (design.md §3.2): one-off window screenshot via
/// SCScreenshotManager → downscale → Vision OCR. The bitmap is discarded
/// immediately after OCR; pixels are never persisted.
@MainActor
final class OCRCapture {
    struct Result {
        let text: String
        let dhash: UInt64
    }

    static let maxCaptureWidth = 2_560
    static let maxCaptureScale: CGFloat = 2.0

    /// Screenshots the frontmost window of `pid` and OCRs it.
    /// Returns nil when no capturable window exists.
    func captureText(pid: pid_t) async throws -> Result? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width > 100 && $0.frame.height > 100
        }
        // Frontmost window of the app: SCShareableContent orders front-to-back.
        guard let window = candidates.first else { return nil }

        let config = SCStreamConfiguration()
        // Capture at up to Retina (2x) pixel density, capped at maxCaptureWidth:
        // window.frame is in points, and OCR needs text at near-native pixel size.
        let scale = min(Self.maxCaptureScale, CGFloat(Self.maxCaptureWidth) / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .automatic

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        let dhash = DHash.hash(image: image) ?? 0
        let text = try Self.recognizeText(in: image)
        return Result(text: text, dhash: dhash)
    }

    /// On-device OCR, fast recognition level (Neural Engine/GPU, not CPU).
    /// At 2x capture density, .fast + language correction reads UI text nearly
    /// perfectly in ~200 ms; .accurate costs ~750 ms/burst (over the §3.4
    /// 300 ms budget) for marginal gains — resolution, not level, was the
    /// accuracy bottleneck.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
