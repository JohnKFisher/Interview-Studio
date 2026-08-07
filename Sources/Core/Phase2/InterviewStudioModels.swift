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
        plexMetadata: PlexMetadataInput = .init(),
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
        self.firstQuestionHint = firstQuestionHint
        self.mediaSignature = mediaSignature
        self.extensions = extensions
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

public struct InterviewAnswer: Codable, Hashable, Sendable {
    public var questionKey: String
    public var selectedTakeID: UUID?
    public var takes: [AnswerTake]
    public var state: QuestionProgressState
    public var lastReviewedAt: Date?
    public var extensions: [String: JSONValue]

    public init(questionKey: String, selectedTakeID: UUID? = nil, takes: [AnswerTake] = [], state: QuestionProgressState = .notStarted, lastReviewedAt: Date? = nil, extensions: [String: JSONValue] = [:]) {
        self.questionKey = questionKey
        self.selectedTakeID = selectedTakeID
        self.takes = takes
        self.state = state
        self.lastReviewedAt = lastReviewedAt
        self.extensions = extensions
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
    public var ageKey: String
    public var ageLabel: String
    public var ageSortValue: Double?
    public var interviewDate: Date?
    public var lifecycle: SessionLifecycle
    public var revision: Int
    public var recordings: [SourceRecording]
    public var answers: [String: InterviewAnswer]
    public var auditEvents: [SessionAuditEvent]
    public var publicationFingerprint: String?
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        ageKey: String,
        ageLabel: String,
        ageSortValue: Double? = nil,
        interviewDate: Date? = nil,
        recordings: [SourceRecording] = [],
        answers: [String: InterviewAnswer] = [:],
        auditEvents: [SessionAuditEvent] = [],
        extensions: [String: JSONValue] = [:]
    ) {
        self.schema = SchemaDescriptor(name: InterviewStudioSchema.session, requiredFeatures: [InterviewStudioFeature.nativeSessionV1])
        self.capabilities = CapabilityDeclarations(required: [InterviewStudioFeature.nativeSessionV1])
        self.id = id
        self.ageKey = ageKey
        self.ageLabel = ageLabel
        self.ageSortValue = ageSortValue
        self.interviewDate = interviewDate
        self.lifecycle = .open
        self.revision = 0
        self.recordings = recordings
        self.answers = answers
        self.auditEvents = auditEvents
        self.publicationFingerprint = nil
        self.extensions = extensions
    }

    public var compatibility: SchemaCompatibility { schema.compatibility() }

    public var incompleteQuestionKeys: [String] {
        answers.values.filter { $0.state == .inProgress || $0.state == .needsReview || $0.state == .notStarted }.map(\.questionKey).sorted()
    }

    public mutating func appendAudit(_ action: String, detail: String = "") {
        auditEvents.append(SessionAuditEvent(action: action, detail: detail))
    }

    public mutating func unlock() throws {
        guard lifecycle == .locked else { return }
        lifecycle = .open
        revision += 1
        publicationFingerprint = nil
        appendAudit("unlock", detail: "Created editable revision \(revision).")
    }

    public mutating func lock() throws {
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
