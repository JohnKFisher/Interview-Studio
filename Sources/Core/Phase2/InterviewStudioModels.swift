import Foundation

public struct InterviewPerson: Codable, Hashable, Sendable {
    public var id: UUID
    public var readableKey: String
    public var displayName: String
    public var localeIdentifier: String
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        readableKey: String,
        displayName: String,
        localeIdentifier: String = Locale.current.identifier,
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.readableKey = readableKey
        self.displayName = displayName
        self.localeIdentifier = localeIdentifier
        self.extensions = extensions
    }
}

public struct InterviewQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var questionKey: String
    public var displayText: String
    public var order: Int
    public var isActive: Bool
    public var createdAt: Date
    public var retiredAt: Date?
    public var aliases: [String]
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        questionKey: String,
        displayText: String,
        order: Int,
        isActive: Bool = true,
        createdAt: Date = Date(),
        retiredAt: Date? = nil,
        aliases: [String] = [],
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.questionKey = questionKey
        self.displayText = displayText
        self.order = order
        self.isActive = isActive
        self.createdAt = createdAt
        self.retiredAt = retiredAt
        self.aliases = aliases
        self.extensions = extensions
    }
}

public struct AssemblySettings: Codable, Hashable, Sendable {
    public var renderSettings: RenderSettings
    public var plexMetadata: PlexMetadataInput
    public var openingTitle: String
    public var closingTitle: String
    public var extensions: [String: JSONValue]

    public init(
        renderSettings: RenderSettings = .default,
        // The companion is optional in the package-backed workflow. Keep
        // Phase 1's sidecar default unchanged; Phase 2 has no Plex settings
        // surface yet, so an enabled-but-empty companion must not block the
        // primary master publication.
        plexMetadata: PlexMetadataInput = .init(isEnabled: false),
        openingTitle: String = "",
        closingTitle: String = "",
        extensions: [String: JSONValue] = [:]
    ) {
        self.renderSettings = renderSettings
        self.plexMetadata = plexMetadata
        self.openingTitle = openingTitle
        self.closingTitle = closingTitle
        self.extensions = extensions
    }
}

public struct InterviewStudioProject: Codable, Hashable, Sendable {
    public var schema: SchemaDescriptor
    public var capabilities: CapabilityDeclarations
    public var projectID: UUID
    public var person: InterviewPerson
    public var questions: [InterviewQuestion]
    public var assemblySettings: AssemblySettings
    public var createdAt: Date
    public var updatedAt: Date
    public var migrationHistoryIDs: [UUID]
    public var extensions: [String: JSONValue]

    public init(
        projectID: UUID = UUID(),
        person: InterviewPerson,
        questions: [InterviewQuestion] = [],
        assemblySettings: AssemblySettings = .init(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        migrationHistoryIDs: [UUID] = [],
        requiredFeatures: [String] = [
            InterviewStudioFeature.questionThenYears,
            InterviewStudioFeature.generatedTextCard,
            InterviewStudioFeature.nativeSessionV1
        ],
        optionalFeatures: [String] = [InterviewStudioFeature.multipartAnswerV1, InterviewStudioFeature.transcriptV1],
        extensions: [String: JSONValue] = [:]
    ) {
        self.schema = SchemaDescriptor(
            name: InterviewStudioSchema.project,
            requiredFeatures: requiredFeatures,
            optionalFeatures: optionalFeatures
        )
        self.capabilities = CapabilityDeclarations(required: requiredFeatures, optional: optionalFeatures)
        self.projectID = projectID
        self.person = person
        self.questions = questions
        self.assemblySettings = assemblySettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.migrationHistoryIDs = migrationHistoryIDs
        self.extensions = extensions
    }

    public var compatibility: SchemaCompatibility {
        schema.compatibility()
    }

    public var activeQuestions: [InterviewQuestion] {
        questions.filter(\.isActive).sorted { $0.order < $1.order }
    }

    public mutating func insertQuestion(displayText: String, at order: Int? = nil) -> InterviewQuestion {
        let key = InterviewStudioKey.readableKey(from: displayText, existing: Set(questions.map(\.questionKey)))
        let insertionOrder = order ?? (questions.map(\.order).max().map { $0 + 1 } ?? 0)
        let question = InterviewQuestion(questionKey: key, displayText: displayText, order: insertionOrder)
        questions.append(question)
        questions.sort { $0.order < $1.order }
        updatedAt = Date()
        return question
    }
}

public enum RecordingImportSource: String, Codable, Hashable, Sendable {
    case finder
    case photos
    case legacy
}

public struct MediaSignature: Codable, Hashable, Sendable {
    public var byteCount: Int64
    public var sha256: String
    public var durationMicroseconds: Int64?
    public var width: Int?
    public var height: Int?
    public var nominalFrameRate: Double?
    public var actualFrameRate: Double?
    public var audioChannels: Int?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorMatrix: String?
    public var extensions: [String: JSONValue]

