import Foundation

public enum ManifestParserConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

public struct ManifestVideoSignature: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var codecName: String?
        public var pixFmt: String?
        public var colorRange: String?
        public var colorSpace: String?
        public var colorTransfer: String?
        public var colorPrimaries: String?
        public var sideDataTypes: [String]

        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case pixFmt = "pix_fmt"
            case colorRange = "color_range"
            case colorSpace = "color_space"
            case colorTransfer = "color_transfer"
            case colorPrimaries = "color_primaries"
            case sideDataTypes = "side_data_types"
        }
    }

    public var entries: [Entry]

    public var codecName: String? { entries.first?.codecName }
    public var pixFmt: String? { entries.first?.pixFmt }
    public var colorRange: String? { entries.first?.colorRange }
    public var colorSpace: String? { entries.first?.colorSpace }
    public var colorTransfer: String? { entries.first?.colorTransfer }
    public var colorPrimaries: String? { entries.first?.colorPrimaries }
    public var sideDataTypes: [String] { entries.first?.sideDataTypes ?? [] }

    public var isHDRLike: Bool {
        let transfer = (colorTransfer ?? "").lowercased()
        let primaries = (colorPrimaries ?? "").lowercased()
        return transfer.contains("hlg") || transfer.contains("2084") || transfer.contains("pq") || primaries.contains("2020")
    }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let entry = try? single.decode(Entry.self) {
            self.entries = [entry]
            return
        }
        if let entries = try? single.decode([Entry].self) {
            self.entries = entries
            return
        }
        self.entries = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if entries.count == 1, let only = entries.first {
            try container.encode(only)
        } else {
            try container.encode(entries)
        }
    }
}

public struct SourcePart: Codable, Hashable, Sendable {
    public var partIndex: Int
    public var sourceArchiveMember: String?
    public var sourceFile: String?
    public var sourceUUID: String?
    public var sourceIsDolby: Bool
    public var parsedSourceInUS: Int64?
    public var parsedSourceOutUS: Int64?
    public var sourceDurationUS: Int64?
    public var exportSourceInUS: Int64?
    public var exportSourceOutUS: Int64?
    public var actualHandleBeforeUS: Int64?
    public var actualHandleAfterUS: Int64?
    public var handleBeforeStatus: String?
    public var handleAfterStatus: String?

    enum CodingKeys: String, CodingKey {
        case partIndex = "part_index"
        case sourceArchiveMember = "source_archive_member"
        case sourceFile = "source_file"
        case sourceUUID = "source_uuid"
        case sourceIsDolby = "source_is_dolby"
        case parsedSourceInUS = "parsed_source_in_us"
        case parsedSourceOutUS = "parsed_source_out_us"
        case sourceDurationUS = "source_duration_us"
        case exportSourceInUS = "export_source_in_us"
        case exportSourceOutUS = "export_source_out_us"
        case actualHandleBeforeUS = "actual_handle_before_us"
        case actualHandleAfterUS = "actual_handle_after_us"
        case handleBeforeStatus = "handle_before_status"
        case handleAfterStatus = "handle_after_status"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partIndex = try container.decodeLossyInt(forKey: .partIndex) ?? 0
        sourceArchiveMember = try container.decodeIfPresent(String.self, forKey: .sourceArchiveMember)
        sourceFile = try container.decodeIfPresent(String.self, forKey: .sourceFile)
        sourceUUID = try container.decodeIfPresent(String.self, forKey: .sourceUUID)
        sourceIsDolby = try container.decodeLossyBool(forKey: .sourceIsDolby) ?? false
        parsedSourceInUS = try container.decodeLossyInt64(forKey: .parsedSourceInUS)
        parsedSourceOutUS = try container.decodeLossyInt64(forKey: .parsedSourceOutUS)
        sourceDurationUS = try container.decodeLossyInt64(forKey: .sourceDurationUS)
        exportSourceInUS = try container.decodeLossyInt64(forKey: .exportSourceInUS)
        exportSourceOutUS = try container.decodeLossyInt64(forKey: .exportSourceOutUS)
        actualHandleBeforeUS = try container.decodeLossyInt64(forKey: .actualHandleBeforeUS)
        actualHandleAfterUS = try container.decodeLossyInt64(forKey: .actualHandleAfterUS)
        handleBeforeStatus = try container.decodeIfPresent(String.self, forKey: .handleBeforeStatus)
        handleAfterStatus = try container.decodeIfPresent(String.self, forKey: .handleAfterStatus)
    }
}

