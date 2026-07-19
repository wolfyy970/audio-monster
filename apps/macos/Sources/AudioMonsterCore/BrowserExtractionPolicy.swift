import Foundation

public enum BrowserNavigationResponseDisposition: Equatable, Sendable {
    case allow
    case rejectHTTPStatus(Int)
}

/// Platform-neutral response handling shared by WebKit-based clients.
///
/// Only a failing main-document response should abort article extraction. A
/// stylesheet or image failure must not discard an otherwise readable page,
/// and redirect responses must remain available to the browser to follow.
public enum BrowserNavigationResponsePolicy {
    public static func disposition(
        isForMainFrame: Bool,
        httpStatusCode: Int?
    ) -> BrowserNavigationResponseDisposition {
        guard isForMainFrame,
            let httpStatusCode,
            (400..<600).contains(httpStatusCode)
        else {
            return .allow
        }
        return .rejectHTTPStatus(httpStatusCode)
    }
}

public struct SnapshotStabilityPolicy: Equatable, Sendable {
    public let minimumReadableCharacterCount: Int
    public let requiredConsecutiveStableSnapshots: Int
    public let maximumReadableSnapshotCount: Int

    public init(
        minimumReadableCharacterCount: Int,
        requiredConsecutiveStableSnapshots: Int,
        maximumReadableSnapshotCount: Int
    ) {
        self.minimumReadableCharacterCount = minimumReadableCharacterCount
        self.requiredConsecutiveStableSnapshots = requiredConsecutiveStableSnapshots
        self.maximumReadableSnapshotCount = maximumReadableSnapshotCount
    }

}

/// Platform-neutral tuning used by browser adapters without depending on WebKit.
public struct BrowserExtractionPolicy: Sendable {
    public static let standard = BrowserExtractionPolicy()

    public let stability: SnapshotStabilityPolicy
    public let maximumHTMLBytes: Int
    public let timeout: Duration
    public let requestTimeoutInterval: TimeInterval
    public let inspectionInterval: Duration
    public let webViewWidth: Double
    public let webViewHeight: Double
    public let applicationNameForUserAgent: String

    public init(
        minimumReadableCharacterCount: Int = 200,
        requiredConsecutiveStableSnapshots: Int = 2,
        maximumReadableSnapshotCount: Int = 5,
        maximumHTMLBytes: Int = 4 * 1024 * 1024,
        timeout: Duration = .seconds(30),
        requestTimeoutInterval: TimeInterval = 30,
        inspectionInterval: Duration = .milliseconds(400),
        webViewWidth: Double = 1_280,
        webViewHeight: Double = 900,
        applicationNameForUserAgent: String = "AudioMonster/0.2.0"
    ) {
        stability = SnapshotStabilityPolicy(
            minimumReadableCharacterCount: minimumReadableCharacterCount,
            requiredConsecutiveStableSnapshots: requiredConsecutiveStableSnapshots,
            maximumReadableSnapshotCount: maximumReadableSnapshotCount
        )
        self.maximumHTMLBytes = maximumHTMLBytes
        self.timeout = timeout
        self.requestTimeoutInterval = requestTimeoutInterval
        self.inspectionInterval = inspectionInterval
        self.webViewWidth = webViewWidth
        self.webViewHeight = webViewHeight
        self.applicationNameForUserAgent = applicationNameForUserAgent
    }
}
