import AppKit
import ShifuCore

/// Walks the capture ladder (design.md §3.2) for one trigger and hands the
/// result to the recorder. Exclusions are checked *before* any capture.
@MainActor
final class CaptureEngine {
    /// AX text shorter than this is considered "not enough signal" and we
    /// fall through to the OCR rung.
    static let axTextFloor = 80

    private let recorder: ObservationRecorder
    private let exclusions: Exclusions
    private let ocr = OCRCapture()
    private var lastDHashByKey: [String: UInt64] = [:]
    private var ocrInFlight = false

    private(set) var lastCaptureAt: Date = .distantPast

    /// Fired after each recorded capture (bundle, url, excluded) — Work Mode
    /// listens here for its rules-only near-real-time classification (§4.4).
    var onCapture: ((String, String?, Bool) -> Void)?

    init(recorder: ObservationRecorder, exclusions: Exclusions) {
        self.recorder = recorder
        self.exclusions = exclusions
    }

    func captureFrontmost(trigger: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        capture(app: app, trigger: trigger)
    }

    func capture(app: NSRunningApplication, trigger: String) {
        lastCaptureAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let bundle = app.bundleIdentifier ?? "unknown.\(app.processIdentifier)"

        // Rung 0: exclusion by bundle — nothing is captured, duration only (§8).
        if exclusions.isExcluded(bundleID: bundle) {
            record(.init(timestamp: now, appBundle: bundle, captureKind: .excluded))
            return
        }

        // Metadata via AX (title, URL for browsers).
        guard let window = AX.focusedWindow(pid: app.processIdentifier) else {
            // No AX (permission missing or opaque app): metadata-only rung.
            record(.init(timestamp: now, appBundle: bundle, captureKind: .meta))
            return
        }
        let title: String? = AX.string(window, kAXTitleAttribute)

        var url: String?
        if Browsers.isBrowser(bundle) {
            // Private windows are always excluded, before any content read (§8).
            if Browsers.isPrivateWindow(title: title) {
                record(.init(timestamp: now, appBundle: bundle, captureKind: .excluded))
                return
            }
            url = AX.webAreaURL(in: window)
            if let url, exclusions.isExcluded(url: url) {
                record(.init(timestamp: now, appBundle: bundle, captureKind: .excluded))
                return
            }
        }

        // Rung 2: AX text extraction.
        let text = AX.extractText(from: window, byteCap: ObservationRecorder.maxTextBytes)
        if text.count >= Self.axTextFloor {
            record(.init(timestamp: now, appBundle: bundle, windowTitle: title, url: url,
                         captureKind: .ax, text: text))
            return
        }

        // Rung 3: screenshot → OCR, gated by dHash change detection.
        captureViaOCR(app: app, bundle: bundle, title: title, url: url, timestamp: now,
                      axFallbackText: text)
    }

    private func captureViaOCR(
        app: NSRunningApplication, bundle: String, title: String?, url: String?,
        timestamp: Int64, axFallbackText: String
    ) {
        guard !ocrInFlight else { return }
        ocrInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.ocrInFlight = false }
            do {
                guard let result = try await self.ocr.captureText(pid: app.processIdentifier) else {
                    self.recordMetaOrAX(bundle: bundle, title: title, url: url,
                                        timestamp: timestamp, axText: axFallbackText)
                    return
                }
                let key = "\(bundle)|\(title ?? "")"
                if let last = self.lastDHashByKey[key], DHash.isUnchanged(last, result.dhash) {
                    // Same screen as last time (e.g. fullscreen video): bump last_seen only.
                    _ = try? self.recorder.touch(appBundle: bundle, windowTitle: title,
                                                 url: url, timestamp: timestamp)
                    return
                }
                self.lastDHashByKey[key] = result.dhash
                if result.text.isEmpty {
                    self.recordMetaOrAX(bundle: bundle, title: title, url: url,
                                        timestamp: timestamp, axText: axFallbackText)
                } else {
                    self.record(.init(timestamp: timestamp, appBundle: bundle, windowTitle: title,
                                      url: url, captureKind: .ocr, text: result.text))
                }
            } catch {
                // Screen Recording permission missing or capture failed:
                // degrade to metadata/AX rather than dropping the trigger (§10).
                self.recordMetaOrAX(bundle: bundle, title: title, url: url,
                                    timestamp: timestamp, axText: axFallbackText)
            }
        }
    }

    private func recordMetaOrAX(bundle: String, title: String?, url: String?,
                                timestamp: Int64, axText: String) {
        if axText.isEmpty {
            record(.init(timestamp: timestamp, appBundle: bundle, windowTitle: title,
                         url: url, captureKind: .meta))
        } else {
            record(.init(timestamp: timestamp, appBundle: bundle, windowTitle: title,
                         url: url, captureKind: .ax, text: axText))
        }
    }

    private func record(_ candidate: ObservationRecorder.Candidate) {
        do {
            try recorder.record(candidate)
        } catch {
            FileHandle.standardError.write(Data("record failed: \(error)\n".utf8))
        }
        onCapture?(candidate.appBundle, candidate.url, candidate.captureKind == .excluded)
    }
}
