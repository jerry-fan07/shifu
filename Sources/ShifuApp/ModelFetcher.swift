import Foundation
import ShifuCore

/// The Qwen edition's one-time weights fetch (design.md §4.2). This is the
/// single, narrow exception to "only shifu-analyzer touches the network"
/// (CLAUDE.md invariant 1): a GET of the pinned Hugging Face artifact for
/// the tier `LocalModel.preflightHere` chose — nothing about the user rides
/// on it, and nothing else is ever fetched. It lives in the app, not the
/// analyzer, because it is setup with a face: a progress bar the user is
/// watching, an alert that names the requirement that failed.
///
/// One instance for the whole process: onboarding starts a fetch, the
/// Settings row shows the same fetch, and quitting the app mid-download
/// simply leaves nothing installed — the fetch restarts from either surface.
/// On completion the backend flips to `local` and the tier's wire name and
/// window are written, so analysis starts on the next hourly run with no
/// settings typed by hand.
@MainActor
final class ModelFetcher: NSObject, ObservableObject {
    static let shared = ModelFetcher()

    enum Phase: Equatable {
        case idle
        /// Preflight said no. The string is the alert body: the specific
        /// unmet requirement, never "setup failed".
        case blocked(String)
        /// Fraction of the tier's published bytes that have landed.
        case downloading(Double)
        case verifying
        case installed(LocalModel.Tier)
        /// The fetch itself broke — offline, HTTP error, or a file that
        /// wasn't the model. Retryable from either surface.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// What preflight picked, for the page's promise ("Qwen3.5-9B · 5.7 GB")
    /// before and during the fetch.
    @Published private(set) var tier: LocalModel.Tier?

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(
        configuration: .default, delegate: FetchDelegate(fetcher: self), delegateQueue: nil)

    override private init() {
        super.init()
        if let installed = LocalModel.installedTier() {
            phase = .installed(installed)
            tier = installed
        }
    }

    /// Preflight, then either the download or the alert copy. Idempotent
    /// while a fetch is running; a second call from the other surface is a
    /// no-op, not a second download.
    func start() {
        if case .downloading = phase { return }
        if case .verifying = phase { return }
        if let installed = LocalModel.installedTier() {
            phase = .installed(installed)
            tier = installed
            return
        }
        switch LocalModel.preflightHere() {
        case .failure(let reason):
            phase = .blocked(Self.explain(reason))
        case .success(let chosen):
            tier = chosen
            phase = .downloading(0)
            let request = URLRequest(url: chosen.downloadURL)
            task = session.downloadTask(with: request)
            task?.resume()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// The alert body for each preflight failure: what is missing, on this
    /// Mac, in numbers — and what still works without the download.
    static func explain(_ reason: LocalModel.PreflightFailure) -> String {
        let gigabyte = 1 << 30
        switch reason {
        case .needsAppleSilicon:
            return "The local model needs an Apple Silicon Mac — this one is Intel. "
                + "Shifu keeps working on rules alone, or point Settings → Analysis "
                + "at a model server you run elsewhere."
        case .needsMemory(let installed):
            return "The local model needs at least 8 GB of memory; this Mac has "
                + "\(installed / UInt64(gigabyte)) GB. Shifu keeps working on rules alone."
        case .needsDisk(let tier, let free, let required):
            return "\(tier.displayName) needs \(required / Int64(gigabyte)) GB free "
                + "(\(tier.displayBytes) of weights plus room to work); this disk has "
                + "\(free / Int64(gigabyte)) GB. Free some space and try again."
        }
    }

    // MARK: - Called by the delegate (main-actor hops)

    fileprivate func report(written: Int64) {
        guard let tier, case .downloading = phase else { return }
        phase = .downloading(
            min(1, Double(written) / Double(tier.weightsBytes)))
    }

    /// The downloaded file, still at URLSession's temporary location, moved
    /// synchronously before this returns — the delegate deletes it after.
    fileprivate func finish(temporary: URL, response: URLResponse?) {
        guard let tier else { return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            phase = .failed("The model download failed (HTTP \(http.statusCode)). "
                + "Check your connection and try again.")
            return
        }
        phase = .verifying
        do {
            guard LocalModel.verifyWeights(at: temporary, tier: tier) else {
                phase = .failed("The downloaded file wasn't the model — the fetch "
                    + "may have been interrupted. Try again.")
                return
            }
            try FileManager.default.createDirectory(
                at: ShifuPaths.models, withIntermediateDirectories: true)
            let destination = LocalModel.weightsURL(for: tier)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try activate(tier)
            phase = .installed(tier)
        } catch {
            phase = .failed("Installing the model failed: \(error.localizedDescription)")
        }
    }

    fileprivate func fail(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        let offline = (error as? URLError)?.code == .notConnectedToInternet
        phase = .failed(offline
            ? "No internet connection. The model is a one-time "
                + "\(tier?.displayBytes ?? "multi-GB") download — connect and try again."
            : "The model download failed: \(error.localizedDescription)")
    }

    /// The flip the whole feature exists for: with the weights installed,
    /// analysis is local from the next hourly run — backend, wire name, and
    /// window all follow the fetched tier, nothing typed by hand.
    private func activate(_ tier: LocalModel.Tier) throws {
        let database = try ShifuDatabase.open(at: ShifuPaths.database)
        try Settings.set(Settings.analysisBackendKey, to: "local", database: database)
        try Settings.set(Settings.localModelKey, to: tier.model, database: database)
        try Settings.set(
            Settings.localContextTokensKey, to: String(tier.contextTokens),
            database: database)
    }
}

/// URLSession's callbacks arrive on a background queue; everything the
/// fetcher publishes is main-actor. The delegate is the hop, nothing more.
private final class FetchDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var fetcher: ModelFetcher?

    init(fetcher: ModelFetcher) { self.fetcher = fetcher }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fetcher = fetcher
        DispatchQueue.main.async { fetcher?.report(written: totalBytesWritten) }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file dies when this callback returns, so the move
        // must happen before the main-actor hop — park it somewhere owned.
        let parked = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-weights-\(UUID().uuidString).gguf")
        do {
            try FileManager.default.moveItem(at: location, to: parked)
        } catch {
            let fetcher = fetcher
            DispatchQueue.main.async { fetcher?.fail(error) }
            return
        }
        let response = downloadTask.response
        let fetcher = fetcher
        DispatchQueue.main.async {
            fetcher?.finish(temporary: parked, response: response)
            try? FileManager.default.removeItem(at: parked)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let fetcher = fetcher
        DispatchQueue.main.async { fetcher?.fail(error) }
    }
}
