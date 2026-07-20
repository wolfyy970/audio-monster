import AudioMonsterCore
import Foundation
import Testing

@testable import AudioMonster

@MainActor
extension WebKitBackedExtractionTests {
    private var fastPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            minimumReadableCharacterCount: 40,
            requiredConsecutiveStableSnapshots: 2,
            maximumReadableSnapshotCount: 5,
            timeout: .seconds(3),
            inspectionInterval: .milliseconds(10)
        )
    }

    @Test
    func describesHTTPFailuresWithoutWaitingForExtractionTimeout() {
        let error = ArticleExtractionError.httpStatus(429)

        #expect(
            error.errorDescription
                == "The page could not be opened because the web server returned HTTP 429."
        )
    }

    @Test
    func rendersClientHydratedDOMThroughTheMinimalNativeBridge() async throws {
        let renderer = BrowserPageRenderer(policy: fastPolicy)
        let sourceURL = try dataURL(
            for: """
                <!doctype html>
                <html><head><title>Loading article</title></head><body>
                  <main id="app">Loading…</main>
                  <script>
                    setTimeout(() => {
                      document.title = "The Hydrated Article";
                      document.getElementById("app").innerHTML = `
                        <article data-rendered="client-side">
                          <h1>The Hydrated Article</h1>
                          <p>This paragraph arrived after navigation completed in the WebKit fixture.</p>
                          <p>The DOM snapshot must contain the client-rendered article for native parsing.</p>
                        </article>`;
                    }, 75);
                  </script>
                </body></html>
                """)

        let snapshot = try await renderer.render(url: sourceURL)

        #expect(snapshot.sourceURL == sourceURL)
        #expect(snapshot.resolvedURL == sourceURL)
        #expect(snapshot.title == "The Hydrated Article")
        #expect(snapshot.readyState == .complete)
        #expect(snapshot.ready)
        #expect(!snapshot.challenged)
        #expect(snapshot.textCharacterCount >= 40)
        #expect(snapshot.substantiveProseCharacterCount >= 40)
        #expect(snapshot.html.contains("data-rendered=\"client-side\""))
        #expect(snapshot.html.contains("client-rendered article for native parsing"))
    }

    @Test
    func rendersAnUntitledArticleWithoutWaitingForBrowserMetadata() async throws {
        let renderer = BrowserPageRenderer(policy: fastPolicy)
        let sourceURL = try dataURL(
            for: """
                <!doctype html><html><body>
                  <article>
                    <h1>The Visible Heading Is Enough</h1>
                    <p>A rendered article can be complete and readable even when the publisher never assigns a browser-tab title.</p>
                    <p>The WebKit stability gate must therefore depend on settled prose rather than metadata that may never exist.</p>
                  </article>
                </body></html>
                """)

        let snapshot = try await renderer.render(url: sourceURL)

        #expect(snapshot.title.isEmpty)
        #expect(snapshot.ready)
        #expect(snapshot.substantiveProseCharacterCount >= 40)
        #expect(snapshot.html.contains("The Visible Heading Is Enough"))
    }

    @Test
    func keepsSubmittedAndResolvedURLsSeparate() async throws {
        let resolvedURL = try #require(URL(string: "https://publisher.example/final-article"))
        let scripts = BrowserExtractionScripts(
            renderedDOMSnapshotSource: try bridgePayloadSource(
                resolvedURL: resolvedURL.absoluteString,
                title: "A Redirected Article",
                html: "<html><body><article>Resolved article body</article></body></html>",
                textCharacterCount: 320
            )
        )
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy) { scripts }
        let sourceURL = try dataURL(
            for: "<!doctype html><html><head><title>Redirecting</title></head><body></body></html>"
        )

        let snapshot = try await renderer.render(url: sourceURL)

        #expect(snapshot.sourceURL == sourceURL)
        #expect(snapshot.resolvedURL == resolvedURL)
        #expect(snapshot.sourceURL != snapshot.resolvedURL)
    }

    @Test
    func reportsAStableBrowserChallengeInsteadOfTreatingItAsArticleContent() async throws {
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy)
        let snapshot = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>Just a moment...</title></head><body>
                      <main>
                        <form id="challenge-form">
                          <p>Checking your browser before accessing the publisher.</p>
                        </form>
                      </main>
                    </body></html>
                    """))

        #expect(snapshot.ready)
        #expect(snapshot.challenged)
        #expect(snapshot.title == "Just a moment...")
        #expect(snapshot.html.contains("challenge-form"))
    }

    @Test
    func doesNotFlagOrdinaryEditorialDiscussionOfBrowserChallenges() async throws {
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy)
        let snapshot = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>Why CAPTCHA Design Matters</title></head><body>
                      <article>
                        <h1>Why CAPTCHA Design Matters</h1>
                        <p>This article discusses why a security checkpoint can frustrate readers without presenting a checkpoint itself.</p>
                        <p>Editorial use of words such as CAPTCHA and access denied must not be confused with an active browser challenge.</p>
                      </article>
                    </body></html>
                    """))

        #expect(!snapshot.challenged)
        #expect(snapshot.title == "Why CAPTCHA Design Matters")
    }

    @Test
    func challengeLikeTitleDoesNotRejectSubstantiveEditorialContent() async throws {
        let renderer = BrowserPageRenderer(policy: fastPolicy)
        let snapshot = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>Access Denied</title></head><body>
                      <article>
                        <h1>Access Denied</h1>
                        <p>This reported essay examines how public institutions restrict access to archival records and why those decisions deserve careful scrutiny.</p>
                        <p>A challenge-like headline is not sufficient evidence of browser verification when the rendered page already contains substantive editorial prose.</p>
                      </article>
                    </body></html>
                    """))

        #expect(!snapshot.challenged)
        #expect(snapshot.title == "Access Denied")
        #expect(snapshot.substantiveProseCharacterCount >= 40)
    }

    @Test
    func captchaWidgetBesideSubstantiveProseDoesNotRejectTheArticle() async throws {
        let policy = BrowserExtractionPolicy(
            minimumReadableCharacterCount: 200,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 1,
            timeout: .seconds(3),
            inspectionInterval: .milliseconds(5)
        )
        let renderer = BrowserPageRenderer(policy: policy)
        let snapshot = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>A Short Report</title></head><body>
                      <article>
                        <h1>A Short Report</h1>
                        <p>A legitimate article can share a document with an inactive CAPTCHA widget inserted by a comment form, consent tool, or publisher security vendor.</p>
                        <p>The presence of that widget alone must not replace substantive editorial prose with a browser-challenge error when the article is already available.</p>
                      </article>
                      <aside><div class="g-recaptcha"></div></aside>
                    </body></html>
                    """))

        #expect(!snapshot.challenged)
        #expect(snapshot.html.contains("A legitimate article"))
    }

    @Test
    func stripsInertScriptBloatBeforeApplyingTheDOMTransportLimit() async throws {
        let policy = BrowserExtractionPolicy(
            minimumReadableCharacterCount: 40,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 1,
            maximumHTMLBytes: 2_048,
            timeout: .seconds(3),
            inspectionInterval: .milliseconds(5)
        )
        let renderer = BrowserPageRenderer(policy: policy)
        let snapshot = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html><html><head><title>Bounded Transport</title></head><body>
                      <script type="application/ld+json">
                        {"@context":"https://schema.org","@type":"Article","headline":"Structured Transport Headline","author":{"@type":"Person","name":"Example Author"}}
                      </script>
                      <article><h1>Bounded Transport</h1>
                        <p>The rendered article remains small and readable even when a publisher injects a very large executable data payload beside it.</p>
                      </article>
                      <script>
                        const inert = document.createElement("script");
                        inert.textContent = "transport-bloat-marker" + "x".repeat(8192);
                        document.body.appendChild(inert);
                      </script>
                    </body></html>
                    """))

        #expect(snapshot.html.utf8.count < policy.maximumHTMLBytes)
        #expect(snapshot.html.contains("The rendered article remains small"))
        #expect(snapshot.html.contains("application/ld+json"))
        #expect(snapshot.html.contains("Structured Transport Headline"))
        #expect(!snapshot.html.contains("transport-bloat-marker"))
    }

    @Test
    func transportClonePreservesDocumentSemanticsAndRemovesOnlyBridgeNoise() async throws {
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy)
        let snapshot = try await renderer.render(
            url: dataURL(
                for: """
                    <!doctype html>
                    <html lang="en" data-shell="hydrated"><head>
                      <title>Semantic Transport</title>
                      <meta name="description" content="Metadata retained by the bridge.">
                      <script type="APPLICATION/LD+JSON; charset=utf-8" data-schema="article">
                        {"@context":"https://schema.org","@type":"Article","headline":"Semantic Transport"}
                      </script>
                      <style data-remove="style">article { color: red; }</style>
                    </head><body data-page="story">
                      <!-- transport-comment-marker -->
                      <noscript data-fallback="retained">A no-script summary remains document content.</noscript>
                      <article data-story-id="42">
                        <p class="lede">The serialized clone must preserve metadata, fallback content, element attributes, and article prose for native Readability.</p>
                      </article>
                      <script data-remove="executable">window.__transportNoise = true;</script>
                    </body></html>
                    """))

        #expect(snapshot.html.contains("lang=\"en\""))
        #expect(snapshot.html.contains("data-shell=\"hydrated\""))
        #expect(snapshot.html.contains("name=\"description\""))
        #expect(snapshot.html.contains("Metadata retained by the bridge."))
        #expect(snapshot.html.contains("APPLICATION/LD+JSON; charset=utf-8"))
        #expect(snapshot.html.contains("data-schema=\"article\""))
        #expect(snapshot.html.contains("<noscript data-fallback=\"retained\""))
        #expect(snapshot.html.contains("A no-script summary remains document content."))
        #expect(snapshot.html.contains("data-page=\"story\""))
        #expect(snapshot.html.contains("data-story-id=\"42\""))
        #expect(snapshot.html.contains("class=\"lede\""))
        #expect(!snapshot.html.contains("transport-comment-marker"))
        #expect(!snapshot.html.contains("data-remove=\"style\""))
        #expect(!snapshot.html.contains("data-remove=\"executable\""))
        #expect(!snapshot.html.contains("__transportNoise"))
    }

    @Test
    func rejectsOversizedSemanticDOMWithoutReturningItsHTMLToSwift() async throws {
        let policy = BrowserExtractionPolicy(
            minimumReadableCharacterCount: 1,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 1,
            maximumHTMLBytes: 512,
            timeout: .seconds(3),
            inspectionInterval: .milliseconds(5)
        )
        let renderer = BrowserPageRenderer(policy: policy)

        do {
            _ = try await renderer.render(
                url: dataURL(
                    for: """
                        <!doctype html><html><head><title>Oversized Article</title></head><body>
                          <article><p id="prose"></p></article>
                          <script>document.getElementById("prose").textContent = "a".repeat(2048);</script>
                        </body></html>
                        """))
            Issue.record("An oversized semantic DOM must fail at the bounded bridge.")
        } catch ArticleExtractionError.pageTooLarge {
            // Expected: the bridge reports size without transporting the HTML string.
        } catch {
            Issue.record("Expected pageTooLarge, received \(error).")
        }
    }

    @Test
    func rejectsAnOversizedBridgeSignalThatStillCarriesHTML() async throws {
        let scripts = BrowserExtractionScripts(
            renderedDOMSnapshotSource: """
                const shouldIncludeHTML = includeHTML === true;
                const html = shouldIncludeHTML
                  ? "<html><body>payload-that-should-have-been-omitted</body></html>"
                  : "";
                return JSON.stringify({
                  payloadKind: shouldIncludeHTML ? "renderedDocument" : "readinessProbe",
                  html,
                  htmlByteCount: shouldIncludeHTML ? maximumHTMLBytes + 1 : 0,
                  oversized: shouldIncludeHTML,
                  resolvedURL: "https://publisher.example/oversized-contract",
                  title: "Oversized Contract",
                  readyState: "complete",
                  challenged: false,
                  textCharacterCount: 320,
                  substantiveProseCharacterCount: 320,
                  stabilityFingerprint: "oversized-contract"
                });
                """)
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy) { scripts }

        do {
            _ = try await renderer.render(
                url: dataURL(for: "<!doctype html><html><body>Fixture</body></html>"))
            Issue.record("An oversized bridge payload must omit HTML before crossing into Swift.")
        } catch ArticleExtractionError.invalidBrowserSnapshot {
            // Expected: `oversized` is trusted only when the bridge omits the HTML.
        } catch {
            Issue.record("Expected invalidBrowserSnapshot, received \(error).")
        }
    }

    @Test
    func malformedBridgePayloadFailsClosed() async throws {
        let scripts = BrowserExtractionScripts(
            renderedDOMSnapshotSource: "return JSON.stringify({ readyState: 'complete' });"
        )
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy) { scripts }

        do {
            _ = try await renderer.render(
                url: dataURL(for: "<!doctype html><html><body>Page</body></html>"))
            Issue.record("A malformed bridge payload must never become a rendered document.")
        } catch ArticleExtractionError.invalidBrowserSnapshot {
            // Expected: schema decoding and required-field validation are fail closed.
        } catch {
            Issue.record("Expected invalidBrowserSnapshot, received \(error).")
        }
    }

    @Test
    func legacyBodyTextOnlyBridgePayloadFailsClosed() async throws {
        let scripts = BrowserExtractionScripts(
            renderedDOMSnapshotSource: """
                const html = "<html><body><article>Legacy article body</article></body></html>";
                return JSON.stringify({
                  html,
                  htmlByteCount: new TextEncoder().encode(html).byteLength,
                  oversized: false,
                  resolvedURL: "https://publisher.example/legacy",
                  title: "Legacy Payload",
                  readyState: "complete",
                  challenged: false,
                  textCharacterCount: 320,
                  stabilityFingerprint: "legacy-body-text-only"
                });
                """
        )
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy) { scripts }

        do {
            _ = try await renderer.render(
                url: dataURL(for: "<!doctype html><html><body>Page</body></html>"))
            Issue.record("A legacy payload without the typed prose signal must fail closed.")
        } catch ArticleExtractionError.invalidBrowserSnapshot {
            // Expected: payload kind and substantive prose count are required.
        } catch {
            Issue.record("Expected invalidBrowserSnapshot, received \(error).")
        }
    }

    @Test
    func negativeSubstantiveProseCountFailsClosed() async throws {
        let scripts = BrowserExtractionScripts(
            renderedDOMSnapshotSource: try bridgePayloadSource(
                resolvedURL: "https://publisher.example/invalid-count",
                title: "Invalid Count",
                html: "<html><body><article>Article body</article></body></html>",
                textCharacterCount: 320,
                substantiveProseCharacterCount: -1
            )
        )
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy) { scripts }

        do {
            _ = try await renderer.render(
                url: dataURL(for: "<!doctype html><html><body>Page</body></html>"))
            Issue.record("A negative substantive prose count must fail closed.")
        } catch ArticleExtractionError.invalidBrowserSnapshot {
            // Expected: numeric readiness fields are range checked in Swift.
        } catch {
            Issue.record("Expected invalidBrowserSnapshot, received \(error).")
        }
    }

    @Test
    func bridgeIsCompiledInAndContainsNoBrowserSideReadabilityImplementation() {
        let source = BrowserExtractionScripts.renderedDOMSnapshot.renderedDOMSnapshotSource

        #expect(source.contains("document.documentElement"))
        #expect(source.contains("outerHTML"))
        #expect(source.contains("includeHTML === true"))
        #expect(source.contains("substantiveProseCharacterCount"))
        #expect(!source.contains("function Readability"))
        #expect(!source.contains("mozilla-readability"))
        #expect(!source.contains("Snapshot.js"))
        #expect(!source.contains(".parse("))
    }

    @Test
    func serializesRenderedDOMOnceAfterLightweightReadinessStabilizes() async throws {
        let scripts = BrowserExtractionScripts(
            renderedDOMSnapshotSource: """
                window.__audioMonsterEvaluationCount =
                  (window.__audioMonsterEvaluationCount ?? 0) + 1;
                if (includeHTML === true) {
                  window.__audioMonsterSerializationCount =
                    (window.__audioMonsterSerializationCount ?? 0) + 1;
                }
                const html = includeHTML === true
                  ? `<html data-evaluation-count="${window.__audioMonsterEvaluationCount}" data-serialization-count="${window.__audioMonsterSerializationCount}"><body>Stable article</body></html>`
                  : "";
                return JSON.stringify({
                  payloadKind: includeHTML === true ? "renderedDocument" : "readinessProbe",
                  html,
                  htmlByteCount: new TextEncoder().encode(html).byteLength,
                  oversized: false,
                  resolvedURL: "https://publisher.example/article",
                  title: "Stable Article",
                  readyState: "complete",
                  challenged: false,
                  textCharacterCount: 320,
                  substantiveProseCharacterCount: 320,
                  stabilityFingerprint: "same-content"
                });
                """
        )
        let renderer = BrowserPageRenderer(policy: fastPolicy) { scripts }

        let snapshot = try await renderer.render(
            url: dataURL(for: "<!doctype html><html><body>Fixture</body></html>"))

        #expect(snapshot.html.contains("data-evaluation-count=\"3\""))
        #expect(snapshot.html.contains("data-serialization-count=\"1\""))
        #expect(snapshot.stabilityFingerprint == "same-content")
    }

    @Test
    func rejectsAConcurrentRenderAndCancelsTheActiveRequestPromptly() async throws {
        let renderer = BrowserPageRenderer(policy: fastPolicy)
        let waitingURL = try dataURL(
            for: """
                <!doctype html><html><head><title>Waiting</title></head>
                <body><main>Not enough content yet.</main></body></html>
                """)
        let firstRequest = Task { @MainActor in
            try await renderer.render(url: waitingURL)
        }
        try await Task.sleep(for: .milliseconds(25))

        do {
            _ = try await renderer.render(url: waitingURL)
            Issue.record("A concurrent browser render should be rejected.")
        } catch ArticleExtractionError.alreadyLoading {
            // Expected.
        } catch {
            Issue.record("Expected alreadyLoading, received \(error).")
        }

        firstRequest.cancel()
        do {
            _ = try await firstRequest.value
            Issue.record("The active browser render should finish with cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected cancellation, received \(error).")
        }
    }

    @Test
    func handlesCancellationBeforeContinuationSetupAndAllowsTheNextRender() async throws {
        let renderer = BrowserPageRenderer(policy: singleSnapshotPolicy)
        let pageURL = try dataURL(
            for: """
                <!doctype html><html><head><title>Cancellation Fixture</title></head>
                <body><main>This document is valid, but its first render is cancelled immediately.</main></body></html>
                """)
        let cancelledRequest = Task { @MainActor in
            try await renderer.render(url: pageURL)
        }
        cancelledRequest.cancel()

        do {
            _ = try await cancelledRequest.value
            Issue.record("A pre-cancelled render should not wait for its timeout.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected cancellation, received \(error).")
        }

        let nextSnapshot = try await renderer.render(url: pageURL)
        #expect(nextSnapshot.title == "Cancellation Fixture")
        #expect(nextSnapshot.sourceURL == pageURL)
    }

    private var singleSnapshotPolicy: BrowserExtractionPolicy {
        BrowserExtractionPolicy(
            minimumReadableCharacterCount: 1,
            requiredConsecutiveStableSnapshots: 1,
            maximumReadableSnapshotCount: 1,
            timeout: .seconds(3),
            inspectionInterval: .milliseconds(5)
        )
    }

    private func bridgePayloadSource(
        resolvedURL: String,
        title: String,
        html: String,
        textCharacterCount: Int,
        substantiveProseCharacterCount: Int? = nil
    ) throws -> String {
        let payload: [String: Any] = [
            "html": html,
            "htmlByteCount": html.utf8.count,
            "oversized": false,
            "resolvedURL": resolvedURL,
            "title": title,
            "readyState": "complete",
            "challenged": false,
            "textCharacterCount": textCharacterCount,
            "substantiveProseCharacterCount": substantiveProseCharacterCount
                ?? textCharacterCount,
            "stabilityFingerprint": "fixture-fingerprint",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return """
            const payload = \(json);
            const shouldIncludeHTML = includeHTML === true;
            payload.payloadKind = shouldIncludeHTML
              ? "renderedDocument"
              : "readinessProbe";
            if (!shouldIncludeHTML) {
              payload.html = "";
              payload.htmlByteCount = 0;
              payload.oversized = false;
            }
            return JSON.stringify(payload);
            """
    }

    private func dataURL(for html: String) throws -> URL {
        let encoded = Data(html.utf8).base64EncodedString()
        return try #require(URL(string: "data:text/html;charset=utf-8;base64,\(encoded)"))
    }
}
