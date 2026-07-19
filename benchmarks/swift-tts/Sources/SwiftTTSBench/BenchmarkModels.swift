import Foundation

struct BenchmarkModel: Codable, Sendable {
    let key: String
    let repository: String
    let modelType: String
    let voice: String?
    let language: String?
    let role: String
}

enum BenchmarkCatalog {
    static let models: [BenchmarkModel] = [
        BenchmarkModel(
            key: "kokoro",
            repository: "mlx-community/Kokoro-82M-bf16",
            modelType: "kokoro",
            voice: "am_michael",
            language: "en-us",
            role: "Primary candidate: 82M parameters and 54 voices"
        ),
        BenchmarkModel(
            key: "pocket",
            repository: "mlx-community/pocket-tts",
            modelType: "pocket_tts",
            voice: "marius",
            language: nil,
            role: "Compact candidate with eight built-in voices"
        ),
        BenchmarkModel(
            key: "marvis",
            repository: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit",
            modelType: "csm",
            voice: "conversational_a",
            language: "English",
            role: "250M 8-bit candidate with two English voices"
        ),
        BenchmarkModel(
            key: "qwen-0.6b",
            repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
            modelType: "qwen3_tts",
            voice: "Ryan",
            language: "English",
            role: "Larger 8-bit quality candidate with voice cloning support"
        ),
        BenchmarkModel(
            key: "soprano-baseline",
            repository: "mlx-community/Soprano-80M-bf16",
            modelType: "soprano",
            voice: nil,
            language: nil,
            role: "Speed baseline only; excluded as the product model"
        ),
    ]

    static func model(for key: String) -> BenchmarkModel? {
        models.first { $0.key == key }
    }
}