    public init(
        byteCount: Int64,
        sha256: String,
        durationMicroseconds: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        nominalFrameRate: Double? = nil,
        actualFrameRate: Double? = nil,
        audioChannels: Int? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        colorMatrix: String? = nil,
        extensions: [String: JSONValue] = [:]
    ) {
        self.byteCount = byteCount
        self.sha256 = sha256
        self.durationMicroseconds = durationMicroseconds
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.actualFrameRate = actualFrameRate
        self.audioChannels = audioChannels
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.colorMatrix = colorMatrix
        self.extensions = extensions
    }
}

public enum SessionWorkflowKind: Codable, Hashable, Sendable {
    case questionFirstV1
    case recordingFirstV1
    case unsupported(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "question_first_v1": self = .questionFirstV1
        case "recording_first_v1": self = .recordingFirstV1
        default: self = .unsupported(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .questionFirstV1: try container.encode("question_first_v1")
        case .recordingFirstV1: try container.encode("recording_first_v1")
        case .unsupported(let value): try container.encode(value)
        }
    }

    public var rawValue: String {
        switch self {
        case .questionFirstV1: return "question_first_v1"
        case .recordingFirstV1: return "recording_first_v1"
        case .unsupported(let value): return value
        }
    }
}

public enum SourceRecordingState: String, Codable, Hashable, Sendable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case finished
}
public typealias RecordingProgressState = SourceRecordingState

public struct SourceRecording: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ageKey: String
    public var ageLabel: String
    public var packageRelativePath: String
    public var originalFilename: String
    public var importSource: RecordingImportSource
    public var photosLocalIdentifier: String?
    public var captureDate: Date?
    public var order: Int
    public var recordingNumber: Int
    public var recordingState: RecordingProgressState
    public var provisionalInPointUS: Int64?
    public var firstQuestionHint: String?
    public var mediaSignature: MediaSignature
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        ageKey: String,
        ageLabel: String,
        packageRelativePath: String,
        originalFilename: String,
        importSource: RecordingImportSource,
        photosLocalIdentifier: String? = nil,
        captureDate: Date? = nil,
        order: Int = 0,
        recordingNumber: Int? = nil,
        recordingState: RecordingProgressState = .notStarted,
        provisionalInPointUS: Int64? = nil,
        firstQuestionHint: String? = nil,
        mediaSignature: MediaSignature,
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.ageKey = ageKey
        self.ageLabel = ageLabel
        self.packageRelativePath = packageRelativePath
        self.originalFilename = originalFilename
        self.importSource = importSource
        self.photosLocalIdentifier = photosLocalIdentifier
        self.captureDate = captureDate
        self.order = order
        self.recordingNumber = recordingNumber ?? order + 1
        self.recordingState = recordingState
        self.provisionalInPointUS = provisionalInPointUS
        self.firstQuestionHint = firstQuestionHint
        self.mediaSignature = mediaSignature
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey { case id, ageKey, ageLabel, packageRelativePath, originalFilename, importSource, photosLocalIdentifier, captureDate, order, recordingNumber, recordingState, provisionalInPointUS, firstQuestionHint, mediaSignature, extensions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); ageKey = try c.decode(String.self, forKey: .ageKey); ageLabel = try c.decode(String.self, forKey: .ageLabel)
        packageRelativePath = try c.decode(String.self, forKey: .packageRelativePath); originalFilename = try c.decode(String.self, forKey: .originalFilename)
        importSource = try c.decode(RecordingImportSource.self, forKey: .importSource); photosLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .photosLocalIdentifier)
        captureDate = try c.decodeIfPresent(Date.self, forKey: .captureDate); order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        recordingNumber = try c.decodeIfPresent(Int.self, forKey: .recordingNumber) ?? order + 1
        recordingState = try c.decodeIfPresent(RecordingProgressState.self, forKey: .recordingState) ?? .notStarted
        provisionalInPointUS = try c.decodeIfPresent(Int64.self, forKey: .provisionalInPointUS)
        firstQuestionHint = try c.decodeIfPresent(String.self, forKey: .firstQuestionHint); mediaSignature = try c.decode(MediaSignature.self, forKey: .mediaSignature)
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }
}

