# Article extraction decision

Updated: 2026-07-20

## Decision

Audio Monster uses native SwiftReadability for article selection, cleanup, and
metadata, followed by a native narration-text projector. Apple WebKit remains
only as a rendered-page adapter: it loads the submitted URL, lets client-side
content hydrate, and serializes the live DOM with a small compiled-in bridge.
The application ships no Mozilla `Readability.js`, `Snapshot.js`, JavaScript
package, Python process, Node runtime, localhost server, or remote extraction
service.

## Behavioral authority and provenance

[Mozilla Readability](https://github.com/mozilla/readability) commit
[`ab4027a8b37669745016869a37a504727992b2ba`](https://github.com/mozilla/readability/commit/ab4027a8b37669745016869a37a504727992b2ba)
is the behavioral specification. The official `Readability.js` and
`Readability-readerable.js` files are held in an optional test-only package
product, protected by fixed SHA-256 values, and used as a result-level oracle.
They are not linked into Audio Monster.

The native package began as a fork of
[lake-of-fire/swift-readability](https://github.com/lake-of-fire/swift-readability),
whose history and BSD attribution are preserved. It established the native
Swift foundation; default compatibility is evaluated against the pinned Mozilla
reference, while deliberately different behavior is isolated behind explicit
extensions.

Audio Monster owns its recovery policy for publisher chrome, carousels,
significant media, article bodies, and ruby markup. The application composes
those granular `ReadabilityExtensions` flags at its native parser boundary;
SwiftReadability provides no client-specific preset. The package's default
extension set is empty and is the only mode compared with Mozilla, preventing
consumer policy from silently changing the meaning of compatibility.

## Evidence and release gates

- Default Swift matches official Mozilla across 136/136 inputs and every
  observable field: parse state, readerability, title and metadata, exact
  browser-serialized content, raw text, and JavaScript-compatible UTF-16
  length. Canonical DOM comparison remains an additional diagnostic.
- The package fixture and differential harnesses fail closed on missing or
  malformed manifests, invalid filters, missing sources, zero selected cases,
  parse errors, and modified oracle files.
- Focused tests cover supplementary Unicode, repeated sessions, retries,
  timed/untimed equivalence, DOM comparison semantics, CJK title tokenization,
  carousel false positives, publisher cleanup false positives, and every
  explicit extension gate.
- Audio Monster adds hermetic integration tests for WebKit hydration, malformed
  bridge payloads, challenge detection and false positives, URL provenance,
  difficult non-semantic layouts, consent and navigation pollution, lists,
  quotations, CJK/ruby, hidden content, narration boundaries, concurrency, and
  cancellation.
- SwiftSoup is pinned exactly to 2.13.6, and Audio Monster pins SwiftReadability
  by immutable revision. Release tooling rejects any dependency drift or legacy
  JavaScript extraction payload.

## Why WebKit remains

Static HTTP alone misses articles assembled by client JavaScript and pages that
depend on browser navigation state. Apple exposes no general Swift API that
returns Safari Reader content or serializes a live `WKWebView` DOM. The minimal
bridge therefore polls with typed, HTML-free readiness data: challenge, URL,
title, total-text, prose-shaped-text, and compact stability signals. Once those
signals settle, it serializes exactly one rendered-DOM clone. Before applying its
transport limit it removes only non-JSON-LD scripts, style elements, and comments
while preserving JSON-LD, `noscript` image fallbacks, metadata, attributes, and
content. It performs no article scoring and contains no extraction library; the
prose-shaped count only prevents a stable navigation or consent shell from being
mistaken for a fully hydrated page.

The native parser runs off the main actor against that immutable HTML string.
Extracted HTML is never displayed; only the native projector's plain narration
text reaches speech synthesis. This preserves rendered-page capability without
making JavaScript a content-selection runtime.

## Alternatives considered

- [Defuddle](https://github.com/kepano/defuddle) is a thoughtful modern
  JavaScript extractor, but adopting it would reintroduce the runtime being
  removed and would require an equally rigorous corpus before replacing the
  existing Mozilla contract.
- [Trafilatura](https://github.com/adbar/trafilatura) is an excellent Python
  reference implementation, not an appropriate native-app dependency.
- Safari Services can present browser UI but does not expose a general article
  extraction API.
- A simple `article`/`main` selector fails on ordinary div-heavy publishers and
  cannot replace scoring, link-density analysis, sibling inclusion, conditional
  cleanup, and relaxed retries.

Future changes must add a failing fixture first, preserve the complete default
Mozilla differential, and keep any non-Mozilla behavior explicit. Performance
claims are secondary to those correctness gates and must use fresh parser
sessions with checked, deterministic output.
