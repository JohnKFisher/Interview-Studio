import Foundation
#if os(macOS)
import Darwin
#endif

public struct RenderJobState: Sendable {
    public var phase: String
    public var detail: String
    public var completedUnits: Int?
    public var totalUnits: Int?
    public var elapsedSeconds: TimeInterval?
    public var operationElapsedSeconds: TimeInterval?
    public var isHeartbeat: Bool

    public init(
        phase: String,
        detail: String,
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        elapsedSeconds: TimeInterval? = nil,
        operationElapsedSeconds: TimeInterval? = nil,
        isHeartbeat: Bool = false
    ) {
        self.phase = phase
        self.detail = detail
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.elapsedSeconds = elapsedSeconds
        self.operationElapsedSeconds = operationElapsedSeconds
        self.isHeartbeat = isHeartbeat
    }
}

private typealias RenderProcessHeartbeat = @Sendable (TimeInterval) -> Void

private func renderElapsedLabel(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(Int(seconds.rounded(.down)), 0)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainingSeconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func renderHeartbeat(
    phase: String,
    detail: String,
    completedUnits: Int? = nil,
    totalUnits: Int? = nil,
    renderStartedAt: Date,
    progress: @escaping @Sendable (RenderJobState) -> Void
) -> RenderProcessHeartbeat {
    { operationElapsedSeconds in
        progress(
            RenderJobState(
                phase: phase,
                detail: "\(detail) — still running (\(renderElapsedLabel(operationElapsedSeconds)) elapsed)",
                completedUnits: completedUnits,
                totalUnits: totalUnits,
                elapsedSeconds: Date().timeIntervalSince(renderStartedAt),
                operationElapsedSeconds: operationElapsedSeconds,
                isHeartbeat: true
            )
        )
    }
}

public struct RenderResult: Sendable {
    public var outputURL: URL
    public var plexOutputURL: URL?
    public var diagnosticsURL: URL?
    public var plexWarning: String?

    public init(outputURL: URL, plexOutputURL: URL?, diagnosticsURL: URL?, plexWarning: String? = nil) {
        self.outputURL = outputURL
        self.plexOutputURL = plexOutputURL
        self.diagnosticsURL = diagnosticsURL
        self.plexWarning = plexWarning
    }
}

public enum RendererError: LocalizedError {
    case exportBlocked([AssemblyIssue])
    case missingSequenceNode(String)
    case invalidTiming(nodeID: String, message: String)
    case ffmpegPreflightFailed(String)
    case outputPathUnavailable
    case outputAlreadyExists(URL)
    case chunkStreamMismatch(String)
    case chunkDurationMismatch(chunkNumber: Int, expected: Double, observed: Double)
    case renderFailed(message: String, diagnosticsURL: URL?)

    public var errorDescription: String? {
        switch self {
        case .exportBlocked(let issues):
            return issues.map(\.humanMessage).joined(separator: "\n")
        case .missingSequenceNode(let id):
            return "The render plan is missing a required sequence node: \(id)"
        case .invalidTiming(_, let message):
            return message
        case .ffmpegPreflightFailed(let message):
            return message
        case .outputPathUnavailable:
            return "The renderer could not determine a final output path."
        case .outputAlreadyExists(let url):
            return "The renderer will not overwrite an existing output: \(url.path)"
        case .chunkStreamMismatch(let message):
            return message
        case .chunkDurationMismatch(let chunkNumber, let expected, let observed):
            return "Chunk \(chunkNumber) duration mismatch: expected \(format(expected))s, observed \(format(observed))s. The chunk was shortened during assembly; inspect the chunk timing and retry after correcting the reported media/timing issue."
        case .renderFailed(let message, _):
            return message
        }
    }
}

private struct RenderTimingDiagnostic: Codable, Sendable {
    var requestedStartSeconds: Double
    var requestedEndSeconds: Double
    var mediaDurationSeconds: Double
    var frameRate: Double
}

private struct RenderFailureContext: Codable, Sendable {
    var phase: String
    var detail: String
    var nodeID: String?
    var boundaryID: String?
    var timing: RenderTimingDiagnostic?

    init(
        phase: String = "startup",
        detail: String = "Preparing the render.",
        nodeID: String? = nil,
        boundaryID: String? = nil,
        timing: RenderTimingDiagnostic? = nil
    ) {
        self.phase = phase
        self.detail = detail
        self.nodeID = nodeID
        self.boundaryID = boundaryID
        self.timing = timing
    }
}

private struct RenderFailureReport: Codable, Sendable {
    let schemaVersion: Int
    let occurredAt: Date
    let phase: String
    let detail: String
    let nodeID: String?
    let boundaryID: String?
    let timing: RenderTimingDiagnostic?
    let errorCategory: String
    let error: String
    let nextAction: String
    let timeoutSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case occurredAt = "occurred_at"
        case phase
        case detail
        case nodeID = "node_id"
        case boundaryID = "boundary_id"
        case timing
        case errorCategory = "error_category"
        case error
        case nextAction = "next_action"
        case timeoutSeconds = "timeout_seconds"
    }
}

private struct ValidatedAnswerWindow: Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let durationSeconds: Double
}

private struct RenderWorkspaceMarker: Codable {
    let schemaVersion: Int
    let application: String
    let createdAt: Date
    let ownerProcessID: Int32
}

public final class Renderer: @unchecked Sendable {
    private let runner = ProcessRunner()
    private let locator = FFmpegLocator()
    private let preflight = FFmpegPreflight()
    private let inspector = MediaInspector()
    private let outputValidator = RenderOutputValidator()
    private let chunkingPolicy: RenderChunkingPolicy

    // Segment encodes should finish well before a legitimate whole-movie
    // assembly. These are safety limits for a stuck subprocess, not estimates
    // of normal render duration.
    private let segmentProcessTimeout: TimeInterval = 10 * 60
    private let assemblyProcessTimeout: TimeInterval = 45 * 60
    private let plexProcessTimeout: TimeInterval = 15 * 60

    public init() {
        self.chunkingPolicy = RenderChunkingPolicy(targetDurationSeconds: 60)
    }

    init(chunkDurationLimitSeconds: Double) {
        self.chunkingPolicy = RenderChunkingPolicy(targetDurationSeconds: chunkDurationLimitSeconds)
    }

