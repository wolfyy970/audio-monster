import AudioMonsterCore
import Testing

struct BrowserNavigationResponsePolicyTests {
    @Test(
        arguments: [
            nil,
            100,
            200,
            204,
            301,
            307,
            399,
            600,
        ] as [Int?]
    )
    func allowsNonErrorMainFrameResponses(statusCode: Int?) {
        #expect(
            BrowserNavigationResponsePolicy.disposition(
                isForMainFrame: true,
                httpStatusCode: statusCode
            ) == .allow
        )
    }

    @Test(arguments: [400, 404, 429, 499, 500, 503, 599])
    func rejectsMainFrameHTTPClientAndServerErrors(statusCode: Int) {
        #expect(
            BrowserNavigationResponsePolicy.disposition(
                isForMainFrame: true,
                httpStatusCode: statusCode
            ) == .rejectHTTPStatus(statusCode)
        )
    }

    @Test(arguments: [400, 429, 500, 599])
    func allowsSubresourceErrors(statusCode: Int) {
        #expect(
            BrowserNavigationResponsePolicy.disposition(
                isForMainFrame: false,
                httpStatusCode: statusCode
            ) == .allow
        )
    }
}