public struct ManifestRow: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        let orderComponent = sequenceIndex.map(String.init) ?? clipNumber
        return "\(personKey)|\(questionKey)|\(ageKey)|\(orderComponent)"
    }

    public let clipNumber: String
    public let sequenceIndex: Int?
    public let person: String
    public let personKey: String
    public let question: String
    public let questionKey: String
    public let questionOriginalIndex: Int?
    public let age: String
    public let ageRawText: String?
    public let ageKey: String
    public let ageYears: Double?
    public let ageSortKey: Double?
    public let outputFile: String
    public let outputPath: String?
    public let exportStatus: String
    public let status: String?
    public let parserConfidence: ManifestParserConfidence?
    public let warnings: String
    public let notes: String
    public let sourceIsDolby: Bool
    public let hdrDolbyValidation: String
    public let sourceVideoSignature: ManifestVideoSignature?
    public let outputVideoSignature: ManifestVideoSignature?
    public let requestedHandleBeforeUS: Int64
    public let requestedHandleAfterUS: Int64
    public let actualHandleBeforeUS: Int64
    public let actualHandleAfterUS: Int64
    public let syntheticHandleBeforeUS: Int64
    public let syntheticHandleAfterUS: Int64
    public let handleBeforeStatus: String
    public let handleAfterStatus: String
    public let syntheticHandleBeforeStatus: String
    public let syntheticHandleAfterStatus: String
    public let realMediaStartInOutputUS: Int64
    public let realMediaEndInOutputUS: Int64
    public let answerStartInOutputUS: Int64
    public let answerEndInOutputUS: Int64
    public let durationDriftUS: Int64?
    public let sourcePartCount: Int
    public let sourceParts: [SourcePart]

    enum CodingKeys: String, CodingKey {
        case clipNumber = "clip_number"
        case sequenceIndex = "sequence_index"
        case person
        case personKey = "person_key"
        case question
        case questionKey = "question_key"
        case questionOriginalIndex = "question_original_index"
        case age
        case ageRawText = "age_raw_text"
        case ageKey = "age_key"
        case ageYears = "age_years"
        case ageSortKey = "age_sort_key"
        case outputFile = "output_file"
        case outputPath = "output_path"
        case exportStatus = "export_status"
        case status
        case parserConfidence = "confidence"
        case warnings
        case notes
        case sourceIsDolby = "source_is_dolby"
        case hdrDolbyValidation = "hdr_dolby_validation"
        case sourceVideoSignature = "source_video_signature"
        case outputVideoSignature = "output_video_signature"
        case requestedHandleBeforeUS = "requested_handle_before_us"
        case requestedHandleAfterUS = "requested_handle_after_us"
        case actualHandleBeforeUS = "actual_handle_before_us"
        case actualHandleAfterUS = "actual_handle_after_us"
        case syntheticHandleBeforeUS = "synthetic_handle_before_us"
        case syntheticHandleAfterUS = "synthetic_handle_after_us"
        case handleBeforeStatus = "handle_before_status"
        case handleAfterStatus = "handle_after_status"
        case syntheticHandleBeforeStatus = "synthetic_handle_before_status"
        case syntheticHandleAfterStatus = "synthetic_handle_after_status"
        case realMediaStartInOutputUS = "real_media_start_in_output_us"
        case realMediaEndInOutputUS = "real_media_end_in_output_us"
        case answerStartInOutputUS = "answer_start_in_output_us"
        case answerEndInOutputUS = "answer_end_in_output_us"
        case durationDriftUS = "duration_drift_us"
        case sourcePartCount = "source_part_count"
        case sourceParts = "source_parts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clipNumber = try container.decodeLossyString(forKey: .clipNumber) ?? "0"
        sequenceIndex = try container.decodeLossyInt(forKey: .sequenceIndex)
        person = try container.decodeIfPresent(String.self, forKey: .person) ?? ""
        personKey = try container.decodeIfPresent(String.self, forKey: .personKey) ?? ""
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        questionKey = try container.decodeIfPresent(String.self, forKey: .questionKey) ?? ""
        questionOriginalIndex = try container.decodeLossyInt(forKey: .questionOriginalIndex)
        age = try container.decodeIfPresent(String.self, forKey: .age) ?? ""
        ageRawText = try container.decodeIfPresent(String.self, forKey: .ageRawText)
        ageKey = try container.decodeIfPresent(String.self, forKey: .ageKey) ?? ""
        ageYears = try container.decodeLossyDouble(forKey: .ageYears)
        ageSortKey = try container.decodeLossyDouble(forKey: .ageSortKey)
        outputFile = try container.decodeIfPresent(String.self, forKey: .outputFile) ?? ""
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
        exportStatus = try container.decodeIfPresent(String.self, forKey: .exportStatus) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status)
        parserConfidence = try container.decodeIfPresent(ManifestParserConfidence.self, forKey: .parserConfidence)
        warnings = try container.decodeIfPresent(String.self, forKey: .warnings) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sourceIsDolby = try container.decodeLossyBool(forKey: .sourceIsDolby) ?? false
        hdrDolbyValidation = try container.decodeIfPresent(String.self, forKey: .hdrDolbyValidation) ?? "unknown"
        sourceVideoSignature = try container.decodeIfPresent(ManifestVideoSignature.self, forKey: .sourceVideoSignature)
        outputVideoSignature = try container.decodeIfPresent(ManifestVideoSignature.self, forKey: .outputVideoSignature)
        requestedHandleBeforeUS = try container.decodeLossyInt64(forKey: .requestedHandleBeforeUS) ?? 0
        requestedHandleAfterUS = try container.decodeLossyInt64(forKey: .requestedHandleAfterUS) ?? 0
        actualHandleBeforeUS = try container.decodeLossyInt64(forKey: .actualHandleBeforeUS) ?? 0
        actualHandleAfterUS = try container.decodeLossyInt64(forKey: .actualHandleAfterUS) ?? 0
        syntheticHandleBeforeUS = try container.decodeLossyInt64(forKey: .syntheticHandleBeforeUS) ?? 0
        syntheticHandleAfterUS = try container.decodeLossyInt64(forKey: .syntheticHandleAfterUS) ?? 0
        handleBeforeStatus = try container.decodeIfPresent(String.self, forKey: .handleBeforeStatus) ?? "unknown"
        handleAfterStatus = try container.decodeIfPresent(String.self, forKey: .handleAfterStatus) ?? "unknown"
        syntheticHandleBeforeStatus = try container.decodeIfPresent(String.self, forKey: .syntheticHandleBeforeStatus) ?? "unknown"
        syntheticHandleAfterStatus = try container.decodeIfPresent(String.self, forKey: .syntheticHandleAfterStatus) ?? "unknown"
        realMediaStartInOutputUS = try container.decodeLossyInt64(forKey: .realMediaStartInOutputUS) ?? 0
        realMediaEndInOutputUS = try container.decodeLossyInt64(forKey: .realMediaEndInOutputUS) ?? 0
        answerStartInOutputUS = try container.decodeLossyInt64(forKey: .answerStartInOutputUS) ?? 0
        answerEndInOutputUS = try container.decodeLossyInt64(forKey: .answerEndInOutputUS) ?? 0
        durationDriftUS = try container.decodeLossyInt64(forKey: .durationDriftUS)
        sourcePartCount = try container.decodeLossyInt(forKey: .sourcePartCount) ?? 0
        sourceParts = try container.decodeIfPresent([SourcePart].self, forKey: .sourceParts) ?? []
    }

    public var isUsableStatus: Bool {
        let normalizedExportStatus = exportStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedExportStatus == "exported" || normalizedExportStatus == "skipped_existing" else {
            return false
        }
        guard let status else { return true }
        return status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ready"
    }

    public var totalVisibleLeadingUS: Int64 {
        max(answerStartInOutputUS, 0)
    }

    public var totalVisibleTrailingUS: Int64 {
        max(actualHandleAfterUS + syntheticHandleAfterUS, 0)
    }

    public var answerDurationUS: Int64 {
        max(answerEndInOutputUS - answerStartInOutputUS, 0)
    }

    public var isHDRLike: Bool {
        if sourceIsDolby { return true }
        if hdrDolbyValidation.lowercased() == "passed" { return true }
        if sourceVideoSignature?.isHDRLike == true { return true }
        return false
    }
}