public enum QuestionProgressState: String, Codable, Hashable, Sendable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case complete
    case skipped
    case needsReview = "needs_review"
}

public enum AnswerReviewState: String, Codable, Hashable, Sendable {
    case unreviewed
    case inProgress = "in_progress"
    case reviewed
    case needsReview = "needs_review"
}

public struct RawAnswerMarkers: Codable, Hashable, Sendable {
    public var answerStart: MediaTime?
    public var answerEnd: MediaTime?
    public var interviewerResumes: MediaTime?
    public var noFollowingInterviewerSpeech: Bool

    public init(answerStart: MediaTime? = nil, answerEnd: MediaTime? = nil, interviewerResumes: MediaTime? = nil, noFollowingInterviewerSpeech: Bool = false) {
        self.answerStart = answerStart
        self.answerEnd = answerEnd
        self.interviewerResumes = interviewerResumes
        self.noFollowingInterviewerSpeech = noFollowingInterviewerSpeech
    }
}

public struct RefinedBoundaries: Codable, Hashable, Sendable {
    public var visibleStart: MediaTime
    public var visibleEnd: MediaTime
    public var safeLeadingStart: MediaTime
    public var safeTrailingEnd: MediaTime
    public var confidence: Double
    public var reasons: [String]
    public var algorithmIdentifier: String
    public var algorithmVersion: String
    public var manualOverride: Bool

    public init(
        visibleStart: MediaTime,
        visibleEnd: MediaTime,
        safeLeadingStart: MediaTime,
        safeTrailingEnd: MediaTime,
        confidence: Double,
        reasons: [String] = [],
        algorithmIdentifier: String = "vad-refinement",
        algorithmVersion: String = "1.0",
        manualOverride: Bool = false
    ) {
        self.visibleStart = visibleStart
        self.visibleEnd = visibleEnd
        self.safeLeadingStart = safeLeadingStart
        self.safeTrailingEnd = safeTrailingEnd
        self.confidence = confidence
        self.reasons = reasons
        self.algorithmIdentifier = algorithmIdentifier
        self.algorithmVersion = algorithmVersion
        self.manualOverride = manualOverride
    }
}

public struct AnswerPart: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceRecordingID: UUID
    public var rawMarkers: RawAnswerMarkers
    public var refinedBoundaries: RefinedBoundaries?
    public var sourceOrder: Int
    public var extensions: [String: JSONValue]

    public init(id: UUID = UUID(), sourceRecordingID: UUID, rawMarkers: RawAnswerMarkers, refinedBoundaries: RefinedBoundaries? = nil, sourceOrder: Int = 0, extensions: [String: JSONValue] = [:]) {
        self.id = id
        self.sourceRecordingID = sourceRecordingID
        self.rawMarkers = rawMarkers
        self.refinedBoundaries = refinedBoundaries
        self.sourceOrder = sourceOrder
        self.extensions = extensions
    }
}

public struct AnswerTake: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var parts: [AnswerPart]
    public var isMultiPart: Bool
    public var reviewState: AnswerReviewState
    public var confidence: Double?
    public var extensions: [String: JSONValue]

    public init(id: UUID = UUID(), createdAt: Date = Date(), parts: [AnswerPart], isMultiPart: Bool = false, reviewState: AnswerReviewState = .unreviewed, confidence: Double? = nil, extensions: [String: JSONValue] = [:]) {
        self.id = id
        self.createdAt = createdAt
        self.parts = parts.sorted { $0.sourceOrder < $1.sourceOrder }
        self.isMultiPart = isMultiPart
        self.reviewState = reviewState
        self.confidence = confidence
        self.extensions = extensions
    }
}

public enum CandidateReviewState: String, Codable, Hashable, Sendable {
    case unreviewed
    case inProgress = "in_progress"
    case needsReview = "needs_review"
    case approved
    case skipped
    case discarded
}

public struct CandidateSegment: Codable, Hashable, Sendable {
    public var start: MediaTime
    public var end: MediaTime

    public init(start: MediaTime, end: MediaTime) { self.start = start; self.end = end }
    public var isValid: Bool { end > start }
    public var duration: MediaTime { MediaTime.microseconds(max(0, end.microseconds - start.microseconds)) }
    public var range: ClosedRange<MediaTime> { start...end }
    public func clamped(to duration: MediaTime) -> CandidateSegment { .init(start: MediaTime.microseconds(max(0, min(start.microseconds, duration.microseconds))), end: MediaTime.microseconds(max(0, min(end.microseconds, duration.microseconds)))) }
}

