import AudioMonsterCore
import Foundation
import Testing

struct BrowserNavigationFailurePolicyTests {
    @Test
    func classifiesCancelledURLErrors() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: nil
        )

        #expect(BrowserNavigationFailurePolicy.kind(for: error) == .cancelled)
    }

    @Test
    func classifiesAppTransportSecurityErrors() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection,
            userInfo: nil
        )

        #expect(BrowserNavigationFailurePolicy.kind(for: error) == .appTransportSecurity)
    }

    @Test
    func walksThroughWrappedWebKitErrorsToFindAppTransportSecurity() {
        let ats = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection,
            userInfo: nil
        )
        let wrapped = NSError(
            domain: "WebKitErrorDomain",
            code: 102,
            userInfo: [NSUnderlyingErrorKey: ats]
        )

        #expect(BrowserNavigationFailurePolicy.kind(for: wrapped) == .appTransportSecurity)
    }

    @Test
    func walksThroughNestedWrappersToFindCancellation() {
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: nil
        )
        let inner = NSError(
            domain: "WebKitErrorDomain",
            code: 102,
            userInfo: [NSUnderlyingErrorKey: cancelled]
        )
        let outer = NSError(
            domain: "WKErrorDomain",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: inner]
        )

        #expect(BrowserNavigationFailurePolicy.kind(for: outer) == .cancelled)
    }

    @Test
    func treatsUnknownURLErrorsAsOtherFailures() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: nil
        )

        #expect(BrowserNavigationFailurePolicy.kind(for: error) == .other)
    }

    @Test
    func treatsDeeplyWrappedUnknownErrorsAsOtherFailures() {
        let first = NSError(domain: "Nested", code: 1, userInfo: nil)
        let second = NSError(
            domain: "Nested",
            code: 2,
            userInfo: [NSUnderlyingErrorKey: first]
        )
        let outer = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnknown,
            userInfo: [NSUnderlyingErrorKey: second]
        )

        #expect(BrowserNavigationFailurePolicy.kind(for: outer) == .other)
    }
}