    public func render(
        plan: RenderPlan,
        diagnosticsRoot: URL? = nil,
        outputRoot: URL? = nil,
        outputURL requestedOutputURL: URL? = nil,
        keepSuccessfulDiagnostics: Bool = false,
        progress: @escaping @Sendable (RenderJobState) -> Void
    ) async throws -> RenderResult {
        let renderStartedAt = Date()
        let blockingIssues = plan.issues.filter { $0.severity == .blocker }
        guard blockingIssues.isEmpty else {
            throw RendererError.exportBlocked(blockingIssues)
        }

        try? pruneStaleRenderWorkspaces()
        let workspace = try makeWorkspace(baseURL: diagnosticsRoot)
        var failureContext = RenderFailureContext()
        var stagedOutputURLs: [URL] = []
        defer {
            for url in stagedOutputURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        do {
            failureContext = .init(phase: "preflight", detail: "Saving a redacted copy of the render plan.")
            let planData = try diagnosticPlanData(plan)
            try planData.write(to: workspace.tempRootURL.appendingPathComponent("render_plan.json"))

            failureContext = .init(phase: "preflight", detail: "Locating ffmpeg and verifying required filters/codecs.")
            progress(.init(phase: "preflight", detail: "Locating ffmpeg and verifying required filters/codecs."))
            let preflightResult = try locatePhaseOneFFmpeg(progress: progress)
            let binaries = preflightResult.binaries
            guard let videoEncoder = preflightResult.capabilities.preferredPhaseOneVideoEncoder else {
                throw RendererError.ffmpegPreflightFailed("No Phase 1 HEVC encoder is available. Install FFmpeg with hevc_videotoolbox or libx265, then try again.")
            }
            let outputURL = try finalOutputURL(for: plan, requestedOutputURL: requestedOutputURL, outputRoot: outputRoot)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let timeline = RenderTimeline(frameRate: plan.exportProfile.frameRate)
            let timelineSchedule = timeline.schedule(sequence: plan.sequence, boundaries: plan.boundaries)
            let expectedRenderDuration = timelineSchedule.total

            let answerNodes = plan.sequence.filter { $0.type == .answerClip }
            var inspections: [String: MediaInspectionResult] = [:]
            var answerWindows: [String: ValidatedAnswerWindow] = [:]
            progress(.init(phase: "inspect", detail: "Inspecting source media and validating HDR readiness."))
            for node in answerNodes {
                try Task.checkCancellation()
                guard let clipRef = node.clipRef else { continue }
                let timing = node.timing
                failureContext = .init(
                    phase: "inspect",
                    detail: "Validating answer timing for \(node.nodeID).",
                    nodeID: node.nodeID,
                    timing: timing.map {
                        RenderTimingDiagnostic(
                            requestedStartSeconds: Double($0.answerStartInOutputUS) / 1_000_000,
                            requestedEndSeconds: Double($0.answerEndInOutputUS) / 1_000_000,
                            mediaDurationSeconds: 0,
                            frameRate: 0
                        )
                    }
                )
                let inspection = try inspector.inspect(url: URL(fileURLWithPath: clipRef.resolvedPath), using: binaries)
                inspections[node.nodeID] = inspection
                guard let timing else {
                    throw RendererError.missingSequenceNode(node.nodeID)
                }
                failureContext.timing = RenderTimingDiagnostic(
                    requestedStartSeconds: Double(timing.answerStartInOutputUS) / 1_000_000,
                    requestedEndSeconds: Double(timing.answerEndInOutputUS) / 1_000_000,
                    mediaDurationSeconds: inspection.durationSeconds,
                    frameRate: inspection.frameRate
                )
                answerWindows[node.nodeID] = try validatedAnswerWindow(
                    nodeID: node.nodeID,
                    timing: timing,
                    inspection: inspection,
                    frameRate: plan.exportProfile.frameRate
                )
            }

            let cardSet = BuiltInTemplates.cardSet(id: plan.settings.selectedCardSetID)
            let overlayStyle = BuiltInTemplates.overlayStyle(id: plan.settings.selectedOverlayStyleID)

            progress(.init(phase: "templates", detail: "Rendering native card and overlay assets."))
            let cardAssetPaths = try renderCardAssets(plan: plan, cardSet: cardSet, overlayStyle: overlayStyle, assetsURL: workspace.assetsURL)

            progress(.init(phase: "segments", detail: "Preparing answer segments, cards, and transition clips."))
            let boundaryLookup = Dictionary(uniqueKeysWithValues: plan.boundaries.map { ("\($0.fromNodeID)->\($0.toNodeID)", $0) })
            var currentChunk = RenderChunk(frameRate: plan.exportProfile.frameRate)
            var chunkURLs: [URL] = []
            var chunkIndex = 0
            var transitionIndex = 0
            let transitionTotal = plan.boundaries.filter {
                $0.boundaryType == "answer_to_answer" && $0.resolved.style == "soft_crossfade"
            }.count
            var expectedChunkSignature: ChunkStreamSignature?

            func flushCurrentChunk() throws {
                guard !currentChunk.segmentURLs.isEmpty else { return }
                let chunkURL = workspace.chunksURL.appendingPathComponent(String(format: "chunk-%04d.mov", chunkIndex))
                let chunkNumber = chunkIndex + 1
                let preparedSegmentCount = currentChunk.segmentURLs.count
                let expectedChunkDurationSeconds = currentChunk.durationSeconds
                let expectedChunkFrameCount = currentChunk.frameCount
                let expectedChunkAudioSampleCount = currentChunk.audioSampleCount
                let encoderLabel = videoEncoder == .hevcVideoToolbox ? "hardware HEVC" : "software x265"
                let chunkDetail = "Encoding chunk \(chunkNumber) using \(encoderLabel) from \(preparedSegmentCount) prepared segments."
                failureContext = .init(phase: "assemble", detail: chunkDetail)
                progress(.init(phase: "assemble", detail: chunkDetail, completedUnits: chunkIndex))
                let signature = try assembleChunk(
                    segmentURLs: currentChunk.segmentURLs,
                    outputURL: chunkURL,
                    workspace: workspace,
                    binaries: binaries,
                    videoEncoder: videoEncoder,
                    chunkNumber: chunkNumber,
                    expectedDurationSeconds: expectedChunkDurationSeconds,
                    expectedFrameCount: expectedChunkFrameCount,
                    expectedAudioSampleCount: expectedChunkAudioSampleCount,
                    profile: plan.exportProfile,
                    heartbeat: renderHeartbeat(
                        phase: "assemble",
                        detail: chunkDetail,
                        completedUnits: chunkIndex,
                        renderStartedAt: renderStartedAt,
                        progress: progress
                    )
                )
                try Task.checkCancellation()
                if let expectedChunkSignature, expectedChunkSignature != signature {
                    throw RendererError.chunkStreamMismatch("Chunk \(chunkIndex + 1) does not match the stream parameters of the earlier chunks.")
                }
                expectedChunkSignature = expectedChunkSignature ?? signature
                chunkURLs.append(chunkURL)
                chunkIndex += 1
                currentChunk = RenderChunk(frameRate: plan.exportProfile.frameRate)
            }

            for (index, node) in plan.sequence.enumerated() {
                try Task.checkCancellation()
                let previousBoundary = plan.boundaries.first(where: { $0.toNodeID == node.nodeID })
                let nextBoundary = plan.boundaries.first(where: { $0.fromNodeID == node.nodeID })
                let nextNode = index < plan.sequence.count - 1 ? plan.sequence[index + 1] : nil
                let boundaryAfterNode: BoundaryTransition? = {
                    guard let nextNode,
                          let boundary = boundaryLookup["\(node.nodeID)->\(nextNode.nodeID)"],
                          boundary.boundaryType == "answer_to_answer",
                          boundary.resolved.style == "soft_crossfade" else {
                        return nil
                    }
                    return boundary
                }()
                let nodeDuration = timelineSchedule.duration(for: node)
                let boundaryDuration = boundaryAfterNode.map { timelineSchedule.duration(for: $0) }
                let groupDuration = nodeDuration.seconds + (boundaryDuration?.seconds ?? 0)
                if shouldStartNewChunk(currentDuration: currentChunk.durationSeconds, nextGroupDuration: groupDuration) {
                    try flushCurrentChunk()
                }
                let encoderLabel = videoEncoder == .hevcVideoToolbox ? "hardware HEVC" : "software x265"
                let segmentDetail = "Encoding segment \(index + 1) of \(plan.sequence.count) using \(encoderLabel): \(node.nodeID)"
                failureContext = .init(phase: "segments", detail: segmentDetail, nodeID: node.nodeID)
                progress(.init(
                    phase: "segments",
                    detail: segmentDetail,
                    completedUnits: index,
                    totalUnits: plan.sequence.count
                ))

                switch node.type {
                case .openingCard, .questionCard, .closingCard:
                    let assetURL = cardAssetPaths[node.nodeID]!
                    let outputURL = workspace.segmentsURL.appendingPathComponent("\(node.nodeID).mov")
                    try renderCardSegment(
                        imageURL: assetURL,
                        node: node,
                        previousBoundary: previousBoundary,
                        nextBoundary: nextBoundary,
                        profile: plan.exportProfile,
                        binaries: binaries,
                        duration: nodeDuration,
                        videoEncoder: videoEncoder,
                        outputURL: outputURL,
                        commandLogURL: workspace.commandLogURL,
                        heartbeat: renderHeartbeat(
                            phase: "segments",
                            detail: segmentDetail,
                            completedUnits: index,
                            totalUnits: plan.sequence.count,
                            renderStartedAt: renderStartedAt,
                            progress: progress
                        )
                    )
                    currentChunk.append(segmentURL: outputURL, duration: nodeDuration)
                case .answerClip:
                    let outputURL = workspace.segmentsURL.appendingPathComponent("\(node.nodeID)-core.mov")
                    guard let inspection = inspections[node.nodeID] else {
                        throw RendererError.missingSequenceNode(node.nodeID)
                    }
                    guard let timingWindow = answerWindows[node.nodeID] else {
                        throw RendererError.missingSequenceNode(node.nodeID)
                    }
                    try renderAnswerCoreSegment(
                        node: node,
                        inspection: inspection,
                        timingWindow: timingWindow,
                        duration: nodeDuration,
                        overlayAssetURL: cardAssetPaths["overlay-\(node.nodeID)"],
                        previousBoundary: previousBoundary,
                        nextBoundary: nextBoundary,
                        profile: plan.exportProfile,
                        binaries: binaries,
                        videoEncoder: videoEncoder,
                        outputURL: outputURL,
                        commandLogURL: workspace.commandLogURL,
                        heartbeat: renderHeartbeat(
                            phase: "segments",
                            detail: segmentDetail,
                            completedUnits: index,
                            totalUnits: plan.sequence.count,
                            renderStartedAt: renderStartedAt,
                            progress: progress
                        )
                    )
                    currentChunk.append(segmentURL: outputURL, duration: nodeDuration)
                }

                if let boundary = boundaryAfterNode, let nextNode {
                    try Task.checkCancellation()
                    guard let fromInspection = inspections[node.nodeID],
                          let toInspection = inspections[nextNode.nodeID] else {
                        throw RendererError.missingSequenceNode(boundary.boundaryID)
                    }

                    transitionIndex += 1
                    let transitionDetail = "Encoding transition \(transitionIndex) of \(transitionTotal): \(boundary.boundaryID)"
                    guard let fromWindow = answerWindows[node.nodeID],
                          let toWindow = answerWindows[nextNode.nodeID] else {
                        throw RendererError.missingSequenceNode(boundary.boundaryID)
                    }
                    failureContext = .init(
                        phase: "segments",
                        detail: transitionDetail,
                        nodeID: node.nodeID,
                        boundaryID: boundary.boundaryID,
                        timing: RenderTimingDiagnostic(
                            requestedStartSeconds: fromWindow.startSeconds,
                            requestedEndSeconds: fromWindow.endSeconds,
                            mediaDurationSeconds: fromInspection.durationSeconds,
                            frameRate: fromInspection.frameRate
                        )
                    )
                    progress(.init(
                        phase: "segments",
                        detail: transitionDetail,
                        completedUnits: transitionIndex - 1,
                        totalUnits: transitionTotal
                    ))
                    let transitionURL = workspace.segmentsURL.appendingPathComponent("\(boundary.boundaryID).mov")
                    try renderAnswerTransitionSegment(
                        boundary: boundary,
                        fromNode: node,
                        toNode: nextNode,
                        fromInspection: fromInspection,
                        toInspection: toInspection,
                        fromWindow: fromWindow,
                        toWindow: toWindow,
                        duration: boundaryDuration ?? timelineSchedule.duration(for: boundary),
                        fromOverlayURL: cardAssetPaths["overlay-\(node.nodeID)"],
                        toOverlayURL: cardAssetPaths["overlay-\(nextNode.nodeID)"],
                        profile: plan.exportProfile,
                        binaries: binaries,
                        videoEncoder: videoEncoder,
                        outputURL: transitionURL,
                        commandLogURL: workspace.commandLogURL,
                        heartbeat: renderHeartbeat(
                            phase: "segments",
                            detail: transitionDetail,
                            completedUnits: transitionIndex - 1,
                            totalUnits: transitionTotal,
                            renderStartedAt: renderStartedAt,
                            progress: progress
                        )
                    )
                    currentChunk.append(segmentURL: transitionURL, duration: boundaryDuration ?? timelineSchedule.duration(for: boundary))
                }

                if currentChunk.durationSeconds >= chunkingPolicy.targetDurationSeconds {
                    try flushCurrentChunk()
                }
            }

            try flushCurrentChunk()
            try Task.checkCancellation()
            let finalAssemblyDetail = "Joining \(chunkURLs.count) HEVC chunks into the final movie file."
            failureContext = .init(phase: "assemble", detail: finalAssemblyDetail)
            progress(.init(phase: "assemble", detail: finalAssemblyDetail, completedUnits: chunkURLs.count))
            try writeConcatFile(chunkURLs, to: workspace.concatFileURL)

            let stagedMasterURL = stagingURL(for: outputURL)
            stagedOutputURLs.append(stagedMasterURL)
            try runner.run(
                executableURL: binaries.ffmpegURL,
                arguments: finalAssemblyArguments(
                    concatFileURL: workspace.concatFileURL,
                    outputURL: stagedMasterURL,
                    expectedFrameCount: expectedRenderDuration.frameCount,
                    expectedAudioSampleCount: expectedRenderDuration.audioSampleCount,
                    profile: plan.exportProfile
                ),
                commandLogURL: workspace.commandLogURL,
                heartbeatInterval: 5,
                heartbeat: renderHeartbeat(
                    phase: "assemble",
                    detail: finalAssemblyDetail,
                    completedUnits: chunkURLs.count,
                    renderStartedAt: renderStartedAt,
                    progress: progress
                ),
                timeout: assemblyProcessTimeout
            )
            try Task.checkCancellation()
            let masterInspection = try inspector.inspect(url: stagedMasterURL, using: binaries)
            try outputValidator.validate(
                masterInspection,
                against: plan.exportProfile,
                expectedDurationSeconds: plan.summary.estimatedRuntimeSeconds,
                expectedVideoFrameCount: expectedRenderDuration.frameCount,
                expectedAudioSampleCount: expectedRenderDuration.audioSampleCount,
                requireFinalOutputContract: true
            )
            try Task.checkCancellation()
            try promote(stagedURL: stagedMasterURL, to: outputURL)
            stagedOutputURLs.removeAll { $0 == stagedMasterURL }

            var plexOutputURL: URL?
            var plexWarning: String?
            if let plexMetadata = plan.plexMetadata {
                failureContext = .init(phase: "plex", detail: "Packaging Plex-friendly MP4 companion with metadata and chapters.")
                progress(.init(phase: "plex", detail: "Packaging Plex-friendly MP4 companion with metadata and chapters."))
                do {
                    plexOutputURL = try packagePlexCompanion(
                        plan: plan,
                        plexMetadata: plexMetadata,
                        masterOutputURL: outputURL,
                        workspace: workspace,
                        binaries: binaries,
                        stagedOutputURLs: &stagedOutputURLs,
                        heartbeat: renderHeartbeat(
                            phase: "plex",
                            detail: "Packaging Plex-friendly MP4 companion with metadata and chapters.",
                            renderStartedAt: renderStartedAt,
                            progress: progress
                        )
                    )
                } catch {
                    plexWarning = "Plex companion was not published; the validated HDR master is available. \(error.localizedDescription)"
                    progress(.init(phase: "plex-warning", detail: plexWarning!))
                }
            }

            let diagnosticsURL = keepSuccessfulDiagnostics ? try persistDiagnostics(from: workspace, failure: nil) : nil
            try cleanupTemporaryArtifacts(at: workspace.tempRootURL)

            progress(.init(phase: "done", detail: "Finished rendering \(outputURL.lastPathComponent)."))
            return RenderResult(outputURL: outputURL, plexOutputURL: plexOutputURL, diagnosticsURL: diagnosticsURL, plexWarning: plexWarning)
        } catch is CancellationError {
            try? cleanupTemporaryArtifacts(at: workspace.tempRootURL)
            throw CancellationError()
        } catch {
            let report = makeFailureReport(context: failureContext, error: error)
            let diagnosticsURL = try? persistDiagnostics(from: workspace, failure: report)
            try? cleanupTemporaryArtifacts(at: workspace.tempRootURL)
            let diagnosticsHint = diagnosticsURL.map {
                "Diagnostics saved to \($0.path). Inspect render_failure.json and ffmpeg_commands.txt there."
            } ?? "The diagnostic bundle could not be saved."
            let message = "Render failed during \(failureContext.phase): \(failureContext.detail)\n\(error.localizedDescription)\n\nNext action: \(report.nextAction)\n\(diagnosticsHint)"
            throw RendererError.renderFailed(message: message, diagnosticsURL: diagnosticsURL)
        }
    }

    private func locatePhaseOneFFmpeg(
        progress: @escaping @Sendable (RenderJobState) -> Void
    ) throws -> FFmpegPreflightResult {
        let candidates = locator.candidates()
        guard !candidates.isEmpty else {
            throw RendererError.ffmpegPreflightFailed(
                "Interview Studio could not find an executable ffmpeg/ffprobe pair. Install FFmpeg and FFprobe, then try again."
            )
        }

        var attempts: [String] = []
        for (index, candidate) in candidates.enumerated() {
            progress(
                .init(
                    phase: "preflight",
                    detail: "Checking FFmpeg candidate \(index + 1) of \(candidates.count): \(candidate.sourceDescription)."
                )
            )

            do {
                let result = try preflight.run(using: candidate)
                if result.capabilities.isSufficientForPhaseOne {
                    return result
                }

                let missing = result.capabilities.missingPhaseOneCapabilities.joined(separator: ", ")
                attempts.append("\(candidate.sourceDescription): missing \(missing)")
            } catch {
                attempts.append("\(candidate.sourceDescription): preflight failed (\(error.localizedDescription))")
            }
        }

        let attemptSummary = attempts.isEmpty ? "No usable candidates were found." : attempts.joined(separator: "\n")
        throw RendererError.ffmpegPreflightFailed(
            "Interview Studio found FFmpeg installations, but none provides the capabilities required for Phase 1 rendering (zscale, xfade, acrossfade, overlay, and hevc_videotoolbox or libx265).\n\nChecked:\n\(attemptSummary)\n\nInstall a compatible FFmpeg/FFprobe build, such as Homebrew ffmpeg-full, then try again."
        )
    }

    private func validatedAnswerWindow(
        nodeID: String,
        timing: RenderTiming,
        inspection: MediaInspectionResult,
        frameRate: Double
    ) throws -> ValidatedAnswerWindow {
        let start = Double(timing.answerStartInOutputUS) / 1_000_000
        let requestedEnd = Double(timing.answerEndInOutputUS) / 1_000_000
        let mediaDuration = inspection.durationSeconds

        guard start.isFinite, requestedEnd.isFinite, mediaDuration.isFinite,
              mediaDuration > 0,
              start >= 0,
              requestedEnd > start else {
            throw RendererError.invalidTiming(
                nodeID: nodeID,
                message: "The render plan has an invalid answer window for \(nodeID): start \(format(start))s, end \(format(requestedEnd))s, media duration \(format(mediaDuration))s. Repair or regenerate this manifest row before rendering."
            )
        }

        guard start < mediaDuration,
              requestedEnd <= mediaDuration else {
            throw RendererError.invalidTiming(
                nodeID: nodeID,
                message: "The render plan asks for \(nodeID) from \(format(start))s to \(format(requestedEnd))s, but its inspected output file is only \(format(mediaDuration))s. This is a manifest/media timing mismatch, not an encoding delay. Regenerate the published clip or repair answer_start_in_output_us and answer_end_in_output_us so both timestamps fall inside output_file, then render again."
            )
        }

        let minimumFrameDuration = 1.0 / max(frameRate, 1)
        guard requestedEnd - start >= minimumFrameDuration else {
            throw RendererError.invalidTiming(
                nodeID: nodeID,
                message: "The answer window for \(nodeID) is shorter than one output frame (\(format(requestedEnd - start))s at \(format(frameRate)) fps). Repair or regenerate this manifest row before rendering."
            )
        }

        return ValidatedAnswerWindow(startSeconds: start, endSeconds: requestedEnd, durationSeconds: requestedEnd - start)
    }

    private func makeFailureReport(context: RenderFailureContext, error: Error) -> RenderFailureReport {
        let category: String
        let nextAction: String
        let timeoutSeconds: Double?
        if case let ProcessRunnerError.timedOut(_, timeout, _) = error {
            timeoutSeconds = timeout
        } else {
            timeoutSeconds = nil
        }
        switch error {
        case let error as RendererError:
            switch error {
            case .invalidTiming:
                category = "invalid_manifest_timing"
                nextAction = "Repair or regenerate the named manifest row so its answer timestamps are inside the inspected output file, then retry."
            case .chunkDurationMismatch:
                category = "chunk_duration_mismatch"
                nextAction = "The renderer detected a shortened chunk before final assembly. Review the named chunk and redacted FFmpeg command log; verify the chunk's segment/audio durations, then retry."
            default:
                category = "renderer_error"
                nextAction = "Review the named stage and the redacted FFmpeg command log, then correct the indicated input or tool issue before retrying."
            }
        case is RenderOutputValidationError:
            category = "render_output_validation"
            nextAction = "The rendered media did not satisfy the output contract. Review the named stage and redacted FFmpeg command log; do not publish the output until the reported codec, color, audio, or timing mismatch is corrected."
        case is ProcessRunnerError:
            category = "ffmpeg_process_failure"
            nextAction = "Review the operation detail and ffmpeg_commands.txt. If this was a timeout, verify the source timing and available disk space before retrying."
        case is CancellationError:
            category = "cancelled"
            nextAction = "The render was cancelled; retry after confirming the source project is still available."
        default:
            category = "unexpected_error"
            nextAction = "Review the stage detail and redacted command log, then retry after correcting the reported input or environment problem."
        }

        return RenderFailureReport(
            schemaVersion: 1,
            occurredAt: Date(),
            phase: context.phase,
            detail: context.detail,
            nodeID: context.nodeID,
            boundaryID: context.boundaryID,
            timing: context.timing,
            errorCategory: category,
            error: ProcessRunner.redactDiagnosticText(error.localizedDescription),
            nextAction: nextAction,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func assembleChunk(
        segmentURLs: [URL],
        outputURL: URL,
        workspace: RenderWorkspace,
        binaries: FFmpegBinarySet,
        videoEncoder: PhaseOneVideoEncoder,
        chunkNumber: Int,
        expectedDurationSeconds: Double,
        expectedFrameCount: Int,
        expectedAudioSampleCount: Int,
        profile: ExportProfile,
        heartbeat: RenderProcessHeartbeat?
    ) throws -> ChunkStreamSignature {
        try writeConcatFile(segmentURLs, to: workspace.concatFileURL)
        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: chunkAssemblyArguments(
                concatFileURL: workspace.concatFileURL,
                outputURL: outputURL,
                videoEncoder: videoEncoder,
                expectedFrameCount: expectedFrameCount,
                expectedAudioSampleCount: expectedAudioSampleCount,
                profile: profile
            ),
            commandLogURL: workspace.commandLogURL,
            heartbeatInterval: heartbeat == nil ? nil : 5,
            heartbeat: heartbeat,
            timeout: assemblyProcessTimeout
        )

        let inspection = try inspector.inspect(url: outputURL, using: binaries)
        do {
            try outputValidator.validate(
                inspection,
                against: profile,
                expectedDurationSeconds: expectedDurationSeconds,
                expectedVideoFrameCount: expectedFrameCount,
                expectedAudioSampleCount: expectedAudioSampleCount
            )
        } catch let error as RenderOutputValidationError {
            if case .mismatch(let field, _, _) = error, field == "duration" {
                throw RendererError.chunkDurationMismatch(
                    chunkNumber: chunkNumber,
                    expected: expectedDurationSeconds,
                    observed: inspection.durationSeconds
                )
            }
            throw error
        }
        let signature = ChunkStreamSignature(inspection: inspection)

        for segmentURL in segmentURLs {
            try cleanupTemporaryArtifacts(at: segmentURL)
        }
        return signature
    }

    private func writeConcatFile(_ urls: [URL], to destinationURL: URL) throws {
        let body = urls
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try Data(body.utf8).write(to: destinationURL)
    }

    private func shouldStartNewChunk(currentDuration: Double, nextGroupDuration: Double) -> Bool {
        chunkingPolicy.shouldStartNewChunk(currentDuration: currentDuration, nextGroupDuration: nextGroupDuration)
    }

    private func renderCardAssets(
        plan: RenderPlan,
        cardSet: CardSet,
        overlayStyle: OverlayStyle,
        assetsURL: URL
    ) throws -> [String: URL] {
        var results: [String: URL] = [:]
        let renderer = TemplateRenderer()
        for node in plan.sequence {
            switch node.type {
            case .openingCard, .questionCard, .closingCard:
                let url = assetsURL.appendingPathComponent("\(node.nodeID).png")
                try renderer.renderCardImage(
                    title: node.text?.title ?? node.questionText ?? "",
                    subtitle: node.text?.subtitle ?? "",
                    cardSet: cardSet,
                    profile: plan.exportProfile,
                    destinationURL: url,
                    isQuestionCard: node.type == .questionCard
                )
                results[node.nodeID] = url
            case .answerClip:
                let overlays = node.overlays
                let ageText = overlays.first(where: { $0.type == "age_overlay" })?.text ?? ""
                let questionText = overlays.first(where: { $0.type == "question_overlay" })?.text
                let showQuestion = overlays.first(where: { $0.type == "question_overlay" })?.enabled ?? false
                let url = assetsURL.appendingPathComponent("overlay-\(node.nodeID).png")
                try renderer.renderOverlayImage(
                    ageText: ageText,
                    questionText: questionText,
                    showQuestionText: showQuestion,
                    style: overlayStyle,
                    profile: plan.exportProfile,
                    destinationURL: url
                )
                results["overlay-\(node.nodeID)"] = url
            }
        }
        return results
    }

    private func renderCardSegment(
        imageURL: URL,
        node: RenderSequenceNode,
        previousBoundary: BoundaryTransition?,
        nextBoundary: BoundaryTransition?,
        profile: ExportProfile,
        binaries: FFmpegBinarySet,
        duration: RenderBlockDuration,
        videoEncoder: PhaseOneVideoEncoder,
        outputURL: URL,
        commandLogURL: URL,
        heartbeat: RenderProcessHeartbeat?
    ) throws {
        let durationSeconds = duration.seconds
        let fadeIn = previousBoundary?.resolved.style == "fade_through_black" ? Double(previousBoundary?.resolved.durationFrames ?? 0) / profile.frameRate : 0
        let fadeOut = nextBoundary?.resolved.style == "fade_through_black" ? Double(nextBoundary?.resolved.durationFrames ?? 0) / profile.frameRate : 0

        var videoFilter = [
            "format=rgba",
            "fps=\(format(profile.frameRate))",
            sdrGraphicNormalizeFilter(profile: profile),
            "scale=\(profile.width):\(profile.height):flags=lanczos",
            "setsar=1"
        ]
        if fadeIn > 0 {
            videoFilter.append("fade=t=in:st=0:d=\(format(fadeIn)):color=black")
        }
        if fadeOut > 0 {
            videoFilter.append("fade=t=out:st=\(format(max(durationSeconds - fadeOut, 0))):d=\(format(fadeOut)):color=black")
        }

        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: segmentEncodeArguments(
                inputs: [
                    ["-loop", "1", "-framerate", format(profile.frameRate), "-t", format(durationSeconds), "-i", imageURL.path],
                    ["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"]
                ],
                filterComplex: "[0:v]\(videoFilter.joined(separator: ","))[v];[1:a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[a]",
                mapVideo: "[v]",
                mapAudio: "[a]",
                outputURL: outputURL,
                videoEncoder: videoEncoder,
                profile: profile,
                videoFrameCount: duration.frameCount,
                audioSampleCount: duration.audioSampleCount
            ),
            commandLogURL: commandLogURL,
            heartbeatInterval: heartbeat == nil ? nil : 5,
            heartbeat: heartbeat,
            timeout: segmentProcessTimeout
        )
    }

    private func renderAnswerCoreSegment(
        node: RenderSequenceNode,
        inspection: MediaInspectionResult,
        timingWindow: ValidatedAnswerWindow,
        duration: RenderBlockDuration,
        overlayAssetURL: URL?,
        previousBoundary: BoundaryTransition?,
        nextBoundary: BoundaryTransition?,
        profile: ExportProfile,
        binaries: FFmpegBinarySet,
        videoEncoder: PhaseOneVideoEncoder,
        outputURL: URL,
        commandLogURL: URL,
        heartbeat: RenderProcessHeartbeat?
    ) throws {
        guard let clipRef = node.clipRef else {
            throw RendererError.missingSequenceNode(node.nodeID)
        }

        let durationSeconds = duration.seconds
        let start = timingWindow.startSeconds
        let audioFilter = baseAudioFilter(
            start: start,
            duration: timingWindow.durationSeconds,
            loudnessMatch: node.audio?.loudnessMatch ?? true,
            targetLUFS: node.audio?.targetLUFS ?? -16,
            truePeak: node.audio?.truePeakCeilingDBTP ?? -1
        )

        var videoChain = [
            "trim=start=\(format(start)):duration=\(format(timingWindow.durationSeconds))",
            "setpts=PTS-STARTPTS",
            "fps=\(format(profile.frameRate))",
            colorNormalizeFilter(for: inspection.colorInfo, profile: profile),
            scalePadFilter(profile: profile),
            "setsar=1"
        ]
        if durationSeconds > timingWindow.durationSeconds {
            videoChain.append("tpad=stop_mode=clone:stop_duration=\(format(durationSeconds - timingWindow.durationSeconds))")
        }

        if let previousBoundary, previousBoundary.resolved.style == "fade_through_black" {
            let fadeIn = Double(previousBoundary.resolved.durationFrames) / profile.frameRate
            videoChain.append("fade=t=in:st=0:d=\(format(fadeIn)):color=black")
        }
        if let nextBoundary, nextBoundary.resolved.style == "fade_through_black" {
            let fadeOut = Double(nextBoundary.resolved.durationFrames) / profile.frameRate
            videoChain.append("fade=t=out:st=\(format(max(durationSeconds - fadeOut, 0))):d=\(format(fadeOut)):color=black")
        }

        var inputs: [[String]] = [["-i", clipRef.resolvedPath]]
        var filterComplex = "[0:v]\(videoChain.joined(separator: ","))[v0];"
        if inspection.hasAudio {
            filterComplex += "[0:a]\(audioFilter),apad=whole_dur=\(format(durationSeconds)),atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[a0];"
        } else {
            inputs.append(["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"])
            filterComplex += "[1:a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[a0];"
        }

        var videoMap = "[v0]"
        if let overlayAssetURL {
            inputs.append(["-loop", "1", "-framerate", format(profile.frameRate), "-t", format(durationSeconds), "-i", overlayAssetURL.path])
            let overlayIndex = inputs.count - 1
            filterComplex += "[\(overlayIndex):v]format=rgba[ov];[v0][ov]overlay=0:0:format=auto[v1]"
            videoMap = "[v1]"
        } else {
            filterComplex.removeLast()
        }

        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: segmentEncodeArguments(
                inputs: inputs,
                filterComplex: filterComplex,
                mapVideo: videoMap,
                mapAudio: "[a0]",
                outputURL: outputURL,
                videoEncoder: videoEncoder,
                profile: profile,
                videoFrameCount: duration.frameCount,
                audioSampleCount: duration.audioSampleCount
            ),
            commandLogURL: commandLogURL,
            heartbeatInterval: heartbeat == nil ? nil : 5,
            heartbeat: heartbeat,
            timeout: segmentProcessTimeout
        )
    }

