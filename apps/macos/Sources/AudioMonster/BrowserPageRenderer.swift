import AudioMonsterCore
import Foundation
import WebKit

enum ArticleExtractionError: LocalizedError {
    case alreadyLoading
    case httpStatus(Int)
    case navigationFailed(String)
    case timedOut
    case pageTooLarge
    case invalidBrowserSnapshot
    case accessChallenge
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .alreadyLoading:
            "Another page is already being read."
        case .httpStatus(let statusCode):
            "The page could not be opened because the web server returned HTTP \(statusCode)."
        case .navigationFailed(let message):
            "The page could not be opened: \(message)"
        case .timedOut:
            "The website did not finish loading within 30 seconds."
        case .pageTooLarge:
            "The rendered page is larger than Audio Monster's 4 MB limit."
        case .invalidBrowserSnapshot:
            "The browser returned an invalid rendered-page snapshot."
        case .accessChallenge:
            "The website presented a browser verification challenge instead of the article."
        case .noReadableContent:
            "No readable article content was found on the page."
        }
    }
}

@MainActor
protocol RenderedPageRendering: AnyObject {
    func render(url: URL) async throws -> RenderedPageSnapshot
}

@MainActor
final class BrowserPageRenderer: NSObject, RenderedPageRendering, WKNavigationDelegate {
    static let shared = BrowserPageRenderer()

    private static let snapshotContentWorld = WKContentWorld.world(
        name: "AudioMonster.RenderedDOMSnapshot"
    )

    private let policy: BrowserExtractionPolicy
    private let scriptsProvider: @Sendable () -> BrowserExtractionScripts

