import Foundation

public enum AssemblyIssueSeverity: String, Codable, CaseIterable, Sendable {
    case blocker
    case warning
    case info
}

public struct AssemblyIssue: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var severity: AssemblyIssueSeverity
    public var code: String
    public var humanMessage: String
    public var aiContext: [String: JSONValue]
    public var suggestedFix: String

    public init(
        severity: AssemblyIssueSeverity,
        code: String,
        humanMessage: String,
        aiContext: [String: JSONValue] = [:],
        suggestedFix: String = ""
    ) {
        self.id = UUID()
        self.severity = severity
        self.code = code
        self.humanMessage = humanMessage
        self.aiContext = aiContext
        self.suggestedFix = suggestedFix
    }
}

public enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public struct Confidence: Codable, Hashable, Sendable {
    public var level: ConfidenceLevel
    public var reasons: [String]

    public init(level: ConfidenceLevel, reasons: [String] = []) {
        self.level = level
        self.reasons = reasons
    }
}

public struct ExportProfile: Codable, Hashable, Sendable {
    public var profileID: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var dynamicRange: String
    public var codec: String
    public var colorPrimaries: String
    public var colorTransfer: String
    public var colorMatrix: String
    public var containerExtension: String

    public static let appleHLG4K60 = ExportProfile(
        profileID: "apple_hlg_4k60",
        width: 3840,
        height: 2160,
        frameRate: 60,
        dynamicRange: "hdr_hlg",
        codec: "hevc_main10",
        colorPrimaries: "bt2020",
        colorTransfer: "arib-std-b67",
        colorMatrix: "bt2020nc",
        containerExtension: "mov"
    )

    public static let rendererTest = ExportProfile(
        profileID: "test_hlg_360p30",
        width: 640,
        height: 360,
        frameRate: 30,
        dynamicRange: "hdr_hlg",
        codec: "hevc_main10",
        colorPrimaries: "bt2020",
        colorTransfer: "arib-std-b67",
        colorMatrix: "bt2020nc",
        containerExtension: "mov"
    )
}

public struct RenderSettings: Codable, Hashable, Sendable {
    public struct TransitionSettings: Codable, Hashable, Sendable {
        public var style: String
        public var durationFrames: Int
        public var fallback: String

        public init(style: String, durationFrames: Int, fallback: String) {
            self.style = style
            self.durationFrames = durationFrames
            self.fallback = fallback
        }
    }

    public struct AudioSettings: Codable, Hashable, Sendable {
        public var gentleLoudnessMatch: Bool
        public var targetLUFS: Double
        public var truePeakCeilingDBTP: Double

        public init(gentleLoudnessMatch: Bool, targetLUFS: Double, truePeakCeilingDBTP: Double) {
            self.gentleLoudnessMatch = gentleLoudnessMatch
            self.targetLUFS = targetLUFS
            self.truePeakCeilingDBTP = truePeakCeilingDBTP
        }
    }

    public struct OverlaySettings: Codable, Hashable, Sendable {
        public var showAgeOverlay: Bool
        public var showQuestionOverlay: Bool

        public init(showAgeOverlay: Bool, showQuestionOverlay: Bool) {
            self.showAgeOverlay = showAgeOverlay
            self.showQuestionOverlay = showQuestionOverlay
        }
    }

    public var answerTransition: TransitionSettings
    public var questionCardTransition: TransitionSettings
    public var audio: AudioSettings
    public var overlays: OverlaySettings
    public var selectedCardSetID: String
    public var selectedOverlayStyleID: String

    public static let `default` = RenderSettings(
        answerTransition: .init(style: "soft_crossfade", durationFrames: 12, fallback: "clean_cut"),
        questionCardTransition: .init(style: "fade_through_black", durationFrames: 12, fallback: "cut"),
        audio: .init(gentleLoudnessMatch: true, targetLUFS: -16.0, truePeakCeilingDBTP: -1.0),
        overlays: .init(showAgeOverlay: true, showQuestionOverlay: false),
        selectedCardSetID: "documentary-paper",
        selectedOverlayStyleID: "age-lower-third-soft"
    )
}

public enum SequenceNodeType: String, Codable, Sendable {
    case openingCard = "opening_card"
    case questionCard = "question_card"
    case answerClip = "answer_clip"
    case closingCard = "closing_card"
}

