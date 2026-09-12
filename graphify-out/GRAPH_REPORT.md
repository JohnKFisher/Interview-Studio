# Graph Report - Interview Studio  (2026-09-07)

## Corpus Check
- 59 files · ~119,559 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1248 nodes · 3384 edges · 64 communities (57 shown, 4 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 253 edges (avg confidence: 0.83)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `8ca1f6a2`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Sendable
- AppState
- AssemblyIssue
- CodingKeys
- URL
- TemplateRenderer
- Foundation
- CodingKeys
- .run
- InterviewStudioPackageError
- MediaInspectionResult
- AppDelegate
- KeyedDecodingContainer
- TitleCaseFormatter
- build_and_run.sh
- Package.swift
- MediaAnalysis.swift
- MediaTime
- InterviewSession
- HDR Color Reference For Future Video Apps
- JSONValue
- InterviewStudioPackageStore
- String
- InterviewStudioProject
- SchemaDescriptor
- InterviewStudioWorkspaceModel
- ManifestRow
- MediaInspector.swift
- AnswerPart
- .build
- Decisions
- Yearly Interview Studio — Render Plan Schema
- LocalizedError
- LegacyMigrationAnalysis
- ManifestVideoSignature
- ManifestParserError
- .importRecording
- .replacePlayer
- .body
- ExportProfile
- Final Manifest Field Guide
- Yearly Interview Studio — Codex Build Plan
- Interview Studio
- NewInterviewYearSheet
- DocumentWorkspace.swift
- LegacyRangeRestorer
- PHASE_2_PLAN.md
- .flushToDocument
- Unreleased
- Phase 2 Plan — Clip Factory
- DocumentWorkspaceView
- InterviewStudioPackage.swift
- NativeAnswerPublisher
- Core checklist
- Phase 1 User Flow
- Visual System
- Marker
- Blockers, Warnings, and Info
- Confidence Labels
- Transition System
- SessionLifecycle

## God Nodes (most connected - your core abstractions)
1. `InterviewStudioWorkspaceModel` - 71 edges
2. `CodingKeys` - 61 edges
3. `InterviewSession` - 54 edges
4. `AppState` - 51 edges
5. `JSONValue` - 49 edges
6. `InterviewStudioPackageStore` - 45 edges
7. `RenderSequenceNode` - 43 edges
8. `RenderPlan` - 43 edges
9. `ManifestRow` - 42 edges
10. `Renderer` - 40 edges

## Surprising Connections (you probably didn't know these)
- `drawIcon()` --calls--> `NSColor`  [INFERRED]
  script/generate_app_icon.swift → Sources/Core/Templates/TemplateRenderer.swift
- `.selectedSession` --references--> `InterviewSession`  [INFERRED]
  Sources/App/DocumentWorkspace.swift → Sources/Core/Phase2/InterviewStudioModels.swift
- `.selectedQuestion` --references--> `InterviewStudioProject`  [INFERRED]
  Sources/App/DocumentWorkspace.swift → Sources/Core/Phase2/InterviewStudioModels.swift
- `.selectedAnswer` --references--> `InterviewSession`  [INFERRED]
  Sources/App/DocumentWorkspace.swift → Sources/Core/Phase2/InterviewStudioModels.swift
- `.selectedRecording` --references--> `InterviewSession`  [INFERRED]
  Sources/App/DocumentWorkspace.swift → Sources/Core/Phase2/InterviewStudioModels.swift

## Import Cycles
- None detected.

## Communities (64 total, 4 thin omitted)

### Community 0 - "Sendable"
Cohesion: 0.16
Nodes (38): Codable, Hashable, Sendable, AudioPlan, AudioSettings, Availability, BoundaryTransition, .id (+30 more)

### Community 1 - "AppState"
Cohesion: 0.05
Nodes (34): Commands, AppPreferenceKey, AppState, Bool, Int, Never, Task, Void (+26 more)

### Community 2 - "AssemblyIssue"
Cohesion: 0.06
Nodes (28): ManifestPathResolution, ManifestPathResolver, Bool, LoadedManifestProject, QuestionGroup, .id, QuestionGroupBuilder, ResolvedManifestClip (+20 more)

### Community 3 - "CodingKeys"
Cohesion: 0.04
Nodes (57): CodingKeys, actualHandleAfterUS, actualHandleBeforeUS, age, ageKey, ageRawText, ageSortKey, ageYears (+49 more)

### Community 4 - "URL"
Cohesion: 0.15
Nodes (12): URL, .pathValue, PublicationBuildResult, Renderer, RenderResult, RenderWorkspace, Bool, Data (+4 more)

### Community 5 - "TemplateRenderer"
Cohesion: 0.09
Nodes (29): CGRect, CGSize, NSBitmapImageRep, NSFont, AppPreviewRenderer, Kind, opening, overlay (+21 more)

### Community 6 - "Foundation"
Cohesion: 0.06
Nodes (30): AppKit, AVFoundation, Core, CoreMedia, CryptoKit, Equatable, Foundation, drawIcon() (+22 more)

### Community 7 - "CodingKeys"
Cohesion: 0.08
Nodes (29): CodingKey, Decodable, CodingKeys, codecName, codecType, colorPrimaries, colorSpace, colorTransfer (+21 more)

### Community 8 - ".run"
Cohesion: 0.22
Nodes (9): DataAccumulator, .data, ProcessOutput, ProcessRunner, ProcessRunnerError, .errorDescription, nonZeroExit, Data (+1 more)

### Community 9 - "InterviewStudioPackageError"
Cohesion: 0.16
Nodes (10): CLIError, .errorDescription, invalidOption, missingArgument, missingOption, Int, UUID, YearlyInterviewStudioCLI (+2 more)

### Community 10 - "MediaInspectionResult"
Cohesion: 0.14
Nodes (14): ColorInfo, FFmpegCapabilities, .isSufficientForPhaseOne, .missingPhaseOneCapabilities, MediaInspectionResult, RenderOutputValidator, Bool, Double (+6 more)

### Community 11 - "AppDelegate"
Cohesion: 0.08
Nodes (24): App, Notification, NSApplication, NSApplicationDelegate, NSDocument, NSObject, NSWindowController, Scene (+16 more)

### Community 12 - "KeyedDecodingContainer"
Cohesion: 0.24
Nodes (6): Key, KeyedDecodingContainer, Bool, Double, Int, Int64

### Community 13 - "TitleCaseFormatter"
Cohesion: 0.42
Nodes (3): Bool, Set, TitleCaseFormatter

### Community 16 - "MediaAnalysis.swift"
Cohesion: 0.07
Nodes (37): SFSpeechRecognizerAuthorizationStatus, .selectedTimelineRange, AccessibilityValueFormatter, AudioWaveformAnalyzer, MediaAnalysisError, conversionFailed, emptyAudio, .errorDescription (+29 more)

### Community 17 - "MediaTime"
Cohesion: 0.11
Nodes (22): CMFormatDescription, Comparable, AnswerBoundaryRefiner, AudioAnalysisBuffer, BoundaryRefinementResult, SpeechActivityWindow, Bool, Double (+14 more)

### Community 18 - "InterviewSession"
Cohesion: 0.13
Nodes (16): AnswerTranscript, InterviewAnswer, .selectedTake, InterviewSession, .incompleteQuestionKeys, MigrationRecord, QuestionProgressState, complete (+8 more)

### Community 19 - "HDR Color Reference For Future Video Apps"
Cohesion: 0.06
Nodes (30): 1. Normalize per source type before final assembly, 2. Metadata alone is not enough, 3. Freeze color math after source normalization, 4. Source-type-specific visual review beats theory, Bottom Line, Core Principles, Display P3 Is Not "Basically BT.709", Failure: gain-map still orientation mismatch (+22 more)

### Community 20 - "JSONValue"
Cohesion: 0.10
Nodes (22): MediaSignature, PublicationRecipe, PublicationRecord, RecordingImportSource, finder, legacy, photos, SourceRecording (+14 more)

### Community 21 - "InterviewStudioPackageStore"
Cohesion: 0.16
Nodes (8): incompatible, InterviewStudioPackageStore, .inventoryDigestURL, .inventoryURL, .projectURL, Data, UUID, T

### Community 22 - "String"
Cohesion: 0.10
Nodes (23): CaseIterable, PackageEntryKind, authoritative, derived, documentation, PackageInventory, PackageInventoryEntry, .id (+15 more)

### Community 23 - "InterviewStudioProject"
Cohesion: 0.18
Nodes (10): NSCoder, AssemblySettings, InterviewPerson, InterviewQuestion, .compatibility, InterviewStudioProject, .activeQuestions, .compatibility (+2 more)

### Community 24 - "SchemaDescriptor"
Cohesion: 0.11
Nodes (18): InterviewStudioCompatibilityError, .errorDescription, invalid, readOnly, upgradeRequired, InterviewStudioFeature, InterviewStudioSchema, SchemaCompatibility (+10 more)

### Community 25 - "InterviewStudioWorkspaceModel"
Cohesion: 0.14
Nodes (14): .markerControls, InterviewStudioWorkspaceModel, .canTranscribeSelectedRecording, .isLegacyImport, .mediaAnalysisID, .selectedAnswer, .selectedAnswerPart, .selectedQuestion (+6 more)

### Community 26 - "ManifestRow"
Cohesion: 0.18
Nodes (17): ManifestParserConfidence, high, low, medium, ManifestRow, .answerDurationUS, .id, .isHDRLike (+9 more)

### Community 27 - "MediaInspector.swift"
Cohesion: 0.18
Nodes (9): FFmpegBinarySet, FFmpegLocator, FFmpegPreflight, FFmpegPreflightResult, MediaInspectionError, .errorDescription, invalidVideoMetadata, missingVideo (+1 more)

### Community 28 - "AnswerPart"
Cohesion: 0.21
Nodes (12): Identifiable, AnswerPart, AnswerReviewState, inProgress, needsReview, reviewed, unreviewed, AnswerTake (+4 more)

### Community 29 - ".build"
Cohesion: 0.18
Nodes (14): NativeMediaInspection, Bool, Double, Int, NativePublishingError, .errorDescription, exportFailed, manifestBlocked (+6 more)

### Community 30 - "Decisions"
Cohesion: 0.12
Nodes (16): 2026-05-03 - Detach renderer subprocesses from terminal stdin, 2026-05-03 - Lock Phase 1 exports to one HDR profile, 2026-05-03 - Phase 1 is a SwiftPM-first macOS Assembly Studio, 2026-05-03 - Publish the project as a GitHub repository, 2026-05-03 - Use ProRes intermediates and a final HEVC assembly encode, 2026-05-06 - Move render inspectors into separate windows and add live style previews, 2026-05-06 - Prefer conservative transition audio over leaked handle speech, 2026-05-07 - Default Title Case and default-on Plex metadata for sidecar-backed projects (+8 more)

### Community 31 - "Yearly Interview Studio — Render Plan Schema"
Cohesion: 0.12
Nodes (16): Answer Clip, Boundary Transition Object, Clip-level Blockers, Closing Card, Initial Validation Rules, Issue Object, Manifest-level Blockers, Notes for Codex (+8 more)

### Community 32 - "LocalizedError"
Cohesion: 0.12
Nodes (16): LocalizedError, FFmpegLocatorError, binariesMissing, .errorDescription, RenderOutputValidationError, .errorDescription, mismatch, DateFormatter (+8 more)

### Community 33 - "LegacyMigrationAnalysis"
Cohesion: 0.21
Nodes (11): LegacyImportResult, LegacyMigrationAnalysis, .canImport, LegacyMigrationFinding, LegacyMigrationSeverity, blocker, info, warning (+3 more)

### Community 34 - "ManifestVideoSignature"
Cohesion: 0.15
Nodes (11): Entry, ManifestVideoSignature, .codecName, .colorPrimaries, .colorRange, .colorSpace, .colorTransfer, .isHDRLike (+3 more)

### Community 35 - "ManifestParserError"
Cohesion: 0.18
Nodes (7): ManifestParser, ManifestParserError, .errorDescription, invalidJSON, noUsableClips, topLevelNotArray, LegacyMigrationService

### Community 36 - ".importRecording"
Cohesion: 0.20
Nodes (7): checksumMismatch, fileExists, invalidPackage, inventoryMismatch, unsafeRelativePath, sha256(), Int

### Community 37 - ".replacePlayer"
Cohesion: 0.21
Nodes (7): AVPlayer, AVPlayerView, Context, NSViewRepresentable, AVPlayerContainer, PlayerObservationLifetime, Any

### Community 38 - ".body"
Cohesion: 0.24
Nodes (5): CMTime, RecordingPlayer, .body, .recordingURL, Int64

### Community 39 - "ExportProfile"
Cohesion: 0.33
Nodes (4): format(), missingSequenceNode, Double, ExportProfile

### Community 40 - "Final Manifest Field Guide"
Cohesion: 0.17
Nodes (11): Core Identity Fields, Final Manifest Field Guide, Output Fields, Recommended Assembly-App Interpretation, Review And Parser Fields, `source_parts` Entry Fields, Source Provenance Fields, Synthetic Freeze-Frame Padding (+3 more)

### Community 41 - "Yearly Interview Studio — Codex Build Plan"
Cohesion: 0.17
Nodes (12): Audio System, Build Order, Color and HDR System, Immediate Codex Task, Missing Ages, Modules, Non-Negotiable Product Philosophy, Phase 2 Architectural Hooks (+4 more)

### Community 42 - "Interview Studio"
Cohesion: 0.17
Nodes (12): AI Assistance, Building And Running, CLI, Current Limits, Current Strengths, Interview Studio, Notes On Packaging, Project Status (+4 more)

### Community 43 - "NewInterviewYearSheet"
Cohesion: 0.24
Nodes (8): ObservableObject, .body, NewInterviewYearDraft, NewInterviewYearSheet, .body, .parsedAge, Double, Void

### Community 44 - "DocumentWorkspace.swift"
Cohesion: 0.29
Nodes (8): AVKit, .missingTranscriptionSummary, MissingTranscriptionPlan, Int, UUID, TranscriptionBatchSummary, .confirmationMessage, TranscriptionCandidate

### Community 46 - "PHASE_2_PLAN.md"
Cohesion: 0.25
Nodes (4): FFmpeg and FFprobe, Interview Studio, Third-Party Attributions, Interview Studio

### Community 48 - "Unreleased"
Cohesion: 0.25
Nodes (7): Added, Changed, Fixed, Internal / Maintenance, Reliability / Data Safety, Unreleased, Working Changelog

### Community 49 - "Phase 2 Plan — Clip Factory"
Cohesion: 0.29
Nodes (7): Current implementation snapshot — 2026-08-07, Definition of done, Explicit non-goals for the initial Phase 2 slice, Open decisions before implementation, Phase 2 outcome, Phase 2 Plan — Clip Factory, Supporting work that may belong in Phase 2

### Community 50 - "DocumentWorkspaceView"
Cohesion: 0.29
Nodes (6): AssemblySummaryView, .body, DocumentWorkspaceView, .answerStatus, .editor, .projectSidebar

### Community 51 - "InterviewStudioPackage.swift"
Cohesion: 0.29
Nodes (5): ImportedRecording, JSONDecoder, .interviewStudio, JSONEncoder, .interviewStudio

### Community 52 - "NativeAnswerPublisher"
Cohesion: 0.48
Nodes (3): FinishAndLockService, ManifestPublicationBuilder, NativeAnswerPublisher

### Community 53 - "Core checklist"
Cohesion: 0.33
Nodes (6): 1. Define the Clip Factory workflow, 2. Build source-media review, 3. Create answer clips, 4. Create and maintain the manifest, 5. Connect the handoff to Phase 1, Core checklist

### Community 54 - "Phase 1 User Flow"
Cohesion: 0.40
Nodes (5): 1. Import / Setup, 2. Assembly Screen, 3. Render Plan Preview, 4. Render, Phase 1 User Flow

### Community 55 - "Visual System"
Cohesion: 0.40
Nodes (5): Age Overlay, Opening Card, Question Card, Question Overlay During Answers, Visual System

### Community 56 - "Marker"
Cohesion: 0.40
Nodes (5): Marker, end, noResume, resume, start

### Community 57 - "Blockers, Warnings, and Info"
Cohesion: 0.50
Nodes (4): Blockers, Blockers, Warnings, and Info, Info, Warnings

### Community 58 - "Confidence Labels"
Cohesion: 0.50
Nodes (4): Confidence Labels, High Confidence, Low Confidence, Medium Confidence

### Community 59 - "Transition System"
Cohesion: 0.50
Nodes (4): Global Answer Transition, Question Card Transitions, Transition Strategy, Transition System

### Community 60 - "SessionLifecycle"
Cohesion: 0.67
Nodes (3): SessionLifecycle, locked, open

## Knowledge Gaps
- **354 isolated node(s):** `PackageDescription`, `AppPreferenceKey`, `.body`, `.statusChip`, `AVKit` (+349 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 440 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `String` connect `String` to `Sendable`, `AppState`, `AssemblyIssue`, `CodingKeys`, `URL`, `TemplateRenderer`, `Foundation`, `CodingKeys`, `.run`, `InterviewStudioPackageError`, `MediaInspectionResult`, `AppDelegate`, `KeyedDecodingContainer`, `TitleCaseFormatter`, `MediaAnalysis.swift`, `MediaTime`, `InterviewSession`, `JSONValue`, `InterviewStudioPackageStore`, `InterviewStudioProject`, `SchemaDescriptor`, `InterviewStudioWorkspaceModel`, `ManifestRow`, `MediaInspector.swift`, `AnswerPart`, `.build`, `LocalizedError`, `LegacyMigrationAnalysis`, `ManifestVideoSignature`, `ManifestParserError`, `.importRecording`, `.body`, `ExportProfile`, `NewInterviewYearSheet`, `DocumentWorkspace.swift`, `LegacyRangeRestorer`, `SessionLifecycle`?**
  _High betweenness centrality (0.381) - this node is a cross-community bridge._
- **Why does `URL` connect `URL` to `AppState`, `AssemblyIssue`, `TemplateRenderer`, `Foundation`, `.run`, `InterviewStudioPackageError`, `MediaInspectionResult`, `AppDelegate`, `MediaAnalysis.swift`, `MediaTime`, `InterviewStudioPackageStore`, `String`, `InterviewStudioProject`, `InterviewStudioWorkspaceModel`, `MediaInspector.swift`, `.build`, `LocalizedError`, `LegacyMigrationAnalysis`, `ManifestParserError`, `.importRecording`, `.replacePlayer`, `.body`, `ExportProfile`, `DocumentWorkspace.swift`, `LegacyRangeRestorer`?**
  _High betweenness centrality (0.073) - this node is a cross-community bridge._
- **Why does `InterviewStudioWorkspaceModel` connect `InterviewStudioWorkspaceModel` to `URL`, `.replacePlayer`, `.body`, `NewInterviewYearSheet`, `DocumentWorkspace.swift`, `AppDelegate`, `.flushToDocument`, `MediaAnalysis.swift`, `DocumentWorkspaceView`, `InterviewSession`, `JSONValue`, `String`, `InterviewStudioProject`, `Marker`, `AnswerPart`?**
  _High betweenness centrality (0.072) - this node is a cross-community bridge._
- **What connects `PackageDescription`, `AppPreferenceKey`, `.body` to the rest of the system?**
  _354 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `AppState` be split into smaller, more focused modules?**
  _Cohesion score 0.05393000573723465 - nodes in this community are weakly interconnected._
- **Should `AssemblyIssue` be split into smaller, more focused modules?**
  _Cohesion score 0.062206572769953054 - nodes in this community are weakly interconnected._
- **Should `CodingKeys` be split into smaller, more focused modules?**
  _Cohesion score 0.03508771929824561 - nodes in this community are weakly interconnected._