    private var activeRequestID: UUID?
    private var sourceURL: URL?
    private var snapshotSource: String?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<RenderedPageSnapshot, any Error>?
    private var inspectionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        policy: BrowserExtractionPolicy = .standard,
        scriptsProvider: @escaping @Sendable () -> BrowserExtractionScripts = {
            .renderedDOMSnapshot
        }
    ) {
        self.policy = policy
        self.scriptsProvider = scriptsProvider
        super.init()
    }

    func render(url: URL) async throws -> RenderedPageSnapshot {
        guard activeRequestID == nil, continuation == nil else {
            throw ArticleExtractionError.alreadyLoading
        }

        let scripts = scriptsProvider()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.applicationNameForUserAgent = policy.applicationNameForUserAgent

        let webView = WKWebView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: policy.webViewWidth,
                height: policy.webViewHeight
            ),
            configuration: configuration
        )
        let requestID = UUID()
        webView.navigationDelegate = self
        activeRequestID = requestID
        sourceURL = url
        snapshotSource = scripts.renderedDOMSnapshotSource
        self.webView = webView

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation

                // A cancellation handler can run before its operation installs the
                // continuation. Checking here closes that race without leaving a
                // request waiting for the normal timeout.
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()), requestID: requestID)
                    return
                }

                let timeout = policy.timeout
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        self?.finish(
                            .failure(ArticleExtractionError.timedOut),
                            requestID: requestID
                        )
                    } catch {
                        // Cancellation is the normal cleanup path for this timer.
                    }
                }
                webView.load(
                    URLRequest(
                        url: url,
                        timeoutInterval: policy.requestTimeoutInterval
                    ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()), requestID: requestID)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let requestID = activeRequestID else { return }
        inspectUntilReady(webView, requestID: requestID)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard webView === self.webView else {
            decisionHandler(.cancel)
            return
        }

        let statusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        let disposition = BrowserNavigationResponsePolicy.disposition(
            isForMainFrame: navigationResponse.isForMainFrame,
            httpStatusCode: statusCode
        )
        switch disposition {
        case .allow:
            decisionHandler(.allow)
        case .rejectHTTPStatus(let statusCode):
            decisionHandler(.cancel)
            guard let requestID = activeRequestID else { return }
            finish(
                .failure(ArticleExtractionError.httpStatus(statusCode)),
                requestID: requestID
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard webView === self.webView,
            let requestID = activeRequestID,
            !isCancelledNavigation(error)
        else { return }
        finish(
            .failure(ArticleExtractionError.navigationFailed(error.localizedDescription)),
            requestID: requestID
        )
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard webView === self.webView,
            let requestID = activeRequestID,
            !isCancelledNavigation(error)
        else { return }
        finish(
            .failure(ArticleExtractionError.navigationFailed(error.localizedDescription)),
            requestID: requestID
        )
    }

    private func inspectUntilReady(_ webView: WKWebView, requestID: UUID) {
        inspectionTask?.cancel()
        inspectionTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, let snapshotSource = self.snapshotSource else { return }
            var tracker = RenderedPageStabilityTracker(policy: policy.stability)

            while !Task.isCancelled,
                activeRequestID == requestID,
                continuation != nil
            {
                do {
                    let probe = try await readinessProbe(
                        of: webView,
                        source: snapshotSource
                    )
                    if tracker.observe(probe) {
                        let renderedDocument = try await snapshot(
                            of: webView,
                            source: snapshotSource
                        )
                        let finalProbe = renderedDocument.readinessProbe
                        if tracker.matchesCurrentSignal(finalProbe)
                            || tracker.observe(finalProbe)
                        {
                            accept(renderedDocument, requestID: requestID)
                            return
                        }
                    }
                } catch ArticleExtractionError.invalidBrowserSnapshot {
                    finish(
                        .failure(ArticleExtractionError.invalidBrowserSnapshot),
                        requestID: requestID
                    )
                    return
                } catch ArticleExtractionError.pageTooLarge {
                    finish(
                        .failure(ArticleExtractionError.pageTooLarge),
                        requestID: requestID
                    )
                    return
                } catch {
                    // A navigation can replace the document while JavaScript is being
                    // evaluated. Treat that WebKit error as transient and inspect the
                    // newly active document on the next interval.
                }

                do {
                    try await Task.sleep(for: policy.inspectionInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func accept(_ snapshot: RenderedPageSnapshot, requestID: UUID) {
        guard snapshot.html.utf8.count <= policy.maximumHTMLBytes else {
            finish(.failure(ArticleExtractionError.pageTooLarge), requestID: requestID)
            return
        }
        finish(.success(snapshot), requestID: requestID)
    }

    private func snapshot(
        of webView: WKWebView,
        source: String
    ) async throws -> RenderedPageSnapshot {
        let (payload, sourceURL, resolvedURL) = try await bridgePayload(
            from: webView,
            source: source,
            includeHTML: true
        )
        guard payload.payloadKind == .renderedDocument else {
            throw ArticleExtractionError.invalidBrowserSnapshot
        }
        if payload.oversized {
            guard payload.html.isEmpty,
                payload.htmlByteCount > policy.maximumHTMLBytes
            else {
                throw ArticleExtractionError.invalidBrowserSnapshot
            }
            throw ArticleExtractionError.pageTooLarge
        }
        guard !payload.html.isEmpty,
            payload.html.utf8.count == payload.htmlByteCount,
            payload.htmlByteCount <= policy.maximumHTMLBytes
        else {
            throw ArticleExtractionError.invalidBrowserSnapshot
        }

        return RenderedPageSnapshot(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: payload.title,
            html: payload.html,
            readyState: payload.readyState,
            challenged: payload.challenged,
            textCharacterCount: payload.textCharacterCount,
            substantiveProseCharacterCount: payload.substantiveProseCharacterCount,
            stabilityFingerprint: payload.stabilityFingerprint
        )
    }

    private func readinessProbe(
        of webView: WKWebView,
        source: String
    ) async throws -> RenderedPageReadinessProbe {
        let (payload, sourceURL, resolvedURL) = try await bridgePayload(
            from: webView,
            source: source,
            includeHTML: false
        )
        guard payload.payloadKind == .readinessProbe,
            payload.html.isEmpty,
            payload.htmlByteCount == 0,
            !payload.oversized
        else {
            throw ArticleExtractionError.invalidBrowserSnapshot
        }

        return RenderedPageReadinessProbe(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: payload.title,
            readyState: payload.readyState,
            challenged: payload.challenged,
            textCharacterCount: payload.textCharacterCount,
            substantiveProseCharacterCount: payload.substantiveProseCharacterCount,
            stabilityFingerprint: payload.stabilityFingerprint
        )
    }

    private func bridgePayload(
        from webView: WKWebView,
        source: String,
        includeHTML: Bool
    ) async throws -> (RenderedPageBridgePayload, URL, URL) {
        let value = try await webView.callAsyncJavaScript(
            source,
            arguments: [
                "includeHTML": includeHTML,
                "maximumHTMLBytes": policy.maximumHTMLBytes,
                "minimumReadableCharacterCount": policy.stability.minimumReadableCharacterCount,
            ],
            in: nil,
            contentWorld: Self.snapshotContentWorld
        )
        guard let json = value as? String,
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(RenderedPageBridgePayload.self, from: data),
            !payload.stabilityFingerprint.isEmpty,
            payload.htmlByteCount >= 0,
            payload.textCharacterCount >= 0,
            payload.substantiveProseCharacterCount >= 0,
            let sourceURL,
            let resolvedURL = URL(string: payload.resolvedURL),
            resolvedURL.scheme != nil
        else {
            throw ArticleExtractionError.invalidBrowserSnapshot
        }
        return (payload, sourceURL, resolvedURL)
    }

    private func finish(
        _ result: Result<RenderedPageSnapshot, any Error>,
        requestID: UUID
    ) {
        // Cancellation delivery is asynchronous. A token prevents an old request's
        // handler or delegate callback from completing a newer continuation.
        guard activeRequestID == requestID, let continuation else { return }
        self.continuation = nil
        activeRequestID = nil
        inspectionTask?.cancel()
        timeoutTask?.cancel()
        inspectionTask = nil
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        sourceURL = nil
        snapshotSource = nil
        continuation.resume(with: result)
    }

    private func isCancelledNavigation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

/// Accepts a stable DOM from lightweight browser-computed signals. No HTML is
/// cloned or transported until this tracker asks for the final rendered document.
private struct RenderedPageStabilityTracker {
    private struct Signal: Equatable {
        let resolvedURL: URL
        let title: String
        let challenged: Bool
        let substantiveProseCharacterCount: Int
        let fingerprint: String
    }

    private let policy: SnapshotStabilityPolicy
    private var previousSignal: Signal?
    private var consecutiveStableSnapshots = 0
    private var candidateSnapshotCount = 0

    init(policy: SnapshotStabilityPolicy) {
        self.policy = policy
    }

    mutating func observe(_ probe: RenderedPageReadinessProbe) -> Bool {
        guard isCandidate(probe)
        else {
            previousSignal = nil
            consecutiveStableSnapshots = 0
            candidateSnapshotCount = 0
            return false
        }

        candidateSnapshotCount += 1
        let signal = signal(for: probe)
        if signal == previousSignal {
            consecutiveStableSnapshots += 1
        } else {
            previousSignal = signal
            consecutiveStableSnapshots = 1
        }

        if consecutiveStableSnapshots >= policy.requiredConsecutiveStableSnapshots
            || candidateSnapshotCount >= policy.maximumReadableSnapshotCount
        {
            return true
        }
        return false
    }

    func matchesCurrentSignal(_ probe: RenderedPageReadinessProbe) -> Bool {
        isCandidate(probe) && signal(for: probe) == previousSignal
    }

    private func isCandidate(_ probe: RenderedPageReadinessProbe) -> Bool {
        probe.ready
            && (probe.challenged
                || probe.substantiveProseCharacterCount
                    >= policy.minimumReadableCharacterCount)
    }

    private func signal(for probe: RenderedPageReadinessProbe) -> Signal {
        Signal(
            resolvedURL: probe.resolvedURL,
            title: probe.title,
            challenged: probe.challenged,
            substantiveProseCharacterCount: probe.substantiveProseCharacterCount,
            fingerprint: probe.stabilityFingerprint
        )
    }
}
