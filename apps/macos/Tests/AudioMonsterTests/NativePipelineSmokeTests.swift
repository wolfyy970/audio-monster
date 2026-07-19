@preconcurrency import AVFoundation
import AudioMonsterCore
import Darwin
import Foundation
import Testing

@testable import AudioMonster

@MainActor
private final class SmokeRenderedPageRenderer: RenderedPageRendering {
    private let snapshot: RenderedPageSnapshot

    init(snapshot: RenderedPageSnapshot) {
        self.snapshot = snapshot
    }

    func render(url _: URL) async throws -> RenderedPageSnapshot {
        snapshot
    }
}

private actor DeterministicSmokeKokoroModel: KokoroSampleGenerating {
    nonisolated let sampleRate = 24_000
    private var requestedTexts: [String] = []

    func generateSamples(
        text: String,
        voiceID _: String,
        language _: String?
    ) async throws -> [Float] {
        requestedTexts.append(text)
        let frameCount = 8_000
        return (0..<frameCount).map { frame in
            0.12 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
        }
    }

    func requests() -> [String] {
        requestedTexts
    }
}

private struct DeterministicSmokeKokoroLoader: KokoroModelLoading {
    let model: DeterministicSmokeKokoroModel

    func loadModel() async throws -> any KokoroSampleGenerating {
        model
    }
}

/// A hermetic release-path smoke test. The network renderer and neural inference
/// are replaced with fixed inputs; native Readability and every downstream audio,
/// metadata, persistence, and discovery component use their production implementations.
@MainActor
struct NativePipelineSmokeTests {
    @Test
    func renderedArticleBecomesPersistedPlayableM4AWithoutNetworkOrModelAccess() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AudioMonster-native-smoke-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let libraryFolder = root.appendingPathComponent("library", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = try #require(URL(string: "https://example.com/submitted-article"))
        let resolvedURL = try #require(
            URL(string: "https://publisher.example/articles/native-pipeline-smoke")
        )
        let html = """
            <!doctype html>
            <html lang="en">
              <head><title>Native Pipeline Smoke</title></head>
              <body>
                <nav>This publisher navigation must not be narrated.</nav>
                <article>
                  <h1>Native Pipeline Smoke</h1>
                  <p>The first editorial paragraph is extracted by native Swift Readability.</p>
                  <p>The second paragraph preserves a separate narration boundary.</p>
                </article>
              </body>
            </html>
            """
        let snapshot = RenderedPageSnapshot(
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            title: "Native Pipeline Smoke",
            html: html,
            readyState: .complete,
            challenged: false,
            textCharacterCount: html.utf16.count,
            substantiveProseCharacterCount: 142,
            stabilityFingerprint: "native-pipeline-smoke"
        )
        let extractor = NativeArticleExtractor(
            renderer: SmokeRenderedPageRenderer(snapshot: snapshot),
            parser: SwiftReadabilityArticleParser(characterThreshold: 1)
        )

        let article = try await extractor.extract(url: sourceURL)

        #expect(article.sourceURL == sourceURL)
        #expect(article.resolvedURL == resolvedURL)
        #expect(article.title == "Native Pipeline Smoke")
        #expect(article.text.contains("The first editorial paragraph"))
        #expect(article.text.contains("\n\nThe second paragraph"))
        #expect(!article.text.contains("publisher navigation"))

        let deterministicModel = DeterministicSmokeKokoroModel()
        let engine = NativeKokoroAudioEngine(
            modelLoader: DeterministicSmokeKokoroLoader(model: deterministicModel),
            artifactEncoder: NativeAudioArtifactEncoder()
        )
        let synthesis = try await engine.convert(
            article: article,
            voiceID: "af_heart",
            workspaceURL: workspace
        ) { _ in }

        let requestedTexts = await deterministicModel.requests()
        #expect(!requestedTexts.isEmpty)
        #expect(synthesis.audioURL.pathExtension == "m4a")
        #expect(fileManager.fileExists(atPath: synthesis.audioURL.path))

        let persistedURL = try AudioFileStore.persist(
            from: synthesis.audioURL,
            in: libraryFolder,
            requestedName: synthesis.recommendedFilename,
            sourceURL: article.sourceURL,
            locationKind: .localFallback
        )
        let libraryItems = try AudioLibrary.scan(folderURL: libraryFolder)

        #expect(libraryItems.count == 1)
        #expect(libraryItems.first?.url.resolvingSymlinksInPath() == persistedURL.resolvingSymlinksInPath())
        #expect(libraryItems.first?.url.pathExtension.lowercased() == "m4a")

        let bytes = try Data(contentsOf: persistedURL)
        #expect(bytes.count > 8)
        #expect(String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp")

        let asset = AVURLAsset(url: persistedURL)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 0.5)
        #expect(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty)

        let metadata = try await asset.load(.metadata)
        let titleItem = metadata.first { $0.identifier == .iTunesMetadataSongName }
        let sourceItem = metadata.first { $0.identifier == .iTunesMetadataUserComment }
        #expect(try await titleItem?.load(.stringValue) == article.title)
        #expect(try await sourceItem?.load(.stringValue) == sourceURL.absoluteString)
        #expect(try whereFromValues(on: persistedURL) == [sourceURL.absoluteString])
    }

    private func whereFromValues(on url: URL) throws -> [String]? {
        let attributeName = "com.apple.metadata:kMDItemWhereFroms"
        let size: Int = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return attributeName.withCString { getxattr(path, $0, nil, 0, 0, 0) }
        }
        if size < 0, errno == ENOATTR { return nil }
        guard size >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var data = Data(count: size)
        let readCount: Int = data.withUnsafeMutableBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return attributeName.withCString {
                    getxattr(path, $0, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard readCount == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String]
        )
    }
}
