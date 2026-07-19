import Foundation

struct BrowserExtractionScripts: Sendable {
    let readabilitySource: String
    let snapshotSource: String

    enum AssetError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let filename):
                "The bundled article extraction resource \(filename) is missing."
            }
        }
    }

    static func bundled() throws -> BrowserExtractionScripts {
        BrowserExtractionScripts(
            readabilitySource: try MozillaReadabilityAsset.source(),
            snapshotSource: try extractionResource(named: "Snapshot", extension: "js")
        )
    }

    private static func extractionResource(
        named name: String,
        extension fileExtension: String
    ) throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Extraction"
            )
        else {
            throw AssetError.missing("\(name).\(fileExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
