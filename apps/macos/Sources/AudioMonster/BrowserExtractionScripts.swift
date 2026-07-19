import Foundation

/// JavaScript kept at the WebKit boundary to observe and serialize the rendered DOM.
///
/// Article selection deliberately does not happen here. Lightweight probes report
/// only document state and a count of ordinary prose-shaped blocks. Once that
/// signal settles, one bounded DOM clone is sent to the native parser with only
/// non-JSON-LD scripts, style elements, and comments removed from the transport.
struct BrowserExtractionScripts: Sendable {
    let renderedDOMSnapshotSource: String

    static let renderedDOMSnapshot = BrowserExtractionScripts(
        renderedDOMSnapshotSource: #"""
            const root = document.documentElement;
            const bodyText = (document.body?.innerText ?? document.body?.textContent ?? "")
              .replace(/\s+/gu, " ")
              .trim();
            const title = (document.title ?? "").trim();
            const resolvedURL = document.location.href;

            // This is a readiness signal, not an article selector. It counts text
            // from prose-shaped leaf blocks while excluding explicit interface
            // regions. Mozilla Readability in Swift still receives the complete
            // rendered DOM and makes every article-selection decision.
            const pageFurnitureSelector = [
              "nav",
              "header",
              "footer",
              "aside",
              "form",
              "dialog",
              "menu",
              "[role='navigation']",
              "[role='banner']",
              "[role='contentinfo']",
              "[role='complementary']",
              "[role='dialog']",
              "[role='alertdialog']",
              "[role='menu']",
              "[role='menubar']",
              "[role='toolbar']",
              "[aria-modal='true']",
              "[aria-hidden='true']",
              "[hidden]"
            ].join(", ");
            const primaryProseSelector = "p, blockquote, pre, li";
            const fallbackProseSelector = [
              "article",
              "[role='article']",
              "[itemprop~='articleBody']",
              "main",
              "section",
              "div"
            ].join(", ");
            const normalizeText = (node) =>
              (node?.innerText ?? node?.textContent ?? "")
                .replace(/\s+/gu, " ")
                .trim();
            const isInterfaceRegion = (node) =>
              node.closest(pageFurnitureSelector) !== null;
            const isLinkHeavy = (node, text) => {
              const linkedText = Array.from(node.querySelectorAll("a"))
                .map(normalizeText)
                .join(" ")
                .replace(/\s+/gu, " ")
                .trim();
              return linkedText.length * 2 > text.length;
            };
            const proseFragments = [];
            document.querySelectorAll(primaryProseSelector).forEach((node) => {
              // Keep only the deepest prose node so nested list items or quoted
              // paragraphs are measured once.
              if (isInterfaceRegion(node) || node.querySelector(primaryProseSelector)) return;
              const text = normalizeText(node);
              if (text.length > 0 && !isLinkHeavy(node, text)) proseFragments.push(text);
            });
            document.querySelectorAll(fallbackProseSelector).forEach((node) => {
              // Generic leaf blocks cover div-heavy publishers without assuming
              // that any one block is the article.
              if (isInterfaceRegion(node)
                || node.querySelector(primaryProseSelector)
                || node.querySelector(fallbackProseSelector)) return;
              const text = normalizeText(node);
              if (text.length > 0 && !isLinkHeavy(node, text)) proseFragments.push(text);
            });
            const substantiveProseText = proseFragments
              .join(" ")
              .replace(/\s+/gu, " ")
              .trim();
            const substantiveProseCharacterCount = substantiveProseText.length;

            const challengeSelector = [
              "#challenge-form",
              "#cf-challenge-running",
              "#px-captcha",
              ".g-recaptcha",
              "iframe[src*='challenges.cloudflare.com']",
              "input[name='cf-turnstile-response']",
              "[data-captcha-provider]"
            ].some((selector) => document.querySelector(selector) !== null);
            const challengeCopy = bodyText.slice(0, 1200);
            const challengeTitle = /^(?:just a moment|checking your browser|security checkpoint|access denied|captcha)[.!…\s-]*$/iu
              .test(title);
            const browserChallengePhrase = /(?:checking your browser|enable javascript and cookies)/iu
              .test(challengeCopy);
            const interactiveChallengePhrase = /(?:verify (?:that )?you(?:'re| are) (?:a )?human|complete (?:the )?(?:security )?(?:check|captcha))/iu
              .test(challengeCopy);
            const configuredReadableThreshold = Number(minimumReadableCharacterCount);
            const readableThreshold = Number.isSafeInteger(configuredReadableThreshold)
              && configuredReadableThreshold > 0
              ? configuredReadableThreshold
              : 200;
            const hasSubstantiveEditorialContent =
              substantiveProseCharacterCount >= readableThreshold;

            // A compact fingerprint lets Swift wait for a stable rendered page
            // without comparing or retaining multiple potentially large HTML strings.
            const semanticShape = [
              document.getElementsByTagName("*").length,
              document.getElementsByTagName("article").length,
              document.getElementsByTagName("main").length,
              document.getElementsByTagName("p").length
            ].join(":");
            const fingerprintInput = `${resolvedURL}\u0000${title}\u0000${semanticShape}\u0000${substantiveProseText}`;
            let fingerprint = 0x811c9dc5;
            for (let index = 0; index < fingerprintInput.length; index += 1) {
              fingerprint ^= fingerprintInput.charCodeAt(index);
              fingerprint = Math.imul(fingerprint, 0x01000193);
            }

            const shouldSerializeHTML = includeHTML === true;
            let serializedHTML = "";
            let htmlByteCount = 0;
            let oversized = false;
            if (shouldSerializeHTML) {
              // Transport a content-equivalent clone rather than executable and
              // presentation payloads that native Readability removes itself.
              // JSON-LD remains available because Mozilla reads it as metadata.
              const transportRoot = root?.cloneNode(true) ?? null;
              transportRoot?.querySelectorAll("script, style").forEach((node) => {
                const scriptMediaType = (node.getAttribute("type") ?? "")
                  .split(";", 1)[0]
                  .trim()
                  .toLowerCase();
                const isJSONLD = node.localName === "script"
                  && scriptMediaType === "application/ld+json";
                if (!isJSONLD) node.remove();
              });
              if (transportRoot) {
                const comments = [];
                const walker = document.createTreeWalker(transportRoot, NodeFilter.SHOW_COMMENT);
                while (walker.nextNode()) comments.push(walker.currentNode);
                comments.forEach((comment) => comment.remove());
              }
              serializedHTML = transportRoot?.outerHTML ?? "";
              htmlByteCount = new TextEncoder().encode(serializedHTML).byteLength;
              const transportLimit = Number(maximumHTMLBytes);
              oversized = !Number.isSafeInteger(transportLimit)
                || transportLimit <= 0
                || htmlByteCount > transportLimit;
            }

            return JSON.stringify({
              payloadKind: shouldSerializeHTML ? "renderedDocument" : "readinessProbe",
              html: oversized ? "" : serializedHTML,
              htmlByteCount,
              oversized,
              resolvedURL,
              title,
              readyState: document.readyState,
              challenged: bodyText.length < 1200
                && !hasSubstantiveEditorialContent
                && (challengeTitle
                  || browserChallengePhrase
                  || challengeSelector
                  || interactiveChallengePhrase),
              textCharacterCount: bodyText.length,
              substantiveProseCharacterCount,
              stabilityFingerprint: (fingerprint >>> 0).toString(16).padStart(8, "0")
            });
            """#
    )
}

enum RenderedDocumentReadyState: String, Decodable, Equatable, Sendable {
    case loading
    case interactive
    case complete

    var isReadyForInspection: Bool {
        self != .loading
    }
}

/// A rendered browser document before article selection or narration projection.
struct RenderedPageSnapshot: Equatable, Sendable {
    let sourceURL: URL
    let resolvedURL: URL
    let title: String
    let html: String
    let readyState: RenderedDocumentReadyState
    let challenged: Bool
    let textCharacterCount: Int
    let substantiveProseCharacterCount: Int
    let stabilityFingerprint: String

    var ready: Bool {
        readyState.isReadyForInspection
    }

    var readinessProbe: RenderedPageReadinessProbe {
        RenderedPageReadinessProbe(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: title,
            readyState: readyState,
            challenged: challenged,
            textCharacterCount: textCharacterCount,
            substantiveProseCharacterCount: substantiveProseCharacterCount,
            stabilityFingerprint: stabilityFingerprint
        )
    }
}

/// Lightweight browser state used only to decide when the DOM has settled.
struct RenderedPageReadinessProbe: Equatable, Sendable {
    let sourceURL: URL
    let resolvedURL: URL
    let title: String
    let readyState: RenderedDocumentReadyState
    let challenged: Bool
    let textCharacterCount: Int
    let substantiveProseCharacterCount: Int
    let stabilityFingerprint: String

    var ready: Bool {
        readyState.isReadyForInspection
    }
}

enum RenderedPageBridgePayloadKind: String, Decodable, Sendable {
    case readinessProbe
    case renderedDocument
}

struct RenderedPageBridgePayload: Decodable, Sendable {
    let payloadKind: RenderedPageBridgePayloadKind
    let html: String
    let htmlByteCount: Int
    let oversized: Bool
    let resolvedURL: String
    let title: String
    let readyState: RenderedDocumentReadyState
    let challenged: Bool
    let textCharacterCount: Int
    let substantiveProseCharacterCount: Int
    let stabilityFingerprint: String
}