public struct AnswerCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceRecordingID: UUID
    public var recordingNumber: Int
    public var clipNumber: Int
    public var sourceOrder: Int
    public var rawMarkers: RawAnswerMarkers
    public var refinedBoundaries: RefinedBoundaries?
    public var retainedSegments: [CandidateSegment]
    public var reviewState: CandidateReviewState
    public var transcript: AnswerTranscript?
    public var createdAt: Date
    public var updatedAt: Date
    public var extensions: [String: JSONValue]

    public init(id: UUID = UUID(), sourceRecordingID: UUID, recordingNumber: Int, clipNumber: Int, sourceOrder: Int = 0, rawMarkers: RawAnswerMarkers, refinedBoundaries: RefinedBoundaries? = nil, retainedSegments: [CandidateSegment] = [], reviewState: CandidateReviewState = .unreviewed, transcript: AnswerTranscript? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), extensions: [String: JSONValue] = [:]) {
        self.id = id; self.sourceRecordingID = sourceRecordingID; self.recordingNumber = recordingNumber; self.clipNumber = clipNumber; self.sourceOrder = sourceOrder; self.rawMarkers = rawMarkers; self.refinedBoundaries = refinedBoundaries
        self.retainedSegments = retainedSegments.sorted { $0.start < $1.start }; self.reviewState = reviewState; self.transcript = transcript; self.createdAt = createdAt; self.updatedAt = updatedAt; self.extensions = extensions
    }
    public var label: String { "Recording \(recordingNumber) · Clip \(clipNumber)" }
    public var visibleRange: CandidateSegment? { if let b = refinedBoundaries { return .init(start: b.visibleStart, end: b.visibleEnd) }; guard let s = rawMarkers.answerStart, let e = rawMarkers.answerEnd else { return nil }; return .init(start: s, end: e) }
    public var safeRange: CandidateSegment? { guard let b = refinedBoundaries else { return visibleRange }; return .init(start: b.safeLeadingStart, end: b.safeTrailingEnd) }
}

public struct NormalizedAge: Codable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var sortValue: Double?
    public init(key: String, label: String, sortValue: Double?) { self.key = key; self.label = label; self.sortValue = sortValue }
}

public enum AgeNormalization {
    public static func normalize(key: String, label: String, sortValue: Double? = nil) -> NormalizedAge {
        let value = sortValue ?? firstNumericValue(in: label)
        let display = value.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0).trimmingCharacters(in: CharacterSet(charactersIn: "0")).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let normalizedLabel = display.map { "\($0) \($0 == "1" ? "Year" : "Years") Old" } ?? label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = value.map { "age_\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0).trimmingCharacters(in: CharacterSet(charactersIn: "0")).trimmingCharacters(in: CharacterSet(charactersIn: ".")))" } ?? key
        return NormalizedAge(key: normalizedKey, label: normalizedLabel, sortValue: value)
    }

    private static func firstNumericValue(in text: String) -> Double? {
        let allowed = CharacterSet(charactersIn: "0123456789.")
        var token = ""
        var sawDigit = false
        for scalar in text.unicodeScalars {
            if allowed.contains(scalar) {
                token.unicodeScalars.append(scalar)
                sawDigit = sawDigit || (scalar.value >= 48 && scalar.value <= 57)
            } else if sawDigit {
                break
            }
        }
        return sawDigit ? Double(token) : nil
    }
}

public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var start: MediaTime
    public var end: MediaTime

    public init(id: UUID = UUID(), text: String, start: MediaTime, end: MediaTime) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct AnswerTranscript: Codable, Hashable, Sendable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var localeIdentifier: String
    public var sourceRecordingID: UUID?
    public var createdAt: Date

    public init(
        text: String,
        segments: [TranscriptSegment] = [],
        localeIdentifier: String = Locale.current.identifier,
        sourceRecordingID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.segments = segments
        self.localeIdentifier = localeIdentifier
        self.sourceRecordingID = sourceRecordingID
        self.createdAt = createdAt
    }
}

public struct InterviewAnswer: Codable, Hashable, Sendable {
    public var questionKey: String
    public var assignedCandidateID: UUID?
    public var selectedTakeID: UUID?
    public var takes: [AnswerTake]
    public var state: QuestionProgressState
    public var lastReviewedAt: Date?
    public var transcript: AnswerTranscript?
    public var extensions: [String: JSONValue]