    private func renderAnswerTransitionSegment(
        boundary: BoundaryTransition,
        fromNode: RenderSequenceNode,
        toNode: RenderSequenceNode,
        fromInspection: MediaInspectionResult,
        toInspection: MediaInspectionResult,
        fromWindow: ValidatedAnswerWindow,
        toWindow: ValidatedAnswerWindow,
        duration: RenderBlockDuration,
        fromOverlayURL: URL?,
        toOverlayURL: URL?,
        profile: ExportProfile,
        binaries: FFmpegBinarySet,
        videoEncoder: PhaseOneVideoEncoder,
        outputURL: URL,
        commandLogURL: URL,
        heartbeat: RenderProcessHeartbeat?
    ) throws {
        guard let fromClipRef = fromNode.clipRef,
              let toClipRef = toNode.clipRef else {
            throw RendererError.missingSequenceNode(boundary.boundaryID)
        }

        let durationSeconds = duration.seconds
        let outgoingAvailable = max(Double(boundary.availability.outgoingRealHandleAfterUS) / 1_000_000, 0)
        let incomingAvailable = max(Double(boundary.availability.incomingRealHandleBeforeUS) / 1_000_000, 0)
        let outgoingAnalysisAvailable = max(
            Double((fromNode.handles?.actualHandleAfterUS ?? boundary.availability.outgoingRealHandleAfterUS) + (fromNode.handles?.syntheticHandleAfterUS ?? 0)) / 1_000_000,
            0
        )
        let incomingAnalysisAvailable = max(
            Double((toNode.handles?.actualHandleBeforeUS ?? boundary.availability.incomingRealHandleBeforeUS) + (toNode.handles?.syntheticHandleBeforeUS ?? 0)) / 1_000_000,
            0
        )

        let outgoingMissing = max(durationSeconds - outgoingAvailable, 0)
        let incomingMissing = max(durationSeconds - incomingAvailable, 0)
        let outgoingTrimDuration = max(min(durationSeconds, outgoingAvailable), 0.01)
        let incomingTrimDuration = max(min(durationSeconds, incomingAvailable), 0.01)
        let frameDuration = 1 / max(profile.frameRate, 1)
        // If no real trailing handle exists, use the final decoded frame as
        // the source for synthetic padding. Starting at the exact media end
        // creates an empty trim input, which can leave ffmpeg spinning forever.
        let lastOutgoingFrameStart = max(fromInspection.durationSeconds - frameDuration, 0)
        let outgoingStart = min(fromWindow.endSeconds, lastOutgoingFrameStart)
        let incomingStart = min(
            max(toWindow.startSeconds - incomingTrimDuration, 0),
            max(toInspection.durationSeconds - incomingTrimDuration, 0)
        )
        let outgoingAnalysisDuration = min(
            Double(boundary.requested.durationUS) / 1_000_000,
            outgoingAnalysisAvailable
        )
        let incomingAnalysisDuration = min(
            Double(boundary.requested.durationUS) / 1_000_000,
            incomingAnalysisAvailable
        )
        let outgoingAnalysisStart = fromWindow.endSeconds
        let incomingAnalysisStart = max(toWindow.startSeconds - incomingAnalysisDuration, 0)

        var inputs: [[String]] = [
            ["-i", fromClipRef.resolvedPath],
            ["-i", toClipRef.resolvedPath]
        ]

        var filterParts: [String] = []

        var fromVideo = "[0:v]trim=start=\(format(outgoingStart)):duration=\(format(outgoingTrimDuration)),setpts=PTS-STARTPTS,fps=\(format(profile.frameRate)),\(colorNormalizeFilter(for: fromInspection.colorInfo, profile: profile)),\(scalePadFilter(profile: profile)),setsar=1"
        if outgoingMissing > 0 {
            fromVideo += ",tpad=stop_mode=clone:stop_duration=\(format(outgoingMissing))"
        }
        filterParts.append("\(fromVideo)[fv0]")

        var toVideo = "[1:v]trim=start=\(format(incomingStart)):duration=\(format(incomingTrimDuration)),setpts=PTS-STARTPTS,fps=\(format(profile.frameRate)),\(colorNormalizeFilter(for: toInspection.colorInfo, profile: profile)),\(scalePadFilter(profile: profile)),setsar=1"
        if incomingMissing > 0 {
            toVideo += ",tpad=start_mode=clone:start_duration=\(format(incomingMissing))"
        }
        filterParts.append("\(toVideo)[tv0]")

        var fromVideoMap = "fv0"
        if let fromOverlayURL {
            inputs.append(["-loop", "1", "-framerate", format(profile.frameRate), "-t", format(durationSeconds), "-i", fromOverlayURL.path])
            let index = inputs.count - 1
            filterParts.append("[\(index):v]format=rgba[fov]")
            filterParts.append("[fv0][fov]overlay=0:0:format=auto[fv1]")
            fromVideoMap = "fv1"
        }

        var toVideoMap = "tv0"
        if let toOverlayURL {
            inputs.append(["-loop", "1", "-framerate", format(profile.frameRate), "-t", format(durationSeconds), "-i", toOverlayURL.path])
            let index = inputs.count - 1
            filterParts.append("[\(index):v]format=rgba[tov]")
            filterParts.append("[tv0][tov]overlay=0:0:format=auto[tv1]")
            toVideoMap = "tv1"
        }

        filterParts.append("[\(fromVideoMap)][\(toVideoMap)]xfade=transition=fade:duration=\(format(durationSeconds)):offset=0[vout]")

        let requestedQuietDuration = Double(boundary.audio.quietWindowUS ?? 0) / 1_000_000
        let outgoingQuietOffset = Double(boundary.audio.outgoingQuietWindowOffsetUS ?? -1) / 1_000_000
        let incomingQuietOffset = Double(boundary.audio.incomingQuietWindowOffsetUS ?? -1) / 1_000_000
        let quietWindowIsValid = requestedQuietDuration > 0
            && outgoingQuietOffset >= 0
            && incomingQuietOffset >= 0
            && outgoingQuietOffset + requestedQuietDuration <= outgoingAnalysisDuration + 0.000001
            && incomingQuietOffset + requestedQuietDuration <= incomingAnalysisDuration + 0.000001
            && requestedQuietDuration <= durationSeconds / 2 + 0.000001
        let requestedAudioMode = ["full_crossfade", "quiet_window_bridge", "silence_gap"].contains(boundary.audio.mode)
            ? boundary.audio.mode
            : "silence_gap"
        let audioMode = requestedAudioMode == "quiet_window_bridge" && !quietWindowIsValid ? "silence_gap" : requestedAudioMode
        switch audioMode {
        case "quiet_window_bridge":
            let minimumQuietDuration = 1.0 / 48_000.0
            let quietDuration = min(
                max(requestedQuietDuration, minimumQuietDuration),
                max(durationSeconds / 2, minimumQuietDuration)
            )
            let bridgeDelay = max(durationSeconds - quietDuration, 0)

            if fromInspection.hasAudio {
                let fromAudio = "[0:a]\(baseAudioFilter(start: outgoingAnalysisStart + outgoingQuietOffset, duration: quietDuration, loudnessMatch: false, targetLUFS: fromNode.audio?.targetLUFS ?? -16, truePeak: fromNode.audio?.truePeakCeilingDBTP ?? -1)),volume=0.35,afade=t=out:st=0:d=\(format(quietDuration)),apad=whole_dur=\(format(durationSeconds)),atrim=duration=\(format(durationSeconds))"
                filterParts.append("\(fromAudio)[fa0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[fa0]")
            }

            if toInspection.hasAudio {
                let toAudio = "[1:a]\(baseAudioFilter(start: incomingAnalysisStart + incomingQuietOffset, duration: quietDuration, loudnessMatch: false, targetLUFS: toNode.audio?.targetLUFS ?? -16, truePeak: toNode.audio?.truePeakCeilingDBTP ?? -1)),volume=0.35,afade=t=in:st=0:d=\(format(quietDuration)),adelay=\(Int((bridgeDelay * 1000).rounded()))|\(Int((bridgeDelay * 1000).rounded())),apad=whole_dur=\(format(durationSeconds)),atrim=duration=\(format(durationSeconds))"
                filterParts.append("\(toAudio)[ta0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[ta0]")
            }

            filterParts.append("[fa0][ta0]amix=inputs=2:normalize=0:duration=longest[aout_raw]")
        case "silence_gap":
            inputs.append(["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"])
            let silenceIndex = inputs.count - 1
            filterParts.append("[\(silenceIndex):a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[aout_raw]")
        default:
            if fromInspection.hasAudio {
                var fromAudio = "[0:a]\(baseAudioFilter(start: outgoingStart, duration: outgoingTrimDuration, loudnessMatch: false, targetLUFS: fromNode.audio?.targetLUFS ?? -16, truePeak: fromNode.audio?.truePeakCeilingDBTP ?? -1))"
                if outgoingMissing > 0 {
                    fromAudio += ",apad=whole_dur=\(format(durationSeconds)),atrim=duration=\(format(durationSeconds))"
                }
                filterParts.append("\(fromAudio)[fa0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[fa0]")
            }

            if toInspection.hasAudio {
                var toAudio = "[1:a]\(baseAudioFilter(start: incomingStart, duration: incomingTrimDuration, loudnessMatch: false, targetLUFS: toNode.audio?.targetLUFS ?? -16, truePeak: toNode.audio?.truePeakCeilingDBTP ?? -1))"
                if incomingMissing > 0 {
                    let delayMS = Int((incomingMissing * 1000).rounded())
                    toAudio += ",adelay=\(delayMS)|\(delayMS)"
                }
                toAudio += ",apad=whole_dur=\(format(durationSeconds)),atrim=duration=\(format(durationSeconds))"
                filterParts.append("\(toAudio)[ta0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(durationSeconds), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[ta0]")
            }

            filterParts.append("[fa0][ta0]acrossfade=d=\(format(durationSeconds)):c1=tri:c2=tri[aout_raw]")
        }

        // Normalize every transition output to the same sample clock as the
        // video block. This also removes any short tail introduced by a
        // fade/mix implementation before the segment is concatenated.
        filterParts.append("[aout_raw]aresample=48000:async=0:first_pts=0,apad=whole_dur=\(format(durationSeconds)),atrim=duration=\(format(durationSeconds)),asetpts=PTS-STARTPTS[aout]")

        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: segmentEncodeArguments(
                inputs: inputs,
                filterComplex: filterParts.joined(separator: ";"),
                mapVideo: "[vout]",
                mapAudio: "[aout]",
                outputURL: outputURL,
                videoEncoder: videoEncoder,
                profile: profile,
                videoFrameCount: duration.frameCount,
                audioSampleCount: duration.audioSampleCount
            ),
            commandLogURL: commandLogURL,
            heartbeatInterval: heartbeat == nil ? nil : 5,
            heartbeat: heartbeat,
            timeout: segmentProcessTimeout
        )
    }

    private func segmentEncodeArguments(
        inputs: [[String]],
        filterComplex: String,
        mapVideo: String,
        mapAudio: String,
        outputURL: URL,
        videoEncoder: PhaseOneVideoEncoder,
        profile: ExportProfile,
        videoFrameCount: Int,
        audioSampleCount: Int
    ) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
        for input in inputs {
            args.append(contentsOf: input)
        }
        args.append(contentsOf: [
            "-filter_complex", limitedAudioFilterGraph(filterComplex: filterComplex, mapAudio: mapAudio, sampleCount: audioSampleCount),
            "-map", mapVideo,
            "-map", "[audio_clock]"
        ])
        args.append(contentsOf: videoEncodingArguments(for: videoEncoder))
        args.append(contentsOf: [
            "-c:a", "pcm_s16le",
            "-ar", "48000",
            "-ac", "2",
            "-fps_mode", "cfr",
            "-frames:v", String(videoFrameCount),
            "-colorspace", profile.colorMatrix,
            "-color_primaries", profile.colorPrimaries,
            "-color_trc", profile.colorTransfer,
            outputURL.path
        ])
        return args
    }

    private func videoEncodingArguments(for encoder: PhaseOneVideoEncoder) -> [String] {
        switch encoder {
        case .hevcVideoToolbox:
            // Hardware Main10 keeps the segment/chunk timeline compressed and
            // avoids both the multi-gigabyte ProRes scratch path and the
            // software x265 bottleneck. Disallow silent software fallback so
            // an unavailable hardware encoder fails quickly and diagnostically.
            return [
                "-c:v", "hevc_videotoolbox",
                "-allow_sw", "0",
                "-profile:v", "main10",
                "-pix_fmt", "p010le",
                "-tag:v", "hvc1",
                "-q:v", "70"
            ]
        case .libx265:
            return [
                "-c:v", "libx265",
                "-preset", "faster",
                "-crf", "18",
                "-pix_fmt", "yuv420p10le",
                "-tag:v", "hvc1",
                "-x265-params", "repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"
            ]
        }
    }

    private func chunkAssemblyArguments(
        concatFileURL: URL,
        outputURL: URL,
        videoEncoder: PhaseOneVideoEncoder,
        expectedFrameCount: Int,
        expectedAudioSampleCount: Int,
        profile: ExportProfile
    ) -> [String] {
        var args = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-n",
            "-f", "concat",
            "-safe", "0",
            "-i", concatFileURL.path
        ]
        args.append(contentsOf: videoEncodingArguments(for: videoEncoder))
        args.append(contentsOf: [
            "-c:a", "pcm_s16le",
            "-ar", "48000",
            "-ac", "2",
            "-af", audioSampleLimitFilter(sampleCount: expectedAudioSampleCount, resetPTS: true),
            // Both streams are bounded on their native clocks. Since every
            // input segment uses the same frame/sample grid, the concat
            // demuxer cannot choose a different stream duration at a seam.
            "-fps_mode", "cfr",
            "-frames:v", String(expectedFrameCount),
            "-colorspace", profile.colorMatrix,
            "-color_primaries", profile.colorPrimaries,
            "-color_trc", profile.colorTransfer,
            outputURL.path
        ])
        return args
    }

    private func finalAssemblyArguments(
        concatFileURL: URL,
        outputURL: URL,
        expectedFrameCount: Int,
        expectedAudioSampleCount: Int,
        profile: ExportProfile
    ) -> [String] {
        [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-n",
            "-f", "concat",
            "-safe", "0",
            "-i", concatFileURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0",
            "-c:v", "copy",
            "-tag:v", "hvc1",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", "2",
            "-af", audioSampleLimitFilter(sampleCount: expectedAudioSampleCount, resetPTS: true),
            "-frames:v", String(expectedFrameCount),
            "-movflags", "+faststart",
            "-colorspace", profile.colorMatrix,
            "-color_primaries", profile.colorPrimaries,
            "-color_trc", profile.colorTransfer,
            outputURL.path
        ]
    }

    private func limitedAudioFilterGraph(filterComplex: String, mapAudio: String, sampleCount: Int) -> String {
        let separator = filterComplex.hasSuffix(";") ? "" : ";"
        return filterComplex + separator + "\(mapAudio)\(audioSampleLimitFilter(sampleCount: sampleCount, resetPTS: true))[audio_clock]"
    }

    private func audioSampleLimitFilter(sampleCount: Int, resetPTS: Bool) -> String {
        let ptsFilter = resetPTS ? ",asetpts=N/SR/TB" : ""
        return "aresample=48000:async=0:first_pts=0,atrim=end_sample=\(sampleCount)\(ptsFilter)"
    }

    private func baseAudioFilter(start: Double, duration: Double, loudnessMatch: Bool, targetLUFS: Double, truePeak: Double) -> String {
        var parts = [
            "atrim=start=\(format(start)):duration=\(format(duration))",
            "asetpts=PTS-STARTPTS",
            "aresample=48000:async=0:first_pts=0",
            "aformat=sample_fmts=fltp:channel_layouts=stereo"
        ]
        if loudnessMatch {
            parts.append("loudnorm=I=\(format(targetLUFS)):TP=\(format(truePeak)):LRA=11:linear=true")
            // loudnorm may process at 192 kHz. Return to the render clock
            // before any sample-count limit is applied downstream.
            parts.append("aresample=48000:async=0:first_pts=0")
        }
        parts.append("apad=whole_dur=\(format(duration))")
        parts.append("atrim=duration=\(format(duration))")
        parts.append("asetpts=PTS-STARTPTS")
        return parts.joined(separator: ",")
    }

    private func colorNormalizeFilter(for colorInfo: ColorInfo, profile: ExportProfile) -> String {
        switch colorInfo.transferFlavor {
        case .hlg:
            return "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix)"
        case .pq:
            return "zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix)"
        case .sdr:
            let transferIn = (colorInfo.transferFunction ?? "").lowercased().contains("iec61966") ? "iec61966-2-1" : "bt709"
            let primariesIn = colorInfo.isDisplayP3Like ? "smpte432" : "bt709"
            let sourceClassIsKnown = colorInfo.transferFunction != nil || colorInfo.colorPrimaries != nil
            let creativeAdjustment = sourceClassIsKnown ? ",eq=contrast=1.08" : ""
            let declaredInput = "setparams=colorspace=bt709:color_primaries=\(primariesIn):color_trc=\(transferIn):range=tv"
            return "\(declaredInput),zscale=transferin=\(transferIn):primariesin=\(primariesIn):matrixin=bt709:transfer=linear:rangein=tv,format=gbrpf32le,zscale=transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix):range=tv:npl=400\(creativeAdjustment)"
        }
    }

    private func sdrGraphicNormalizeFilter(profile: ExportProfile) -> String {
        "zscale=transferin=iec61966-2-1:primariesin=bt709:matrixin=bt709:transfer=linear,format=gbrpf32le,zscale=transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix):range=tv:npl=400,eq=contrast=1.04"
    }

    private func scalePadFilter(profile: ExportProfile) -> String {
        "scale=w=\(profile.width):h=\(profile.height):force_original_aspect_ratio=decrease:flags=lanczos,pad=\(profile.width):\(profile.height):(ow-iw)/2:(oh-ih)/2:black"
    }

    private func makeDiagnosticsDirectory(baseURL: URL?) throws -> URL {
        let base = baseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yearly Interview Studio/Diagnostics", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = base.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeWorkspace(baseURL: URL?) throws -> RenderWorkspace {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("YearlyInterviewStudio-Render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let marker = RenderWorkspaceMarker(
            schemaVersion: 1,
            application: "InterviewStudio",
            createdAt: Date(),
            ownerProcessID: ProcessInfo.processInfo.processIdentifier
        )
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: tempBase.appendingPathComponent(".render-workspace"), options: .atomic)
        let persistentBase = baseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yearly Interview Studio/Diagnostics", isDirectory: true)
        let workURL = tempBase.appendingPathComponent("work", isDirectory: true)
        let assetsURL = workURL.appendingPathComponent("assets", isDirectory: true)
        let segmentsURL = workURL.appendingPathComponent("segments", isDirectory: true)
        let chunksURL = workURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: segmentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        return RenderWorkspace(
            tempRootURL: tempBase,
            persistentBaseURL: persistentBase,
            workURL: workURL,
            assetsURL: assetsURL,
            segmentsURL: segmentsURL,
            chunksURL: chunksURL,
            commandLogURL: tempBase.appendingPathComponent("ffmpeg_commands.txt"),
            concatFileURL: tempBase.appendingPathComponent("concat.txt")
        )
    }

    private func pruneStaleRenderWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            guard entry.deletingLastPathComponent().standardizedFileURL == root,
                  entry.lastPathComponent.hasPrefix("YearlyInterviewStudio-Render-") else {
                continue
            }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }

            let markerURL = entry.appendingPathComponent(".render-workspace")
            guard let markerData = try? Data(contentsOf: markerURL),
                  let marker = try? JSONDecoder().decode(RenderWorkspaceMarker.self, from: markerData),
                  marker.schemaVersion == 1,
                  marker.application == "InterviewStudio",
                  marker.createdAt < cutoff else {
                continue
            }

            #if os(macOS)
            // A live owner is allowed to keep its workspace even if the
            // machine clock or a long-running operation makes it look old.
            if kill(marker.ownerProcessID, 0) == 0 { continue }
            #endif
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func diagnosticPlanData(_ plan: RenderPlan) throws -> Data {
        var safePlan = plan
        safePlan.project.manifestPath = "<redacted>"
        safePlan.project.mediaRoot = "<redacted>"
        for index in safePlan.sequence.indices {
            safePlan.sequence[index].clipRef?.resolvedPath = "<redacted>"
        }
        return try JSONEncoder.pretty.encode(safePlan)
    }

    private func stagingURL(for outputURL: URL) -> URL {
        let extensionName = outputURL.pathExtension.isEmpty ? "tmp" : outputURL.pathExtension
        return outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).interviewstudio-staging.\(extensionName)")
    }

    private func promote(stagedURL: URL, to outputURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RendererError.outputPathUnavailable
        }
        try FileManager.default.moveItem(at: stagedURL, to: outputURL)
    }

    private func persistDiagnostics(from workspace: RenderWorkspace, failure: RenderFailureReport?) throws -> URL {
        let destination = try makeDiagnosticsDirectory(baseURL: workspace.persistentBaseURL)
        // Keep failure evidence small and durable. The workspace can contain
        // tens of gigabytes of ProRes segments and generated graphics; those
        // are rebuildable intermediates, not diagnostics.
        let retainedFiles = [
            workspace.tempRootURL.appendingPathComponent("render_plan.json"),
            workspace.commandLogURL
        ]
        for sourceURL in retainedFiles where FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destination.appendingPathComponent(sourceURL.lastPathComponent))
        }
        if let failure {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(failure).write(
                to: destination.appendingPathComponent("render_failure.json"),
                options: .atomic
            )
        }
        return destination
    }

    private func cleanupTemporaryArtifacts(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func finalOutputURL(for plan: RenderPlan, requestedOutputURL: URL?, outputRoot: URL?) throws -> URL {
        if let requestedOutputURL {
            let outputURL = requestedOutputURL.standardizedFileURL
            guard outputURL.pathExtension.lowercased() == plan.exportProfile.containerExtension.lowercased() else {
                throw RendererError.outputPathUnavailable
            }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw RendererError.outputAlreadyExists(outputURL)
            }
            return outputURL
        }

        let root = outputRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Yearly Interview Studio/\(plan.project.projectName)", isDirectory: true)
        let sanitizedBase = sanitizeFilename(plan.project.projectName)
        let defaultURL = root.appendingPathComponent("\(sanitizedBase).\(plan.exportProfile.containerExtension)")
        if !FileManager.default.fileExists(atPath: defaultURL.path) {
            return defaultURL
        }

        let stamp = DateFormatter.outputTimestamp.string(from: Date())
        return root.appendingPathComponent("\(sanitizedBase)-\(stamp).\(plan.exportProfile.containerExtension)")
    }

    private func packagePlexCompanion(
        plan: RenderPlan,
        plexMetadata: PlexMetadataPlan,
        masterOutputURL: URL,
        workspace: RenderWorkspace,
        binaries: FFmpegBinarySet,
        stagedOutputURLs: inout [URL],
        heartbeat: RenderProcessHeartbeat?
    ) throws -> URL {
        let chapterURL = workspace.tempRootURL.appendingPathComponent("plex_chapters.ffmeta")
        try Data(ffmetadataText(for: plexMetadata.chapters).utf8).write(to: chapterURL)

        let outputURL = try plexOutputURL(for: masterOutputURL, metadata: plexMetadata)
        let stagedURL = stagingURL(for: outputURL)
        stagedOutputURLs.append(stagedURL)
        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: plexPackagingArguments(
                plan: plan,
                plexMetadata: plexMetadata,
                masterOutputURL: masterOutputURL,
                chapterMetadataURL: chapterURL,
                outputURL: stagedURL
            ),
            commandLogURL: workspace.commandLogURL,
            heartbeatInterval: heartbeat == nil ? nil : 5,
            heartbeat: heartbeat,
            timeout: plexProcessTimeout
        )
        let inspection = try inspector.inspect(url: stagedURL, using: binaries)
        try outputValidator.validate(inspection, against: plan.exportProfile, expectedDurationSeconds: nil)
        try promote(stagedURL: stagedURL, to: outputURL)
        stagedOutputURLs.removeAll { $0 == stagedURL }
        return outputURL
    }

    private func plexOutputURL(for masterOutputURL: URL, metadata: PlexMetadataPlan) throws -> URL {
        let baseName = sanitizeFilename("\(metadata.show) - \(metadata.episodeID) - \(metadata.episodeTitle)")
        let root = masterOutputURL.deletingLastPathComponent()
        let preferred = root.appendingPathComponent("\(baseName).mp4")
        if !FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        let stamp = DateFormatter.outputTimestamp.string(from: Date())
        return root.appendingPathComponent("\(baseName)-\(stamp).mp4")
    }

    private func plexPackagingArguments(
        plan: RenderPlan,
        plexMetadata: PlexMetadataPlan,
        masterOutputURL: URL,
        chapterMetadataURL: URL,
        outputURL: URL
    ) -> [String] {
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-n",
            "-i", masterOutputURL.path,
            "-f", "ffmetadata",
            "-i", chapterMetadataURL.path,
            "-map_metadata", "-1",
            "-map", "0",
            "-map_chapters", "1",
            "-c", "copy",
            "-tag:v", "hvc1",
            "-movflags", "+faststart",
            "-metadata", "title=\(plexMetadata.episodeTitle)",
            "-metadata", "show=\(plexMetadata.show)",
            "-metadata", "season_number=\(plexMetadata.seasonNumber)",
            "-metadata", "episode_sort=\(plexMetadata.episodeNumber)",
            "-metadata", "episode_id=\(plexMetadata.episodeID)",
            "-metadata", "date=\(plexMetadata.seasonNumber)",
            "-metadata", "description=\(plexMetadata.summary)",
            "-metadata", "synopsis=\(plexMetadata.summary)",
            "-metadata", "comment=\(plexMetadata.summary)",
            "-metadata", "genre=Interview",
            "-metadata", "software=\(plan.appName)",
            "-metadata", "information=\(plan.exportProfile.profileID) Plex companion from HDR master"
        ]

        if let creationTime = inferredPlexCreationTime(for: plan) {
            arguments.append(contentsOf: ["-metadata", "creation_time=\(creationTime)"])
        }

        arguments.append(outputURL.path)
        return arguments
    }

    private func ffmetadataText(for chapters: [RenderChapter]) -> String {
        var lines = [";FFMETADATA1", ""]
        for chapter in chapters {
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000000")
            lines.append("START=\(chapter.startUS)")
            lines.append("END=\(chapter.endUS)")
            lines.append("title=\(escapeFFMetadata(chapter.title))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func escapeFFMetadata(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func sanitizeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }

    private func inferredPlexCreationTime(for plan: RenderPlan) -> String? {
        let fileManager = FileManager.default
        let latestDate = plan.sequence
            .compactMap(\.clipRef?.resolvedPath)
            .compactMap { path -> Date? in
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let modificationDate = attributes[.modificationDate] as? Date else {
                    return nil
                }
                return modificationDate
            }
            .max()

        guard let latestDate else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: latestDate)
    }
}

private struct RenderWorkspace {
    let tempRootURL: URL
    let persistentBaseURL: URL
    let workURL: URL
    let assetsURL: URL
    let segmentsURL: URL
    let chunksURL: URL
    let commandLogURL: URL
    let concatFileURL: URL
}

struct RenderChunkingPolicy: Sendable {
    let targetDurationSeconds: Double

    init(targetDurationSeconds: Double) {
        self.targetDurationSeconds = max(targetDurationSeconds, 0.01)
    }

    func shouldStartNewChunk(currentDuration: Double, nextGroupDuration: Double) -> Bool {
        currentDuration > 0 && currentDuration + nextGroupDuration > targetDurationSeconds
    }
}

private struct RenderChunk {
    var segmentURLs: [URL] = []
    let frameRate: Double
    var frameCount: Int = 0
    var audioSampleCount: Int = 0

    init(frameRate: Double) {
        self.frameRate = frameRate
    }

    var durationSeconds: Double {
        Double(frameCount) / frameRate
    }

    mutating func append(segmentURL: URL, duration: RenderBlockDuration) {
        precondition(duration.frameRate == frameRate)
        segmentURLs.append(segmentURL)
        frameCount += duration.frameCount
        audioSampleCount += duration.audioSampleCount
    }
}

struct ChunkStreamSignature: Equatable {
    let width: Int
    let height: Int
    let frameRate: Double
    let pixFmt: String?
    let colorSpace: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let hasAudio: Bool
    let audioChannels: Int
    let codecName: String?
    let formatName: String?
    let videoProfile: String?
    let videoLevel: Int?
    let videoCodecTag: String?
    let videoTimeBase: String?
    let sampleAspectRatio: String?
    let audioCodecName: String?
    let audioSampleRate: Int?
    let audioSampleFormat: String?
    let audioChannelLayout: String?
    let audioTimeBase: String?
    let streamCount: Int

    init(inspection: MediaInspectionResult) {
        width = inspection.width
        height = inspection.height
        frameRate = inspection.frameRate
        pixFmt = inspection.pixFmt
        colorSpace = inspection.colorSpace
        colorTransfer = inspection.colorTransfer
        colorPrimaries = inspection.colorPrimaries
        hasAudio = inspection.hasAudio
        audioChannels = inspection.audioChannels
        codecName = inspection.codecName
        formatName = inspection.formatName
        videoProfile = inspection.videoProfile
        videoLevel = inspection.videoLevel
        videoCodecTag = inspection.videoCodecTag
        videoTimeBase = inspection.videoTimeBase
        sampleAspectRatio = inspection.sampleAspectRatio
        audioCodecName = inspection.audioCodecName
        audioSampleRate = inspection.audioSampleRate
        audioSampleFormat = inspection.audioSampleFormat
        audioChannelLayout = inspection.audioChannelLayout
        audioTimeBase = inspection.audioTimeBase
        streamCount = inspection.streamCount
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension DateFormatter {
    static let outputTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private func format(_ value: Double) -> String {
    String(format: "%.6f", value)
}