public struct RenderPlanProjectInfo: Codable, Hashable, Sendable {
    public var projectID: String
    public var projectName: String
    public var manifestPath: String
    public var mediaRoot: String

    public init(projectID: String, projectName: String, manifestPath: String, mediaRoot: String) {
        self.projectID = projectID
        self.projectName = projectName
        self.manifestPath = manifestPath
        self.mediaRoot = mediaRoot
    }
}

public struct RenderPlanText: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String
}

public struct RenderPlanTemplate: Codable, Hashable, Sendable {
    public var templateID: String
    public var durationSeconds: Double
    public var durationSource: String
}

public struct RenderClipRef: Codable, Hashable, Sendable {
    public var clipID: String
    public var clipNumber: String
    public var outputFile: String
    public var resolvedPath: String
}

public struct RenderIdentity: Codable, Hashable, Sendable {
    public var person: String
    public var personKey: String
    public var questionKey: String
    public var questionText: String
    public var age: String
    public var ageKey: String
    public var ageSortKey: Double
}

public struct RenderTiming: Codable, Hashable, Sendable {
    public var answerStartInOutputUS: Int64
    public var answerEndInOutputUS: Int64
    public var realMediaStartInOutputUS: Int64
    public var realMediaEndInOutputUS: Int64
    public var durationUS: Int64
}

public struct RenderHandles: Codable, Hashable, Sendable {
    public var actualHandleBeforeUS: Int64
    public var actualHandleAfterUS: Int64
    public var syntheticHandleBeforeUS: Int64
    public var syntheticHandleAfterUS: Int64
    public var handleBeforeStatus: String
    public var handleAfterStatus: String
    public var syntheticHandleBeforeStatus: String
    public var syntheticHandleAfterStatus: String
}

public struct RenderVideoInfo: Codable, Hashable, Sendable {
    public var sourceIsDolby: Bool
    public var hdrDolbyValidation: String
    public var sourceVideoSignature: ManifestVideoSignature?
    public var outputVideoSignature: ManifestVideoSignature?
}

public struct RenderOverlay: Codable, Hashable, Sendable {
    public var type: String
    public var mode: String
    public var text: String
    public var styleID: String
    public var enabled: Bool?
}

public struct RenderAudioInfo: Codable, Hashable, Sendable {
    public var loudnessMatch: Bool
    public var targetLUFS: Double
    public var truePeakCeilingDBTP: Double
}

public struct RenderSequenceNode: Codable, Hashable, Sendable, Identifiable {
    public var id: String { nodeID }
    public var nodeID: String
    public var type: SequenceNodeType
    public var text: RenderPlanText?
    public var template: RenderPlanTemplate?
    public var questionKey: String?
    public var questionText: String?
    public var clipRef: RenderClipRef?
    public var identity: RenderIdentity?
    public var timing: RenderTiming?
    public var handles: RenderHandles?
    public var video: RenderVideoInfo?
    public var overlays: [RenderOverlay]
    public var audio: RenderAudioInfo?
    public var confidence: Confidence?
    public var issues: [AssemblyIssue]

    public init(
        nodeID: String,
        type: SequenceNodeType,
        text: RenderPlanText?,
        template: RenderPlanTemplate?,
        questionKey: String?,
        questionText: String?,
        clipRef: RenderClipRef?,
        identity: RenderIdentity?,
        timing: RenderTiming?,
        handles: RenderHandles?,
        video: RenderVideoInfo?,
        overlays: [RenderOverlay],
        audio: RenderAudioInfo?,
        confidence: Confidence?,
        issues: [AssemblyIssue]
    ) {
        self.nodeID = nodeID
        self.type = type
        self.text = text
        self.template = template
        self.questionKey = questionKey
        self.questionText = questionText
        self.clipRef = clipRef
        self.identity = identity
        self.timing = timing
        self.handles = handles
        self.video = video
        self.overlays = overlays
        self.audio = audio
        self.confidence = confidence
        self.issues = issues
    }
}

public struct BoundaryTransition: Codable, Hashable, Sendable, Identifiable {
    public struct Requested: Codable, Hashable, Sendable {
        public var style: String
        public var durationFrames: Int
        public var durationUS: Int64
    }

    public struct Resolved: Codable, Hashable, Sendable {
        public var style: String
        public var durationFrames: Int
        public var method: String
        public var fallbackUsed: Bool
    }