    public init(questionKey: String, assignedCandidateID: UUID? = nil, selectedTakeID: UUID? = nil, takes: [AnswerTake] = [], state: QuestionProgressState = .notStarted, lastReviewedAt: Date? = nil, transcript: AnswerTranscript? = nil, extensions: [String: JSONValue] = [:]) {
        self.questionKey = questionKey
        self.assignedCandidateID = assignedCandidateID
        self.selectedTakeID = selectedTakeID
        self.takes = takes
        self.state = state
        self.lastReviewedAt = lastReviewedAt
        self.transcript = transcript
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey { case questionKey, assignedCandidateID, selectedTakeID, takes, state, lastReviewedAt, transcript, extensions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionKey = try c.decode(String.self, forKey: .questionKey); assignedCandidateID = try c.decodeIfPresent(UUID.self, forKey: .assignedCandidateID)
        selectedTakeID = try c.decodeIfPresent(UUID.self, forKey: .selectedTakeID); takes = try c.decodeIfPresent([AnswerTake].self, forKey: .takes) ?? []
        state = try c.decodeIfPresent(QuestionProgressState.self, forKey: .state) ?? .notStarted; lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        transcript = try c.decodeIfPresent(AnswerTranscript.self, forKey: .transcript); extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }

    public var selectedTake: AnswerTake? {
        guard let selectedTakeID else { return nil }
        return takes.first { $0.id == selectedTakeID }
    }
}

public enum SessionLifecycle: String, Codable, Hashable, Sendable {
    case open
    case locked
}

public struct SessionAuditEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var action: String
    public var detail: String

    public init(id: UUID = UUID(), date: Date = Date(), action: String, detail: String = "") {
        self.id = id
        self.date = date
        self.action = action
        self.detail = detail
    }
}

