import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
extension WebKitBackedExtractionTests {
    private var httpPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            minimumReadableCharacterCount: 40,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 2,
            timeout: .seconds(5),
            requestTimeoutInterval: 5,
            inspectionInterval: .milliseconds(10)
        )
    }

    @Test
    func extractsACompleteArticleOverLoopbackHTTP() async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: ["/IncIdeas/BitterLesson.html": .html(ArticleHTTPFixturePages.essay)]
        )
        defer { server.finish() }
        let pageURL = server.url("/IncIdeas/BitterLesson.html")
        let extractor = NativeArticleExtractor(
            renderer: BrowserPageRenderer(policy: httpPolicy),
            parser: SwiftReadabilityArticleParser()
        )

        let article = try await extractor.extract(url: pageURL)

        #expect(article.title == "The HTTP Essay")
        #expect(article.text.contains("ordinary HTTP pages"))
        #expect(article.text.contains("independent publishers"))
        #expect(!article.text.contains("Publisher chrome"))
        #expect(article.sourceURL == pageURL)
        #expect(article.resolvedURL == pageURL)
        #expect(pageURL.scheme == "http")
    }

    @Test
    func preservesSubmittedHTTPURLAcrossARelativeRedirect() async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: [
                "/start": .redirect(to: "/final-article"),
                "/final-article": .html(ArticleHTTPFixturePages.redirectedEssay),
            ]
        )
        defer { server.finish() }
        let submitted = server.url("/start")
        let resolved = server.url("/final-article")
        let renderer = BrowserPageRenderer(policy: httpPolicy)

        let snapshot = try await renderer.render(url: submitted)

        #expect(snapshot.sourceURL == submitted)
        #expect(snapshot.resolvedURL == resolved)
        #expect(snapshot.title == "The Redirected HTTP Essay")
        #expect(snapshot.html.contains("Relative and absolute redirects"))
    }

    @Test(arguments: [301, 302, 307, 308])
    func followsHTTPRedirectStatusCodes(_ status: Int) async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: [
                "/hop": .html("<p>placeholder</p>"),
                "/essay": .html(ArticleHTTPFixturePages.redirectedEssay),
            ]
        )
        defer { server.finish() }
        server.set("/hop", response: .redirect(to: "/essay", status: status))
        let renderer = BrowserPageRenderer(policy: httpPolicy)

        let snapshot = try await renderer.render(url: server.url("/hop"))

        #expect(snapshot.resolvedURL == server.url("/essay"))
        #expect(snapshot.title == "The Redirected HTTP Essay")
    }

    @Test
    func followsAnAbsoluteHTTPRedirectOnTheSameOrigin() async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: ["/essay": .html(ArticleHTTPFixturePages.redirectedEssay)]
        )
        defer { server.finish() }
        server.set(
            "/out",
            response: .redirect(to: server.url("/essay").absoluteString, status: 302)
        )
        let renderer = BrowserPageRenderer(policy: httpPolicy)

        let snapshot = try await renderer.render(url: server.url("/out"))

        #expect(snapshot.sourceURL == server.url("/out"))
        #expect(snapshot.resolvedURL == server.url("/essay"))
    }

    @Test
    func keepsQueryParametersOnAnHTTPArticleURL() async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: ["/article": .html(ArticleHTTPFixturePages.essay)]
        )
        defer { server.finish() }
        let pageURL = server.url("/article?edition=morning&format=html")
        let renderer = BrowserPageRenderer(policy: httpPolicy)

        let snapshot = try await renderer.render(url: pageURL)

        #expect(snapshot.sourceURL == pageURL)
        #expect(snapshot.title == "The HTTP Essay")
    }

    @Test(arguments: [404, 429, 503])
    func rejectsMainFrameHTTPErrorStatusesWithoutWaitingForProse(_ status: Int) async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: ["/fail": .status(status)]
        )
        defer { server.finish() }
        let renderer = BrowserPageRenderer(policy: httpPolicy)

        do {
            _ = try await renderer.render(url: server.url("/fail"))
            Issue.record("HTTP \(status) must fail closed before snapshot polling.")
        } catch ArticleExtractionError.httpStatus(let code) {
            #expect(code == status)
        } catch {
            Issue.record("Expected httpStatus(\(status)), received \(error).")
        }
    }

    @Test
    func stillExtractsWhenAnHTTPSubresourceFails() async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: [
                "/illustrated": .html(
                    ArticleHTTPFixturePages.essayWithBrokenImage(imagePath: "/missing.png")
                ),
                "/missing.png": .status(404),
            ]
        )
        defer { server.finish() }
        let extractor = NativeArticleExtractor(
            renderer: BrowserPageRenderer(policy: httpPolicy),
            parser: SwiftReadabilityArticleParser()
        )

        let article = try await extractor.extract(url: server.url("/illustrated"))

        #expect(article.title == "The Illustrated HTTP Essay")
        #expect(article.text.contains("missing image must not discard"))
        #expect(article.text.contains("second paragraph"))
    }

    @Test
    func timesOutWhenTheHTTPServerNeverResponds() async throws {
        let policy = BrowserExtractionPolicy(
            timeout: .milliseconds(250),
            requestTimeoutInterval: 5,
            inspectionInterval: .milliseconds(10)
        )
        let server = try await ArticleHTTPFixtureServer.start(
            routes: [:],
            hangingPaths: ["/hang"]
        )
        defer { server.finish() }
        let renderer = BrowserPageRenderer(policy: policy)

        do {
            _ = try await renderer.render(url: server.url("/hang"))
            Issue.record("A hanging HTTP server must not be treated as a successful render.")
        } catch ArticleExtractionError.timedOut {
            // Expected.
        } catch {
            Issue.record("Expected timedOut, received \(error).")
        }
    }

    @Test
    func reportsNavigationFailureWhenTheHTTPPortIsClosed() async throws {
        let server = try await ArticleHTTPFixtureServer.start(
            routes: ["/essay": .html(ArticleHTTPFixturePages.essay)]
        )
        let closedURL = server.url("/essay")
        server.finish()
        try await Task.sleep(for: .milliseconds(50))
        let renderer = BrowserPageRenderer(policy: httpPolicy)

        do {
            _ = try await renderer.render(url: closedURL)
            Issue.record("A closed HTTP port must not be treated as a successful render.")
        } catch ArticleExtractionError.navigationFailed(let message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected navigationFailed, received \(error).")
        }
    }

    @Test
    func describesInsecureConnectionFailuresWithoutTheRawSystemString() {
        let error = ArticleExtractionError.insecureConnection

        #expect(
            error.errorDescription
                == "The page could not be opened because it uses an insecure HTTP connection."
        )
    }
}
