import Foundation

enum KokoroLanguage: String, CaseIterable, Hashable, Sendable {
    case americanEnglish = "a"
    case britishEnglish = "b"
    case spanish = "e"
    case french = "f"
    case hindi = "h"
    case italian = "i"
    case japanese = "j"
    case brazilianPortuguese = "p"
    case mandarinChinese = "z"

    var displayName: String {
        switch self {
        case .americanEnglish: "American English"
        case .britishEnglish: "British English"
        case .spanish: "Spanish"
        case .french: "French"
        case .hindi: "Hindi"
        case .italian: "Italian"
        case .japanese: "Japanese"
        case .brazilianPortuguese: "Brazilian Portuguese"
        case .mandarinChinese: "Mandarin Chinese"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .americanEnglish: "en-US"
        case .britishEnglish: "en-GB"
        case .spanish: "es-ES"
        case .french: "fr-FR"
        case .hindi: "hi-IN"
        case .italian: "it-IT"
        case .japanese: "ja-JP"
        case .brazilianPortuguese: "pt-BR"
        case .mandarinChinese: "zh-CN"
        }
    }

    var synthesisCode: String {
        switch self {
        case .americanEnglish: "en-us"
        case .britishEnglish: "en-gb"
        case .spanish: "es"
        case .french: "fr"
        case .hindi: "hi"
        case .italian: "it"
        case .japanese: "ja"
        case .brazilianPortuguese: "pt"
        case .mandarinChinese: "cmn"
        }
    }
}

enum VoiceGender: String, Hashable, Sendable {
    case male
    case female

    var displayName: String { rawValue.capitalized }

    var group: VoiceGenderGroup {
        switch self {
        case .male: .male
        case .female: .female
        }
    }
}

struct Voice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: KokoroLanguage
    let gender: VoiceGender
    let isDefault: Bool

    var genderGroup: VoiceGenderGroup { gender.group }
}

enum KokoroVoiceCatalog {
    static let defaultVoiceID = "af_heart"

    // These are the voice weights shipped by mlx-community/Kokoro-82M-bf16.
    static let voiceIDs = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        "ef_dora", "em_alex", "em_santa", "ff_siwis",
        "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        "if_sara", "im_nicola",
        "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo",
        "pf_dora", "pm_alex", "pm_santa",
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    static let voices: [Voice] = voiceIDs.compactMap { voiceID in
        guard voiceID.count >= 2,
            let languageKey = voiceID.first,
            let language = KokoroLanguage(rawValue: String(languageKey))
        else { return nil }
        let genderIndex = voiceID.index(after: voiceID.startIndex)
        let gender: VoiceGender = voiceID[genderIndex] == "f" ? .female : .male
        let rawName = voiceID.split(separator: "_", maxSplits: 1).last.map(String.init) ?? voiceID
        return Voice(
            id: voiceID,
            name: rawName.replacingOccurrences(of: "_", with: " ").capitalized,
            language: language,
            gender: gender,
            isDefault: voiceID == defaultVoiceID
        )
    }

    static func language(for voiceID: String) -> KokoroLanguage? {
        voiceID.first.flatMap { KokoroLanguage(rawValue: String($0)) }
    }
}

enum VoiceGenderGroup: Int, CaseIterable, Identifiable, Sendable {
    case male
    case female

    var id: Self { self }

    var title: String {
        switch self {
        case .male: "Male voices"
        case .female: "Female voices"
        }
    }

}

struct VoiceLanguageSection: Identifiable {
    let language: String
    let languageCode: String
    let voices: [Voice]

    var id: String { languageCode }
}

struct VoiceGenderSection: Identifiable {
    let gender: VoiceGenderGroup
    let languages: [VoiceLanguageSection]

    var id: VoiceGenderGroup { gender }
    var voiceCount: Int { languages.reduce(0) { $0 + $1.voices.count } }
}

enum VoiceCatalogOrdering {
    static func sections(
        for voices: [Voice],
        preferredLanguageCode: String = Locale.current.language.languageCode?.identifier ?? "en"
    ) -> [VoiceGenderSection] {
        let preferredLanguage = baseLanguageCode(preferredLanguageCode)
        let voicesByGender = Dictionary(grouping: voices, by: \.genderGroup)

        return VoiceGenderGroup.allCases.compactMap { gender in
            guard let genderVoices = voicesByGender[gender], !genderVoices.isEmpty else {
                return nil
            }
            let languageGroups = Dictionary(grouping: genderVoices, by: \.language)
            let languages = languageGroups.map { language, languageVoices in
                VoiceLanguageSection(
                    language: language.displayName,
                    languageCode: language.localeIdentifier,
                    voices: languageVoices.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }.sorted { lhs, rhs in
                let lhsPreferred = baseLanguageCode(lhs.languageCode) == preferredLanguage
                let rhsPreferred = baseLanguageCode(rhs.languageCode) == preferredLanguage
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                return lhs.language.localizedStandardCompare(rhs.language) == .orderedAscending
            }
            return VoiceGenderSection(gender: gender, languages: languages)
        }
    }

    private static func baseLanguageCode(_ code: String) -> String {
        code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
    }
}

enum VoicePreviewStatus: String, Sendable {
    case pending
    case generating
    case ready
    case failed
}

struct VoicePreview: Identifiable, Equatable, Sendable {
    let voiceID: String
    let status: VoicePreviewStatus
    let audioURL: URL?
    let durationSeconds: Double?

    var id: String { voiceID }
}

struct AudioSegment: Identifiable, Equatable, Sendable {
    let index: Int
    let url: URL

    var id: Int { index }
}

enum ConversionStatus: String, Sendable {
    case extracting
    case synthesizing
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .extracting, .synthesizing: false
        }
    }

    var label: String {
        switch self {
        case .extracting: "Reading page"
        case .synthesizing: "Creating audio"
        case .completed: "Ready"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct ConversionJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var status: ConversionStatus
    var title: String?
    var recommendedFilename: String?
    var progress: Double
    var message: String?
    var audioURL: URL?
    var segments: [AudioSegment]

    var segmentsReady: Int { segments.count }
}

struct SynthesisResult: Sendable {
    let audioURL: URL
    let recommendedFilename: String
}

enum SynthesisEvent: Sendable {
    case started(sectionCount: Int)
    case segment(AudioSegment, completed: Int, total: Int)
    case encoding
}