public struct InterviewSession: Codable, Hashable, Sendable, Identifiable {
    public var schema: SchemaDescriptor
    public var capabilities: CapabilityDeclarations
    public var id: UUID
    public var workflowKind: SessionWorkflowKind
    public var ageKey: String
    public var ageLabel: String
    public var ageSortValue: Double?
    public var interviewDate: Date?
    public var lifecycle: SessionLifecycle
    public var revision: Int
    public var recordings: [SourceRecording]
    public var answers: [String: InterviewAnswer]
    public var candidates: [AnswerCandidate]
    public var calendarYear: Int?
    public var isArchived: Bool
    public var auditEvents: [SessionAuditEvent]
    public var publicationFingerprint: String?
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        workflowKind: SessionWorkflowKind = .questionFirstV1,
        ageKey: String,
        ageLabel: String,
        ageSortValue: Double? = nil,
        interviewDate: Date? = nil,
        recordings: [SourceRecording] = [],
        answers: [String: InterviewAnswer] = [:],
        candidates: [AnswerCandidate] = [],
        calendarYear: Int? = nil,
        isArchived: Bool = false,
        auditEvents: [SessionAuditEvent] = [],
        extensions: [String: JSONValue] = [:]
    ) {
        self.schema = SchemaDescriptor(name: InterviewStudioSchema.session, requiredFeatures: [InterviewStudioFeature.nativeSessionV1] + (workflowKind == .recordingFirstV1 ? [InterviewStudioFeature.recordingFirstV1] : []))
        self.capabilities = CapabilityDeclarations(required: [InterviewStudioFeature.nativeSessionV1] + (workflowKind == .recordingFirstV1 ? [InterviewStudioFeature.recordingFirstV1] : []))
        self.id = id
        self.workflowKind = workflowKind
        self.ageKey = ageKey
        self.ageLabel = ageLabel
        self.ageSortValue = ageSortValue
        self.interviewDate = interviewDate
        self.lifecycle = .open
        self.revision = 0
        self.recordings = recordings
        self.answers = answers
        self.candidates = candidates
        self.calendarYear = calendarYear
        self.isArchived = isArchived
        self.auditEvents = auditEvents
        self.publicationFingerprint = nil
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey { case schema, capabilities, id, workflowKind, ageKey, ageLabel, ageSortValue, interviewDate, lifecycle, revision, recordings, answers, candidates, calendarYear, isArchived, auditEvents, publicationFingerprint, extensions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(SchemaDescriptor.self, forKey: .schema) ?? SchemaDescriptor(name: InterviewStudioSchema.session)
        capabilities = try c.decodeIfPresent(CapabilityDeclarations.self, forKey: .capabilities) ?? .init(required: [InterviewStudioFeature.nativeSessionV1])
        id = try c.decode(UUID.self, forKey: .id); workflowKind = try c.decodeIfPresent(SessionWorkflowKind.self, forKey: .workflowKind) ?? .questionFirstV1
        if case .unsupported(let rawValue) = workflowKind {
            if !schema.requiredFeatures.contains(rawValue) { schema.requiredFeatures.append(rawValue) }
            if !capabilities.required.contains(rawValue) { capabilities.required.append(rawValue) }
        }
        ageKey = try c.decode(String.self, forKey: .ageKey); ageLabel = try c.decode(String.self, forKey: .ageLabel); ageSortValue = try c.decodeIfPresent(Double.self, forKey: .ageSortValue)
        interviewDate = try c.decodeIfPresent(Date.self, forKey: .interviewDate); lifecycle = try c.decodeIfPresent(SessionLifecycle.self, forKey: .lifecycle) ?? .open; revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        recordings = try c.decodeIfPresent([SourceRecording].self, forKey: .recordings) ?? []; answers = try c.decodeIfPresent([String: InterviewAnswer].self, forKey: .answers) ?? [:]
        candidates = try c.decodeIfPresent([AnswerCandidate].self, forKey: .candidates) ?? []; calendarYear = try c.decodeIfPresent(Int.self, forKey: .calendarYear); isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        auditEvents = try c.decodeIfPresent([SessionAuditEvent].self, forKey: .auditEvents) ?? []; publicationFingerprint = try c.decodeIfPresent(String.self, forKey: .publicationFingerprint); extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }

    public var compatibility: SchemaCompatibility { schema.compatibility() }

    public var incompleteQuestionKeys: [String] {
        answers.values.filter { $0.state == .inProgress || $0.state == .needsReview || $0.state == .notStarted }.map(\.questionKey).sorted()
    }
    public var isLocked: Bool { lifecycle == .locked }
    public var isActive: Bool { !isArchived }
    public var activeRecordings: [SourceRecording] { recordings.sorted { $0.order < $1.order } }
    public var activeCandidates: [AnswerCandidate] { candidates.filter { $0.reviewState != .discarded } }
    public var archivedCandidates: [AnswerCandidate] { candidates.filter { $0.reviewState == .discarded } }
    public var nextRecordingNumber: Int { (recordings.map(\.recordingNumber).max() ?? 0) + 1 }
    public func nextClipNumber(for recordingID: UUID) -> Int { (candidates.filter { $0.sourceRecordingID == recordingID }.map(\.clipNumber).max() ?? 0) + 1 }
    public func normalizedAge() -> NormalizedAge { AgeNormalization.normalize(key: ageKey, label: ageLabel, sortValue: ageSortValue) }

    public mutating func mergeImportedRecordings(
        _ importedRecordings: [SourceRecording],
        importedAtRevision: Int
    ) -> RecordingImportMergeResult {
        let previousRevision = revision
        var knownIDs = Set(recordings.map(\.id))
        var knownHashes = Set(recordings.map { $0.mediaSignature.sha256 }.filter { !$0.isEmpty })
        var nextOrder = (recordings.map(\.order).max() ?? -1) + 1
        var nextRecordingNumber = self.nextRecordingNumber
        var addedRecordings: [SourceRecording] = []

        for original in importedRecordings {
            let hash = original.mediaSignature.sha256
            guard knownIDs.insert(original.id).inserted,
                  hash.isEmpty || knownHashes.insert(hash).inserted else { continue }

            var recording = original
            recording.ageKey = ageKey
            recording.ageLabel = ageLabel
            recording.order = nextOrder
            recording.recordingNumber = nextRecordingNumber
            nextOrder += 1
            nextRecordingNumber += 1
            recordings.append(recording)
            addedRecordings.append(recording)
        }

        guard !addedRecordings.isEmpty else {
            return RecordingImportMergeResult(
                addedRecordings: [],
                importedAtRevision: importedAtRevision,
                previousRevision: previousRevision,
                resultingRevision: previousRevision
            )
        }

        revision += 1
        publicationFingerprint = nil
        let detail = previousRevision == importedAtRevision
            ? "Imported \(addedRecordings.count) recording(s) at revision \(revision)."
            : "Merged \(addedRecordings.count) recording(s) onto revision \(previousRevision) after concurrent edits from revision \(importedAtRevision)."
        appendAudit("recordings_imported", detail: detail)
        return RecordingImportMergeResult(
            addedRecordings: addedRecordings,
            importedAtRevision: importedAtRevision,
            previousRevision: previousRevision,
            resultingRevision: revision
        )
    }

    public mutating func changeAge(key: String, label: String, sortValue: Double? = nil) throws {
        guard compatibility.isWritable else { throw InterviewStudioCompatibilityError.readOnly("The session uses an unsupported schema or workflow.") }
        guard isActive else { throw InterviewStudioCompatibilityError.invalid("Restore the archived session before changing its age.") }
        guard lifecycle == .open else { throw InterviewStudioCompatibilityError.invalid("Unlock the session before changing its age.") }
        ageKey = key
        ageLabel = label
        ageSortValue = sortValue
        for index in recordings.indices {
            recordings[index].ageKey = key
            recordings[index].ageLabel = label
        }
        revision += 1
        publicationFingerprint = nil
        appendAudit("change_age", detail: label)
    }
    public mutating func archive() throws {
        guard compatibility.isWritable else { throw InterviewStudioCompatibilityError.readOnly("The session uses an unsupported schema or workflow.") }
        guard isActive else { return }
        guard lifecycle == .open else { throw InterviewStudioCompatibilityError.invalid("Unlock the age entry before archiving it.") }
        isArchived = true
        revision += 1
        publicationFingerprint = nil
        appendAudit("archive")
    }
    public mutating func restore() throws {
        guard compatibility.isWritable else { throw InterviewStudioCompatibilityError.readOnly("The session uses an unsupported schema or workflow.") }
        guard isArchived else { return }
        isArchived = false
        revision += 1
        publicationFingerprint = nil
        appendAudit("restore")
    }
    public mutating func lockWithWarnings() throws -> [String] {
        guard compatibility.isWritable else { throw InterviewStudioCompatibilityError.readOnly("The session uses an unsupported schema or workflow.") }
        guard isActive else { throw InterviewStudioCompatibilityError.invalid("Restore the archived session before locking it.") }
        guard lifecycle == .open else { return [] }
        let readiness = RecordingFirstWorkflow.readiness(for: self)
        guard readiness.blockers.isEmpty else {
            throw InterviewStudioCompatibilityError.invalid(readiness.blockers.joined(separator: "\n"))
        }
        let warnings = candidates.filter { $0.reviewState == .unreviewed || $0.reviewState == .needsReview || $0.reviewState == .skipped }.map { "Candidate \($0.label) still needs review." }
        let assignmentProblems = RecordingFirstWorkflow.validateAssignments(in: self)
        guard assignmentProblems.isEmpty else {
            throw InterviewStudioCompatibilityError.invalid(assignmentProblems.joined(separator: "\n"))
        }
        lifecycle = .locked
        revision += 1
        publicationFingerprint = nil
        appendAudit("lock_with_warnings", detail: warnings.isEmpty ? "No unresolved candidate warnings." : warnings.joined(separator: " "))
        return warnings
    }

    public mutating func appendAudit(_ action: String, detail: String = "") {
        auditEvents.append(SessionAuditEvent(action: action, detail: detail))
    }

    public mutating func unlock() throws {
        guard compatibility.isWritable else { throw InterviewStudioCompatibilityError.readOnly("The session uses an unsupported schema or workflow.") }
        guard isActive else { throw InterviewStudioCompatibilityError.invalid("Restore the archived session before unlocking it.") }
        guard lifecycle == .locked else { return }
        lifecycle = .open
        revision += 1
        publicationFingerprint = nil
        appendAudit("unlock", detail: "Created editable revision \(revision).")
    }

    public mutating func lock() throws {
        guard compatibility.isWritable else { throw InterviewStudioCompatibilityError.readOnly("The session uses an unsupported schema or workflow.") }
        guard isActive else { throw InterviewStudioCompatibilityError.invalid("Restore the archived session before locking it.") }
        guard lifecycle == .open else { return }
        let incomplete = incompleteQuestionKeys
        if !incomplete.isEmpty {
            throw InterviewStudioCompatibilityError.invalid("Cannot lock while answers need review: \(incomplete.joined(separator: ", ")).")
        }
        lifecycle = .locked
        revision += 1
        appendAudit("lock", detail: "Locked revision \(revision).")
    }
}

