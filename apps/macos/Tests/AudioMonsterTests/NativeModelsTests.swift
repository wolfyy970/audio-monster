import Foundation
import Testing

@testable import AudioMonster

struct NativeModelsTests {
    @Test
    func exposesAllKokoroVoicesWithNativeLanguageMetadata() {
        #expect(KokoroVoiceCatalog.voices.count == 54)
        #expect(KokoroVoiceCatalog.voices.map(\.id).contains("af_heart"))
        #expect(KokoroVoiceCatalog.voices.map(\.id).contains("jf_alpha"))
        #expect(KokoroVoiceCatalog.voices.map(\.id).contains("zf_xiaobei"))
        #expect(KokoroVoiceCatalog.language(for: "af_heart") == .americanEnglish)
        #expect(KokoroVoiceCatalog.language(for: "jf_alpha") == .japanese)
        #expect(KokoroVoiceCatalog.language(for: "zf_xiaobei") == .mandarinChinese)
        #expect(KokoroLanguage.americanEnglish.synthesisCode == "en-us")
        #expect(KokoroLanguage.japanese.synthesisCode == "ja")
        #expect(KokoroLanguage.mandarinChinese.synthesisCode == "cmn")
        #expect(KokoroVoiceCatalog.voices.filter(\.isDefault).map(\.id) == ["af_heart"])
    }

    @Test
    func ordersVoiceCatalogByGenderThenLanguageThenName() {
        let voices = [
            Voice(
                id: "ff_zoe", name: "Zoe", language: .french,
                gender: .female, isDefault: false
            ),
            Voice(
                id: "am_zed", name: "Zed", language: .americanEnglish,
                gender: .male, isDefault: false
            ),
            Voice(
                id: "af_bella", name: "Bella", language: .americanEnglish,
                gender: .female, isDefault: false
            ),
            Voice(
                id: "am_adam", name: "Adam", language: .americanEnglish,
                gender: .male, isDefault: true
            ),
            Voice(
                id: "fm_pierre", name: "Pierre", language: .french,
                gender: .male, isDefault: false
            ),
        ]

        let sections = VoiceCatalogOrdering.sections(
            for: voices,
            preferredLanguageCode: "en-GB"
        )

        #expect(sections.map(\.gender) == [.male, .female])
        #expect(sections[0].languages.map(\.languageCode) == ["en-US", "fr-FR"])
        #expect(sections[0].languages[0].voices.map(\.name) == ["Adam", "Zed"])
        #expect(sections[1].languages.flatMap(\.voices).map(\.name) == ["Bella", "Zoe"])
    }

}
