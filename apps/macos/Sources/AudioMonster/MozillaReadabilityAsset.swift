import Foundation

enum MozillaReadabilityAsset {
    static let version = "0.6.0"
    static let sourceSHA256 =
        "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174"

    enum AssetError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let filename):
                "The bundled article reader resource \(filename) is missing."
            }
        }
    }

    static func source() throws -> String {
        try string(named: "Readability", extension: "js")
    }

    static func license() throws -> String {
        try string(named: "LICENSE", extension: "md")
    }

    static func upstreamMetadata() throws -> String {
        try string(named: "UPSTREAM", extension: "md")
    }

    private static func string(named name: String, extension fileExtension: String) throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Readability"
            )
        else {
            throw AssetError.missing("\(name).\(fileExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
