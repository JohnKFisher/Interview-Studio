import Foundation

public enum ManifestParserError: LocalizedError {
    case invalidJSON(String)
    case topLevelNotArray
    case noUsableClips

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return message
        case .topLevelNotArray:
            return "The manifest must decode to an array of clip rows."
        case .noUsableClips:
            return "No usable clips were found in the manifest."
        }
    }
}

public struct ManifestParser {
    public init() {}

    public func parse(url: URL) throws -> [ManifestRow] {
        let data = try Data(contentsOf: url)
        do {
            let raw = try JSONSerialization.jsonObject(with: data)
            guard raw is [Any] else {
                throw ManifestParserError.topLevelNotArray
            }
        } catch {
            throw ManifestParserError.invalidJSON("The manifest is not valid JSON: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode([ManifestRow].self, from: data)
        } catch {
            throw ManifestParserError.invalidJSON("The manifest could not be decoded into typed rows: \(error)")
        }
    }
}
