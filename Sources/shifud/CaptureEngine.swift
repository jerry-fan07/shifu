import AppKit
import ShifuCore

/// Walks the capture ladder (design.md §3.2) for one trigger and hands the
/// result to the recorder. Exclusions are checked *before* any capture.
@MainActor
final class CaptureEngine {
    /// AX text shorter than this is considered "not enough signal" and we
    /// fall through to the OCR rung.
    static let axTextFloor = 80

    /// Default capacity of `lastDHashByKey` (design.md §3.4: <80 MB steady
    /// RSS). Window titles are unbounded in cardinality, so the dHash dedupe
    /// map is a bounded LRU rather than a plain dictionary.
    static let defaultDHashCacheCapacity = 256

    /// Everything the ladder reads from outside this process, behind one seam.
    ///
    /// Production wires these straight to `AXHelper` and `OCRCapture`; the
    /// point of the indirection is that the ladder's *ordering* is then an
    /// assertion rather than a code review. Invariants 3 and 4 (design.md §8,
    /// §3.2) are both statements about what is never *called* — an excluded
    /// window must reach no reader at all — and a fake that records its calls
    /// is the only way to state that as a test.
    struct Probe {
        var focusedWindow: (pid_t) -> AXUIElement?
        var title: (AXUIElement) -> String?
        var webAreaURL: (AXUIElement) -> String?
        var extractText: (AXUIElement, Int) -> String
        var enableWebAccessibility: (pid_t) -> Void
        var ocrText: (pid_t) async throws -> OCRCapture.Result?

        @MainActor
        static func live() -> Probe {
            let ocr = OCRCapture()
            return Probe(
                focusedWindow: { AXHelper.focusedWindow(pid: $0) },
                title: { AXHelper.string($0, kAXTitleAttribute) },
                webAreaURL: { AXHelper.webAreaURL(in: $0) },
                extractText: { AXHelper.extractText(from: $0, byteCap: $1) },
                enableWebAccessibility: { AXHelper.enableWebAccessibility(pid: $0) },
                ocrText: { try await ocr.captureText(pid: $0) })
        }
    }

    private struct OCRTarget {
        let pid: pid_t
        let bundle: String
        let title: String?
        let url: String?
        let timestamp: Int64
        let axFallbackText: String
    }

    private let recorder: ObservationRecorder
    private let exclusions: Exclusions
    private let probe: Probe
    private var lastDHashByKey: BoundedLRUCache<String, UInt64>
    private var ocrInFlight = false
    /// The in-flight OCR rung. Held only so a test can await the rung it just
    /// triggered; nothing in the daemon reads it.
    private(set) var ocrTask: Task<Void, Never>?
    /// Chromium pids already asked to build their web-content AX tree,
    /// paired with the process's launch date. macOS recycles pids (they
    /// wrap at ~100k), so a bare pid can't tell a live process from a dead
    /// one that used to hold the same pid — `launchDate` can. Not a leak:
    /// bounded by the pid space, at most ~100k small entries.
    private var webAXEnabledLaunchDates: [pid_t: Date] = [:]

    private(set) var lastCaptureAt: Date = .distantPast

    /// Fired after each recorded capture (bundle, url, excluded) — Work Mode
    /// listens here for its rules-only near-real-time classification (§4.4).
    var onCapture: ((String, String?, Bool) -> Void)?

    init(
        recorder: ObservationRecorder,
        exclusions: Exclusions,
        dhashCacheCapacity: Int = CaptureEngine.defaultDHashCacheCapacity,
        probe: Probe? = nil
    ) {
        self.recorder = recorder
        self.exclusions = exclusions
        self.lastDHashByKey = BoundedLRUCache(capacity: dhashCacheCapacity)
        self.probe = probe ?? .live()
    }

    func captureFrontmost(trigger: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        capture(app: app, trigger: trigger)
    }

    func capture(app: NSRunningApplication, trigger: String) {
        capture(
            bundle: app.bundleIdentifier ?? "unknown.\(app.processIdentifier)",
            pid: app.processIdentifier, launchDate: app.launchDate, trigger: trigger)
    }

