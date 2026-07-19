import Testing

@testable import AudioMonster

@Suite("Native narration text projection")
struct NarrationTextProjectorTests {
    private let projector = NarrationTextProjector()

    @Test("Preserves speech boundaries for structural HTML")
    func preservesStructuralBoundaries() throws {
        let text = try projector.project(
            html: """
                <article>
                  <h1>A narrated heading</h1>
                  <p>The first <em>paragraph</em> stays together.<br>The line after a break pauses.</p>
                  <pre>A compact preformatted example</pre>
                  <p>The final paragraph follows.</p>
                </article>
                """)

        #expect(
            text == """
                A narrated heading

                The first paragraph stays together.

                The line after a break pauses.

                A compact preformatted example

                The final paragraph follows.
                """)
    }

    @Test("Normalizes inline whitespace without separating punctuation")
    func normalizesInlineSpacing() throws {
        let text = try projector.project(
            html: """
                <p>Audio&nbsp;<em>Monster</em> turns
                  <strong>rendered text</strong> into <span>clear audio</span>.</p>
                """)

        #expect(text == "Audio Monster turns rendered text into clear audio.")
    }

    @Test("Keeps list order and quotations as distinct narration units")
    func preservesListsAndQuotations() throws {
        let text = try projector.project(
            html: """
                <p>Follow these steps.</p>
                <ol>
                  <li>Extract the article.</li>
                  <li>Preserve its structure.</li>
                  <li>Narrate the result.</li>
                </ol>
                <blockquote>
                  <p>The listener should hear the argument.</p>
                  <p>Website furniture should stay silent.</p>
                </blockquote>
                """)

        #expect(
            text.components(separatedBy: "\n\n") == [
                "Follow these steps.",
                "Extract the article.",
                "Preserve its structure.",
                "Narrate the result.",
                "The listener should hear the argument.",
                "Website furniture should stay silent.",
            ])
    }

    @Test("Narrates CJK base text once and omits ruby pronunciation hints")
    func handlesCJKAndRubyWithoutDuplication() throws {
        let text = try projector.project(
            html: """
                <p><ruby><rb>東京</rb><rp>(</rp><rt>とうきょう</rt><rp>)</rp></ruby>で<span>音声</span>を聞く。</p>
                <p>短い引用も消してはいけません。</p>
                """)

        #expect(text == "東京で音声を聞く。\n\n短い引用も消してはいけません。")
        #expect(!text.contains("とう"))
        #expect(!text.contains("きょう"))
    }

    @Test("Excludes hidden content, controls, and modal dialogs")
    func excludesNonSpokenContent() throws {
        let text = try projector.project(
            html: """
                <header><h1>The visible article heading</h1></header>
                <p aria-hidden="TRUE">An icon label that must not be spoken.</p>
                <p hidden>Hidden fallback copy.</p>
                <p style="DISPLAY : none">Invisible style copy.</p>
                <div role="dialog">Accept every cookie.</div>
                <form><label>Email address</label><button>Continue</button></form>
                <p style="--fallback-display: none; display: block">A custom CSS property must not create a false positive.</p>
                <p>The actual article remains audible.</p>
                """)

        #expect(
            text == """
                The visible article heading

                A custom CSS property must not create a false positive.

                The actual article remains audible.
                """)
    }

    @Test("Preserves a selected table of contents, aside, and corrections footer")
    func preservesSelectedSemanticArticleContent() throws {
        let text = try projector.project(
            html: """
                <nav role="navigation">In this article: context, evidence, and conclusion.</nav>
                <p>The selected article body remains audible.</p>
                <aside role="complementary">A supporting editorial note adds useful context.</aside>
                <footer role="contentinfo">Correction: the original date has been updated.</footer>
                """)

        #expect(
            text.components(separatedBy: "\n\n") == [
                "In this article: context, evidence, and conclusion.",
                "The selected article body remains audible.",
                "A supporting editorial note adds useful context.",
                "Correction: the original date has been updated.",
            ])
    }

    @Test("Empty markup has no narration")
    func emptyMarkupProducesEmptyText() throws {
        #expect(try projector.project(html: "") == "")
        #expect(try projector.project(html: "  \n\t ") == "")
        #expect(try projector.project(html: "<script>ignored()</script>") == "")
    }

    @Test("Projection is deterministic across repeated runs")
    func isDeterministic() throws {
        let html = """
            <article><h2>Stable output</h2><p>One <em>complete</em> thought.</p>
            <ul><li>First item</li><li>Second item</li></ul></article>
            """
        let expected = try projector.project(html: html)

        for _ in 0..<50 {
            #expect(try projector.project(html: html) == expected)
        }
    }
}
