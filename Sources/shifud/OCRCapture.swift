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

    static let maxCaptureWidth = 1_280

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
        let scale = min(1.0, CGFloat(Self.maxCaptureWidth) / window.frame.width)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .nominal

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        let dhash = DHash.hash(image: image) ?? 0
        let text = try Self.recognizeText(in: image)
        return Result(text: text, dhash: dhash)
    }

    /// On-device OCR, fast recognition level (Neural Engine/GPU, not CPU).
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