    /// The ladder itself, over an app's identity rather than its
    /// `NSRunningApplication` — so it can be walked without one.
    func capture(bundle: String, pid: pid_t, launchDate: Date?, trigger: String) {
        lastCaptureAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)

        // Rung 0: exclusion by bundle — nothing is captured, duration only (§8).
        if exclusions.isExcluded(bundleID: bundle) {
            record(.init(timestamp: now, appBundle: bundle, captureKind: .excluded))
            return
        }

        // Metadata via AX (title, URL for browsers).
        guard let window = probe.focusedWindow(pid) else {
            // No AX (permission missing or opaque app): metadata-only rung.
            record(.init(timestamp: now, appBundle: bundle, captureKind: .meta))
            return
        }
        let title: String? = probe.title(window)

        var url: String?
        if Browsers.isBrowser(bundle) {
            // Private windows are always excluded, before any content read (§8).
            if Browsers.isPrivateWindow(title: title) {
                record(.init(timestamp: now, appBundle: bundle, captureKind: .excluded))
                return
            }
            url = probe.webAreaURL(window)
            if let url, exclusions.isExcluded(url: url) {
                record(.init(timestamp: now, appBundle: bundle, captureKind: .excluded))
                return
            }
            // Chromium keeps web content out of the AX tree until asked;
            // without this rung 2 sees only browser chrome and every capture
            // pays the OCR cost. Dedupe on (pid, launchDate) rather than pid
            // alone: a recycled pid belongs to a genuinely new process and
            // must still be poked. An unavailable launchDate falls back to
            // `.distantPast`, which is stable across captures, so such a
            // process is still poked exactly once — a fresh `Date()` here
            // would never match and would put two AX round-trips on every
            // capture of that app (design.md §3.4).
            if Browsers.isChromium(bundle) {
                let launched = launchDate ?? .distantPast
                if webAXEnabledLaunchDates[pid] != launched {
                    probe.enableWebAccessibility(pid)
                    webAXEnabledLaunchDates[pid] = launched
                }
            }
        }

        // Rung 2: AX text extraction.
        let text = probe.extractText(window, ObservationRecorder.maxTextBytes)
        if text.count >= Self.axTextFloor {
            record(.init(timestamp: now, appBundle: bundle, windowTitle: title, url: url,
                         captureKind: .ax, text: text))
            return
        }

        // Rung 3: screenshot → OCR, gated by dHash change detection.
        let target = OCRTarget(
            pid: pid, bundle: bundle, title: title, url: url,
            timestamp: now, axFallbackText: text
        )
        captureViaOCR(target: target)
    }

    private func captureViaOCR(target: OCRTarget) {
        guard !ocrInFlight else { return }
        ocrInFlight = true
        ocrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.ocrInFlight = false }
            do {
                guard let result = try await self.probe.ocrText(target.pid) else {
                    self.recordMetaOrAX(bundle: target.bundle, title: target.title, url: target.url,
                                        timestamp: target.timestamp, axText: target.axFallbackText)
                    return
                }
                let key = "\(target.bundle)|\(target.title ?? "")"
                if let last = self.lastDHashByKey.get(key), DHash.isUnchanged(last, result.dhash) {
                    // Same screen as last time (e.g. fullscreen video): bump last_seen only.
                    _ = try? self.recorder.touch(appBundle: target.bundle, windowTitle: target.title,
                                                 url: target.url, timestamp: target.timestamp)
                    return
                }
                self.lastDHashByKey.set(result.dhash, forKey: key)
                if result.text.isEmpty {
                    self.recordMetaOrAX(bundle: target.bundle, title: target.title, url: target.url,
                                        timestamp: target.timestamp, axText: target.axFallbackText)
                } else {
                    self.record(.init(timestamp: target.timestamp, appBundle: target.bundle, windowTitle: target.title,
                                      url: target.url, captureKind: .ocr, text: result.text))
                }
            } catch {
                // Screen Recording permission missing or capture failed:
                // degrade to metadata/AX rather than dropping the trigger (§10).
                self.recordMetaOrAX(bundle: target.bundle, title: target.title, url: target.url,
                                    timestamp: target.timestamp, axText: target.axFallbackText)
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