public struct RecordingImportMergeResult: Codable, Hashable, Sendable {
    public var addedRecordings: [SourceRecording]
    public var importedAtRevision: Int
    public var previousRevision: Int
    public var resultingRevision: Int

    public init(addedRecordings: [SourceRecording], importedAtRevision: Int, previousRevision: Int, resultingRevision: Int) {
        self.addedRecordings = addedRecordings
        self.importedAtRevision = importedAtRevision
        self.previousRevision = previousRevision
        self.resultingRevision = resultingRevision
    }

    public var wasRebased: Bool { importedAtRevision != previousRevision }
}

public struct PublicationRecord: Codable, Hashable, Sendable, Identifiable {
    public var schema: SchemaDescriptor
    public var id: UUID
    public var projectID: UUID
    public var sessionID: UUID
    public var revision: Int
    public var fingerprint: String
    public var manifestRelativePath: String
    public var recipe: PublicationRecipe
    public var generatedAt: Date
    public var answerCount: Int
    public var extensions: [String: JSONValue]

    public init(id: UUID = UUID(), projectID: UUID, sessionID: UUID, revision: Int, fingerprint: String, manifestRelativePath: String, recipe: PublicationRecipe, generatedAt: Date = Date(), answerCount: Int, extensions: [String: JSONValue] = [:]) {
        self.schema = SchemaDescriptor(name: InterviewStudioSchema.publication, requiredFeatures: [InterviewStudioFeature.nativeSessionV1])
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.revision = revision
        self.fingerprint = fingerprint
        self.manifestRelativePath = manifestRelativePath
        self.recipe = recipe
        self.generatedAt = generatedAt
        self.answerCount = answerCount
        self.extensions = extensions
    }
}

