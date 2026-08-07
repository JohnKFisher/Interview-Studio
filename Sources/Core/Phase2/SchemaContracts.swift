import Foundation

public enum InterviewStudioSchema {
    public static let major = 1
    public static let minor = 0
    public static let minimumReaderVersion = "0.2.0"
    public static let project = "interview_studio_project"
    public static let session = "interview_studio_session"
    public static let publication = "publication_record"
    public static let inventory = "package_inventory"
}

public enum InterviewStudioFeature {
    public static let questionThenYears = "question_then_years"
    public static let generatedTextCard = "generated_text_card"
    public static let nativeSessionV1 = "native_session_v1"
    public static let multipartAnswerV1 = "multipart_answer_v1"
    public static let transcriptV1 = "transcript_v1"
}

public struct SchemaDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var major: Int
    public var minor: Int
    public var minimumReaderVersion: String
    public var requiredFeatures: [String]
    public var optionalFeatures: [String]
    public var extensions: [String: JSONValue]

    public init(
        name: String,
        major: Int = InterviewStudioSchema.major,
        minor: Int = InterviewStudioSchema.minor,
        minimumReaderVersion: String = InterviewStudioSchema.minimumReaderVersion,
        requiredFeatures: [String] = [],
        optionalFeatures: [String] = [],
        extensions: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.major = major
        self.minor = minor
        self.minimumReaderVersion = minimumReaderVersion
        self.requiredFeatures = requiredFeatures
        self.optionalFeatures = optionalFeatures
        self.extensions = extensions
    }

    public var isCurrent: Bool {
        major == InterviewStudioSchema.major && minor <= InterviewStudioSchema.minor
    }

    public func compatibility(knownOptionalFeatures: Set<String> = []) -> SchemaCompatibility {
        if major > InterviewStudioSchema.major {
            return .readOnly("Schema major version \(major) is newer than this reader supports.")
        }
        if major < InterviewStudioSchema.major {
            return .upgradeRequired("Schema major version \(major) is older than the supported version and requires migration.")
        }
        let unknownRequired = requiredFeatures.filter { !knownOptionalFeatures.contains($0) && !InterviewStudioKnownFeatures.contains($0) }
        if !unknownRequired.isEmpty {
            return .readOnly("Required features are not supported: \(unknownRequired.joined(separator: ", ")).")
        }
        return .writable
    }
}

public enum SchemaCompatibility: Codable, Hashable, Sendable {
    case writable
    case readOnly(String)
    case upgradeRequired(String)

    public var isWritable: Bool {
        if case .writable = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .writable: return nil
        case .readOnly(let message), .upgradeRequired(let message): return message
        }
    }
}

private let InterviewStudioKnownFeatures: Set<String> = [
    InterviewStudioFeature.questionThenYears,
    InterviewStudioFeature.generatedTextCard,
    InterviewStudioFeature.nativeSessionV1,
    InterviewStudioFeature.multipartAnswerV1,
    InterviewStudioFeature.transcriptV1
]

public enum InterviewStudioCompatibilityError: LocalizedError, Sendable {
    case readOnly(String)
    case upgradeRequired(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let message), .upgradeRequired(let message), .invalid(let message): return message
        }
    }
}

public struct MediaTime: Codable, Hashable, Sendable, Comparable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = max(timescale, 1)
    }

    public static let zero = MediaTime(value: 0, timescale: 1_000_000)

    public var microseconds: Int64 {
        let numerator = value.multipliedReportingOverflow(by: 1_000_000)
        guard !numerator.overflow else { return value >= 0 ? Int64.max : Int64.min }
        return numerator.partialValue / Int64(timescale)
    }

    public static func microseconds(_ value: Int64) -> MediaTime {
        MediaTime(value: value, timescale: 1_000_000)
    }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        lhs.microseconds < rhs.microseconds
    }
}

public struct CapabilityDeclarations: Codable, Hashable, Sendable {
    public var required: [String]
    public var optional: [String]
    public var extensions: [String: JSONValue]

    public init(required: [String] = [], optional: [String] = [], extensions: [String: JSONValue] = [:]) {
        self.required = required
        self.optional = optional
        self.extensions = extensions
    }
}

public enum InterviewStudioKey {
    public static func readableKey(from text: String, existing: Set<String> = []) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let words = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(String(scalar).lowercased()) }
            return "_"
        }
        var key = String(words)
            .split(separator: "_")
            .joined(separator: "_")
        if key.isEmpty { key = "question" }
        if key.first?.isNumber == true { key = "question_\(key)" }
        guard existing.contains(key) else { return key }
        var suffix = 2
        while existing.contains("\(key)_\(suffix)") { suffix += 1 }
        return "\(key)_\(suffix)"
    }

    public static func safeFilenameComponent(_ value: String, fallback: String = "item") -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }
}
