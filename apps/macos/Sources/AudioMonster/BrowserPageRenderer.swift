import AudioMonsterCore
import Foundation
import WebKit

enum ArticleExtractionError: LocalizedError {
    case alreadyLoading
    case httpStatus(Int)
    case navigationFailed(String)
    case timedOut
    case pageTooLarge
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
            "The readable page text is larger than Audio Monster's 4 MB limit."
        case .noReadableContent:
            "No readable article content was found on the page."
        }
    }
}

@MainActor
protocol ArticleExtracting: AnyObject {
    func extract(url: URL) async throws -> ReadableArticle
}

@MainActor
final class BrowserPageRenderer: NSObject, ArticleExtracting, WKNavigationDelegate {
    typealias ExtractionMethod = BrowserExtractionMethod

    static let shared = BrowserPageRenderer()

    private static let readabilityContentWorld = WKContentWorld.world(
        name: "AudioMonster.MozillaReadability"
    )

    private let policy: BrowserExtractionPolicy
    private let scriptsProvider: () throws -> BrowserExtractionScripts

    private var activeRequestID: UUID?
    private var sourceURL: URL?
    private var snapshotSource: String?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ReadableArticle, any Error>?
    private var inspectionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private(set) var lastExtractionMethod: ExtractionMethod?

    init(
        policy: BrowserExtractionPolicy = .standard,
        scriptsProvider: @escaping () throws -> BrowserExtractionScripts =
            BrowserExtractionScripts.bundled
    ) {
        self.policy = policy
        self.scriptsProvider = scriptsProvider
        super.init()
    }

    func extract(url: URL) async throws -> ReadableArticle {
        guard activeRequestID == nil, continuation == nil else {
            throw ArticleExtractionError.alreadyLoading
        }

        let scripts = try scriptsProvider()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.applicationNameForUserAgent = policy.applicationNameForUserAgent
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: scripts.readabilitySource,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: Self.readabilityContentWorld
            ))

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
        snapshotSource = scripts.snapshotSource
        lastExtractionMethod = nil
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

                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        guard let self else { return }
                        try await Task.sleep(for: self.policy.timeout)
                        self.finish(
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
            var tracker = SnapshotStabilityTracker(policy: policy.stability)

            while !Task.isCancelled,
                activeRequestID == requestID,
                continuation != nil
            {
                do {
                    if let snapshot = try await snapshot(
                        of: webView,
                        source: snapshotSource
                    ), case .accept(let accepted) = tracker.observe(snapshot) {
                        accept(accepted, requestID: requestID)
                        return
                    }
                } catch {
                    // Browser checks can navigate while JavaScript is evaluated.
                }

                do {
                    try await Task.sleep(for: policy.inspectionInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func accept(_ snapshot: BrowserExtractionSnapshot, requestID: UUID) {
        guard snapshot.text.utf8.count <= policy.maximumTextBytes else {
            finish(.failure(ArticleExtractionError.pageTooLarge), requestID: requestID)
            return
        }
        guard let sourceURL,
            let resolvedURL = URL(string: snapshot.resolvedURL)
        else {
            finish(.failure(ArticleExtractionError.noReadableContent), requestID: requestID)
            return
        }
        lastExtractionMethod = snapshot.method
        finish(
            .success(
                ReadableArticle(
                    sourceURL: sourceURL,
                    resolvedURL: resolvedURL,
                    title: snapshot.title,
                    text: snapshot.text
                )), requestID: requestID)
    }

    private func snapshot(
        of webView: WKWebView,
        source: String
    ) async throws -> BrowserExtractionSnapshot? {
        let value = try await webView.callAsyncJavaScript(
            source,
            arguments: [
                "minimumReadableCharacterCount": policy.stability.minimumReadableCharacterCount,
                "readabilityMaximumElements": policy.readabilityMaximumElements,
                "readabilityTopCandidates": policy.readabilityTopCandidates,
            ],
            in: nil,
            contentWorld: Self.readabilityContentWorld
        )
        guard let json = value as? String,
            let data = json.data(using: .utf8)
        else { return nil }
        return try JSONDecoder().decode(BrowserExtractionSnapshot.self, from: data)
    }

    private func finish(
        _ result: Result<ReadableArticle, any Error>,
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