    public struct Requirements: Codable, Hashable, Sendable {
        public var outgoingHandleAfterRequiredUS: Int64
        public var incomingHandleBeforeRequiredUS: Int64
    }

    public struct Availability: Codable, Hashable, Sendable {
        public var outgoingRealHandleAfterUS: Int64
        public var incomingRealHandleBeforeUS: Int64
        public var outgoingSyntheticAvailable: Bool
        public var incomingSyntheticAvailable: Bool
    }

    public struct AudioPlan: Codable, Hashable, Sendable {
        public var riskLevel: String
        public var mode: String
        public var quietWindowUS: Int64?
        public var outgoingQuietWindowOffsetUS: Int64?
        public var incomingQuietWindowOffsetUS: Int64?
        public var silenceGapUS: Int64?
        public var reasons: [String]

        public static let notApplicable = AudioPlan(
            riskLevel: "not_applicable",
            mode: "not_applicable",
            quietWindowUS: nil,
            outgoingQuietWindowOffsetUS: nil,
            incomingQuietWindowOffsetUS: nil,
            silenceGapUS: nil,
            reasons: []
        )
    }

    public var id: String { boundaryID }
    public var boundaryID: String
    public var fromNodeID: String
    public var toNodeID: String
    public var boundaryType: String
    public var requested: Requested
    public var resolved: Resolved
    public var requirements: Requirements
    public var availability: Availability
    public var audio: AudioPlan
    public var issues: [AssemblyIssue]
}

public struct RenderPlanSummary: Codable, Hashable, Sendable {
    public struct ConfidenceCounts: Codable, Hashable, Sendable {
        public var high: Int
        public var medium: Int
        public var low: Int

        public init(high: Int, medium: Int, low: Int) {
            self.high = high
            self.medium = medium
            self.low = low
        }
    }

    public struct TransitionCounts: Codable, Hashable, Sendable {
        public var realHandleCrossfade: Int
        public var syntheticCrossfade: Int
        public var cleanCutFallback: Int

        public init(realHandleCrossfade: Int, syntheticCrossfade: Int, cleanCutFallback: Int) {
            self.realHandleCrossfade = realHandleCrossfade
            self.syntheticCrossfade = syntheticCrossfade
            self.cleanCutFallback = cleanCutFallback
        }
    }

    public var questionCount: Int
    public var answerClipCount: Int
    public var estimatedRuntimeSeconds: Double
    public var blockerCount: Int
    public var warningCount: Int
    public var infoCount: Int
    public var confidenceCounts: ConfidenceCounts
    public var transitionCounts: TransitionCounts
    public var exportAllowed: Bool

    public init(
        questionCount: Int,
        answerClipCount: Int,
        estimatedRuntimeSeconds: Double,
        blockerCount: Int,
        warningCount: Int,
        infoCount: Int,
        confidenceCounts: ConfidenceCounts,
        transitionCounts: TransitionCounts,
        exportAllowed: Bool
    ) {
        self.questionCount = questionCount
        self.answerClipCount = answerClipCount
        self.estimatedRuntimeSeconds = estimatedRuntimeSeconds
        self.blockerCount = blockerCount
        self.warningCount = warningCount
        self.infoCount = infoCount
        self.confidenceCounts = confidenceCounts
        self.transitionCounts = transitionCounts
        self.exportAllowed = exportAllowed
    }
}

public struct RenderPlan: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var appName: String
    public var project: RenderPlanProjectInfo
    public var exportProfile: ExportProfile
    public var settings: RenderSettings
    public var sequence: [RenderSequenceNode]
    public var boundaries: [BoundaryTransition]
    public var issues: [AssemblyIssue]
    public var summary: RenderPlanSummary

    public init(
        schemaVersion: String,
        appName: String,
        project: RenderPlanProjectInfo,
        exportProfile: ExportProfile,
        settings: RenderSettings,
        sequence: [RenderSequenceNode],
        boundaries: [BoundaryTransition],
        issues: [AssemblyIssue],
        summary: RenderPlanSummary
    ) {
        self.schemaVersion = schemaVersion
        self.appName = appName
        self.project = project
        self.exportProfile = exportProfile
        self.settings = settings
        self.sequence = sequence
        self.boundaries = boundaries
        self.issues = issues
        self.summary = summary
    }
}