public struct PublicationRecipe: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var codec: String
    public var pixelFormat: String
    public var colorPrimaries: String
    public var transferFunction: String
    public var colorMatrix: String
    public var videoBitrate: Int
    public var audioSampleRate: Int
    public var audioChannels: Int
    public var audioBitDepth: Int
    public var extensions: [String: JSONValue]

    public static let phaseTwoDefault = PublicationRecipe(
        width: 3_840,
        height: 2_160,
        frameRate: 60,
        codec: "hvc1",
        pixelFormat: "x420",
        colorPrimaries: "ITU_R_2020",
        transferFunction: "ITU_R_2100_HLG",
        colorMatrix: "ITU_R_2020",
        videoBitrate: 160_000_000,
        audioSampleRate: 48_000,
        audioChannels: 2,
        audioBitDepth: 24
    )

    public init(width: Int, height: Int, frameRate: Int, codec: String, pixelFormat: String, colorPrimaries: String, transferFunction: String, colorMatrix: String, videoBitrate: Int, audioSampleRate: Int, audioChannels: Int, audioBitDepth: Int, extensions: [String: JSONValue] = [:]) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.colorMatrix = colorMatrix
        self.videoBitrate = videoBitrate
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.audioBitDepth = audioBitDepth
        self.extensions = extensions
    }
}

public struct MigrationRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var sourcePathDescription: String
    public var importedManifestSHA256: String?
    public var decisionSummary: [String]

    public init(id: UUID = UUID(), date: Date = Date(), sourcePathDescription: String, importedManifestSHA256: String? = nil, decisionSummary: [String] = []) {
        self.id = id
        self.date = date
        self.sourcePathDescription = sourcePathDescription
        self.importedManifestSHA256 = importedManifestSHA256
        self.decisionSummary = decisionSummary
    }
}

public enum InterviewStudioPackageMigration {
    /// Stable identity for the repair of packages created while the Phase 2
    /// AssemblySettings default accidentally enabled an empty Plex companion.
    public static let accidentalEmptyPlexCompanionDefaultID = UUID(uuidString: "D6FC4F3D-4BC1-4C24-A3A6-2B0F0A0E0E42")!

    public static func repairAccidentalEmptyPlexCompanion(
        in project: InterviewStudioProject,
        sourcePathDescription: String,
        date: Date = Date()
    ) -> (project: InterviewStudioProject, migrationRecord: MigrationRecord?) {
        guard project.assemblySettings.plexMetadata == PlexMetadataInput() else {
            return (project, nil)
        }

        var repaired = project
        repaired.assemblySettings.plexMetadata.isEnabled = false
        repaired.updatedAt = date
        if !repaired.migrationHistoryIDs.contains(accidentalEmptyPlexCompanionDefaultID) {
            repaired.migrationHistoryIDs.append(accidentalEmptyPlexCompanionDefaultID)
        }
        let record = MigrationRecord(
            id: accidentalEmptyPlexCompanionDefaultID,
            date: date,
            sourcePathDescription: sourcePathDescription,
            decisionSummary: [
                "Disabled the accidental empty Plex companion default in an existing package-backed Phase 2 project.",
                "Only assemblySettings.plexMetadata.isEnabled changed; source media, answers, render settings, and titles were preserved."
            ]
        )
        return (repaired, record)
    }
}
