# Article extraction decision

Research date: 2026-07-18

## Decision

Audio Monster will keep its pinned, vendored Mozilla Readability algorithm running
locally against the rendered page in Apple WebKit. This is a native macOS deployment:
the app launches no Python or Node runtime, subprocess, localhost server, or remote
extraction service. JavaScript is used only as the content-selection algorithm inside
the system browser engine.

The current implementation is stronger than the available Swift packages because it
waits for client-rendered content, executes Readability against a cloned live DOM in
an isolated `WKContentWorld`, bounds the work, requires stable readable snapshots, and
keeps a semantic fallback. It returns normalized plain text; extracted HTML is never
rendered.

## Evidence

- [Mozilla Readability](https://github.com/mozilla/readability) is the Apache-2.0
  algorithm used by Firefox Reader View. It has a large fixture corpus and exposes
  article text and metadata from a DOM document.
- [Bevendorff et al., SIGIR 2023](https://downloads.webis.de/publications/papers/bevendorff_2023c.pdf)
  evaluated 14 extractors across 3,985 labeled pages. Trafilatura had the highest
  macro-mean F1 (0.883); Readability was close (0.861), had the highest median
  (0.970), the lowest spread, and was the paper's best overall recommendation. The
  corpus age makes an Audio Monster-specific modern corpus important.
- [Defuddle](https://github.com/kepano/defuddle) is the strongest modern challenger.
  It is MIT-licensed and adds useful handling for visibility, structured metadata,
  footnotes, code, math, and diagnostic removal reasons, but its own documentation
  still calls it a work in progress and there is no comparable independent benchmark.
- [SwiftSoup](https://github.com/scinfu/SwiftSoup) is an active, MIT-licensed,
  pure-Swift HTML DOM parser. It does not identify an article on its own, so adopting
  it today would mean inventing and maintaining the difficult scoring algorithm.
- [Ryu0118/swift-readability](https://github.com/Ryu0118/swift-readability) is a
  SwiftPM interface around Mozilla's JavaScript rather than a pure-Swift extraction
  algorithm. Its static-fetch path is less capable than Audio Monster's rendered-DOM
  integration.
- [Readability.rs](https://github.com/theiskaa/readabilityrs) is a useful example of
  how to port responsibly: it publishes compatibility against Mozilla's fixtures.
  Rust FFI does not advance the desired Swift-native architecture.
- [Trafilatura](https://github.com/adbar/trafilatura) is an excellent Python reference
  oracle, not an appropriate desktop dependency. Its broad lxml/XPath and language
  stack would be expensive to reproduce or bundle.

Apple provides WebKit rendering and isolated script execution, and Safari Services
can present Reader mode, but Apple exposes no general API that returns Safari's
selected article text. A pure-Swift content selector would still need WebKit on Apple
clients for hydrated and browser-protected pages.

## Benchmark before changing the default

Any replacement must beat the current extractor on frozen rendered-DOM fixtures, not
live URLs. The corpus should cover recent news, essays, blogs, documentation, consent
and paywall furniture, lazy/client rendering, lists, quotes, code, and non-English
content. Measure token precision/recall/F1, title and language accuracy, block order,
duplicates, and speech pollution. Defuddle can be a development-only comparator;
it should not become a shipped second runtime until the corpus proves a material win.

## Pure-Swift path

If a pure-Swift selector becomes a priority, it should be a separate open-source
SwiftPM package built on SwiftSoup with an Apache-2.0-compatible license. Port
Readability incrementally—metadata, normalization, candidate scoring, link density,
sibling inclusion, conditional cleanup, and relaxed retries—and require Mozilla
fixture parity at every stage. Keep Audio Monster's `ArticleExtracting` protocol so
the production WebKit adapter and a future shared Swift core remain interchangeable.
