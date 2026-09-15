import AVFoundation
import Foundation

public enum NativePublishingError: LocalizedError, Sendable {
    case sessionMustBeOpenOrLocked
    case missingSelectedTake(String)
    case unsupportedMultiPart(String)
    case sourceMissing(String)
    case exportFailed(String)
    case outputAlreadyExists(URL)
    case outputProfileMismatch(String)
    case manifestBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .sessionMustBeOpenOrLocked: return "The session cannot be published in its current lifecycle state."
        case .missingSelectedTake(let key): return "Question \(key) has no selected answer take."
        case .unsupportedMultiPart(let key): return "Multi-part answer \(key) requires the Phase 2 compositor and cannot be published by this pass."
        case .sourceMissing(let path): return "The selected source recording is missing: \(path)"
        case .exportFailed(let message): return "Native answer export failed: \(message)"
        case .outputAlreadyExists(let url): return "The answer output already exists and was not overwritten: \(url.path)"
        case .outputProfileMismatch(let message): return "Native answer output did not meet the protected publication profile: \(message)"
        case .manifestBlocked(let message): return "The generated manifest is blocked: \(message)"
        }
    }
}

public struct PublicationBuildResult: Sendable {
    public var publication: PublicationRecord
    public var buildRoot: URL
    public var manifestURL: URL
    public var rows: [ManifestRow]
    public var renderPlan: RenderPlan
    /// The session state produced by finish-and-lock, when this result came
    /// from that operation. It is returned to the document layer so the
    /// document, rather than the background service, owns package persistence.
    public var stagedSession: InterviewSession?

    public init(publication: PublicationRecord, buildRoot: URL, manifestURL: URL, rows: [ManifestRow], renderPlan: RenderPlan, stagedSession: InterviewSession? = nil) {
        self.publication = publication
        self.buildRoot = buildRoot
        self.manifestURL = manifestURL
        self.rows = rows
        self.renderPlan = renderPlan
        self.stagedSession = stagedSession
    }
}

public struct NativeAnswerPublisher: Sendable {
    public let recipe: PublicationRecipe

    public init(recipe: PublicationRecipe = .phaseTwoDefault) {
        self.recipe = recipe
    }

    public func generate(part: AnswerPart, sourceURL: URL, outputURL: URL) async throws -> NativeMediaInspection {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NativePublishingError.outputAlreadyExists(outputURL)
        }
        guard let boundaries = part.refinedBoundaries ?? refinedFallback(for: part.rawMarkers) else {
            throw NativePublishingError.exportFailed("The answer has no usable boundaries.")
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NativePublishingError.sourceMissing(sourceURL.path)
        }
        let start = CMTime(value: boundaries.safeLeadingStart.value, timescale: boundaries.safeLeadingStart.timescale)
        let end = CMTime(value: boundaries.safeTrailingEnd.value, timescale: boundaries.safeTrailingEnd.timescale)
        let duration = CMTimeSubtract(end, start)
        guard duration.isNumeric, duration > .zero else { throw NativePublishingError.exportFailed("The selected range is empty.") }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativePublishingError.exportFailed("Could not create composition tracks.")
        }
        let range = CMTimeRange(start: start, duration: duration)
        do {
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
            try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        } catch {
            throw NativePublishingError.exportFailed(error.localizedDescription)
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preset = AVAssetExportPresetHEVC3840x2160
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NativePublishingError.exportFailed("The system does not provide \(preset).")
        }
        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).interviewstudio-staging.mov")
        defer {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }
        exporter.shouldOptimizeForNetworkUse = false
        do {
            try await exporter.export(to: stagedURL, as: .mov)
        } catch {
            throw NativePublishingError.exportFailed(error.localizedDescription)
        }
        let inspection = try await validate(outputURL: stagedURL, expectedDuration: duration, sourceURL: sourceURL)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NativePublishingError.outputAlreadyExists(outputURL)
        }
        try FileManager.default.moveItem(at: stagedURL, to: outputURL)
        return inspection
    }

    /// Publishes a recording-first candidate. Retained pieces are joined in a
    /// composition; adjacent pieces receive a short audio/video crossfade so
    /// an internal cut does not create a hard discontinuity.
    public func generate(candidate: AnswerCandidate, sourceURL: URL, outputURL: URL) async throws -> NativeMediaInspection {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NativePublishingError.outputAlreadyExists(outputURL)
        }
        let timeline = RecordingFirstWorkflow.publicationTimeline(for: candidate)
        guard !timeline.placements.isEmpty else {
            throw NativePublishingError.exportFailed("The answer has no usable retained segments.")
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NativePublishingError.sourceMissing(sourceURL.path)
        }
        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.isNumeric, sourceDuration > .zero else {
            throw NativePublishingError.sourceMissing(sourceURL.path)
        }
        let naturalSize = try await sourceVideo.load(.naturalSize)

        let composition = AVMutableComposition()
        let trackCount = timeline.placements.count > 1 ? 2 : 1
        let videoTracks = try (0..<trackCount).map { _ in
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NativePublishingError.exportFailed("Could not create composition video tracks.")
            }
            return track
        }
        let audioTracks = try (0..<trackCount).map { _ in
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NativePublishingError.exportFailed("Could not create composition audio tracks.")
            }
            return track
        }
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let renderTransform = try compositionTransform(for: naturalSize, preferredTransform: preferredTransform)
        // Render orientation and fit explicitly in the compositor. Leaving the
        // source transform only on the composition track lets AVFoundation
        // preserve metadata while still placing a smaller source in the
        // upper-left of the configured 4K canvas.
        videoTracks.forEach { $0.preferredTransform = .identity }

        struct Placement {
            let start: CMTime
            let end: CMTime
            let trackIndex: Int
        }
        var placements: [Placement] = []
        for (index, timelinePlacement) in timeline.placements.enumerated() {
            let segment = timelinePlacement.sourceSegment
            let start = CMTime(value: segment.start.value, timescale: segment.start.timescale)
            let end = CMTime(value: segment.end.value, timescale: segment.end.timescale)
            let duration = CMTimeSubtract(end, start)
            guard duration.isNumeric, duration > .zero, start >= .zero, end <= sourceDuration else {
                throw NativePublishingError.exportFailed("A retained segment lies outside the source recording.")
            }
            let insertionTime = CMTime(value: timelinePlacement.outputStart.value, timescale: timelinePlacement.outputStart.timescale)
            let range = CMTimeRange(start: start, duration: duration)
            let trackIndex = index % trackCount
            do {
                try videoTracks[trackIndex].insertTimeRange(range, of: sourceVideo, at: insertionTime)
                try audioTracks[trackIndex].insertTimeRange(range, of: sourceAudio, at: insertionTime)
            } catch {
                throw NativePublishingError.exportFailed(error.localizedDescription)
            }
            let endTime = CMTimeAdd(insertionTime, duration)
            placements.append(Placement(start: insertionTime, end: endTime, trackIndex: trackIndex))
        }

        let outputDuration = composition.duration
        guard outputDuration.isNumeric, outputDuration > .zero else {
            throw NativePublishingError.exportFailed("The composed answer is empty.")
        }

        let videoComposition: AVMutableVideoComposition?
        let audioMix: AVMutableAudioMix?
        if !placements.isEmpty {
            let inputParameters = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
            inputParameters.forEach { $0.setVolume(1, at: .zero) }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: outputDuration)
            let layers = videoTracks.map { AVMutableVideoCompositionLayerInstruction(assetTrack: $0) }
            layers.forEach {
                $0.setTransform(renderTransform, at: .zero)
                $0.setOpacity(0, at: .zero)
            }
            for (placementIndex, placement) in placements.enumerated() {
                let layer = layers[placement.trackIndex]
                if placementIndex == 0 {
                    layer.setOpacity(1, at: .zero)
                    inputParameters[placement.trackIndex].setVolume(1, at: .zero)
                } else {
                    let previous = placements[placementIndex - 1]
                    let overlapStart = placement.start
                    let overlapEnd = min(previous.end, placement.end)
                    let overlapDuration = CMTimeSubtract(overlapEnd, overlapStart)
                    if overlapDuration > .zero {
                        let overlap = CMTimeRange(start: overlapStart, duration: overlapDuration)
                        layer.setOpacity(0, at: overlapStart)
                        layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: overlap)
                        inputParameters[placement.trackIndex].setVolume(0, at: overlapStart)
                        inputParameters[placement.trackIndex].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: overlap)
                    } else {
                        layer.setOpacity(1, at: placement.start)
                        inputParameters[placement.trackIndex].setVolume(1, at: placement.start)
                    }
                }
                if placementIndex + 1 < placements.count {
                    let next = placements[placementIndex + 1]
                    let overlapStart = next.start
                    let overlapEnd = min(placement.end, next.end)
                    let overlapDuration = CMTimeSubtract(overlapEnd, overlapStart)
                    if overlapDuration > .zero {
                        let overlap = CMTimeRange(start: overlapStart, duration: overlapDuration)
                        layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: overlap)
                        inputParameters[placement.trackIndex].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: overlap)
                    }
                }
            }
            instruction.layerInstructions = layers.reversed()
            let instructions = [instruction]
            let configuredVideo = AVMutableVideoComposition()
            configuredVideo.renderSize = CGSize(width: recipe.width, height: recipe.height)
            configuredVideo.frameDuration = CMTime(value: 1, timescale: CMTimeScale(recipe.frameRate))
            configuredVideo.instructions = instructions
            videoComposition = configuredVideo
            let configuredAudio = AVMutableAudioMix()
            configuredAudio.inputParameters = inputParameters
            audioMix = configuredAudio
        } else {
            videoComposition = nil
            audioMix = nil
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preset = AVAssetExportPresetHEVC3840x2160
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NativePublishingError.exportFailed("The system does not provide \(preset).")
        }
        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).interviewstudio-staging.mov")
        defer {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }
        exporter.shouldOptimizeForNetworkUse = false
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        do {
            try await exporter.export(to: stagedURL, as: .mov)
        } catch {
            throw NativePublishingError.exportFailed(error.localizedDescription)
        }
        let inspection = try await validate(outputURL: stagedURL, expectedDuration: outputDuration, sourceURL: sourceURL)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NativePublishingError.outputAlreadyExists(outputURL)
        }
        try FileManager.default.moveItem(at: stagedURL, to: outputURL)
        return inspection
    }

    private func compositionTransform(for naturalSize: CGSize, preferredTransform: CGAffineTransform) throws -> CGAffineTransform {
        let naturalRect = CGRect(origin: .zero, size: naturalSize)
        let orientedRect = naturalRect.applying(preferredTransform)
        let orientedWidth = abs(orientedRect.width)
        let orientedHeight = abs(orientedRect.height)
        guard orientedWidth.isFinite, orientedHeight.isFinite, orientedWidth > 0, orientedHeight > 0 else {
            throw NativePublishingError.exportFailed("The source video has no usable dimensions.")
        }
        let scale = min(CGFloat(recipe.width) / orientedWidth, CGFloat(recipe.height) / orientedHeight)
        let renderedWidth = orientedWidth * scale
        let renderedHeight = orientedHeight * scale
        let translation = CGAffineTransform(
            translationX: (CGFloat(recipe.width) - renderedWidth) / 2 - orientedRect.minX * scale,
            y: (CGFloat(recipe.height) - renderedHeight) / 2 - orientedRect.minY * scale
        )
        let scaling = CGAffineTransform(scaleX: scale, y: scale)
        let normalization = CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
        return translation
            .concatenating(scaling)
            .concatenating(normalization)
            .concatenating(preferredTransform)
    }

    private func refinedFallback(for markers: RawAnswerMarkers) -> RefinedBoundaries? {
        guard let start = markers.answerStart, let end = markers.answerEnd, end > start else { return nil }
        return RefinedBoundaries(visibleStart: start, visibleEnd: end, safeLeadingStart: start, safeTrailingEnd: end, confidence: 0.4, reasons: ["Native fallback used raw markers."], algorithmIdentifier: "raw-marker-fallback", algorithmVersion: "1.0")
    }

    private func validate(outputURL: URL, expectedDuration: CMTime, sourceURL: URL) async throws -> NativeMediaInspection {
        let inspection: NativeMediaInspection
        do {
            inspection = try await NativeMediaInspector().inspect(url: outputURL)
        } catch {
            throw NativePublishingError.outputProfileMismatch(error.localizedDescription)
        }
        guard inspection.hasVideo, inspection.hasAudio, inspection.audioChannels > 0 else {
            throw NativePublishingError.outputProfileMismatch("The validated output must contain both video and audio.")
        }
        guard inspection.width == recipe.width, inspection.height == recipe.height else {
            throw NativePublishingError.outputProfileMismatch("Expected \(recipe.width)x\(recipe.height), got \(inspection.width)x\(inspection.height).")
        }
        guard abs(inspection.nominalFrameRate - Double(recipe.frameRate)) <= 1 else {
            throw NativePublishingError.outputProfileMismatch("Expected \(recipe.frameRate) fps, got \(inspection.nominalFrameRate).")
        }
        let expectedDurationUS = Int64((expectedDuration.seconds * 1_000_000).rounded())
        let durationToleranceUS = max(50_000, Int64((2_000_000.0 / Double(recipe.frameRate)).rounded()))
        guard abs(inspection.duration.microseconds - expectedDurationUS) <= durationToleranceUS else {
            throw NativePublishingError.outputProfileMismatch("Expected approximately \(expectedDurationUS) microseconds, got \(inspection.duration.microseconds).")
        }

        // Native answer clips are intermediate media: the final renderer owns
        // source-aware SDR-to-HLG normalization and strict Main10 validation.
        // Still, the answer publication boundary must prove that AVFoundation
        // produced HEVC media and did not silently lose an explicitly HDR
        // source profile.
        do {
            let binaries = try FFmpegLocator().locate()
            let outputProbe = try MediaInspector().inspect(url: outputURL, using: binaries)
            guard outputProbe.codecName?.localizedCaseInsensitiveContains("hevc") == true || outputProbe.codecName?.localizedCaseInsensitiveContains("h265") == true else {
                throw NativePublishingError.outputProfileMismatch("Expected an HEVC intermediate, got \(outputProbe.codecName ?? "missing codec").")
            }
            guard outputProbe.width == recipe.width, outputProbe.height == recipe.height else {
                throw NativePublishingError.outputProfileMismatch("ffprobe dimensions differ from AVFoundation inspection: \(outputProbe.width)x\(outputProbe.height).")
            }
            guard abs(outputProbe.frameRate - Double(recipe.frameRate)) <= 1 else {
                throw NativePublishingError.outputProfileMismatch("ffprobe frame rate differs from the target: \(outputProbe.frameRate) fps.")
            }
            guard outputProbe.hasAudio, outputProbe.audioChannels > 0 else {
                throw NativePublishingError.outputProfileMismatch("ffprobe found no usable audio stream.")
            }
            let sourceProbe = try MediaInspector().inspect(url: sourceURL, using: binaries)
            if sourceProbe.colorInfo.isHDR && !outputProbe.colorInfo.isHDR {
                throw NativePublishingError.outputProfileMismatch("The native publication lost the source recording's explicit HDR profile.")
            }
        } catch let error as NativePublishingError {
            throw error
        } catch {
            throw NativePublishingError.outputProfileMismatch("Could not verify the native answer with ffprobe: \(error.localizedDescription)")
        }
        return inspection
    }
}

private struct PublicationFingerprintInput: Codable, Sendable {
    let project: InterviewStudioProject
    let sessions: [InterviewSession]
    let recipe: PublicationRecipe
}

public struct ManifestPublicationBuilder: Sendable {
    public let answerPublisher: NativeAnswerPublisher

    public init(answerPublisher: NativeAnswerPublisher = .init()) {
        self.answerPublisher = answerPublisher
    }

    public func build(
        project: InterviewStudioProject,
        session: InterviewSession,
        store: InterviewStudioPackageStore,
        buildRoot: URL
    ) async throws -> PublicationBuildResult {
        try await build(
            project: project,
            sessions: [session],
            store: store,
            buildRoot: buildRoot,
            publicationSessionID: session.id,
            publicationRevision: session.revision
        )
    }

    public func buildAggregate(
        project: InterviewStudioProject,
        sessions: [InterviewSession],
        store: InterviewStudioPackageStore,
        buildRoot: URL
    ) async throws -> PublicationBuildResult {
        let orderedSessions = sessions.filter(\.isActive).sorted {
            let left = ($0.ageSortValue ?? .greatestFiniteMagnitude, $0.id.uuidString)
            let right = ($1.ageSortValue ?? .greatestFiniteMagnitude, $1.id.uuidString)
            return left < right
        }
        guard let firstSession = orderedSessions.first else {
            throw NativePublishingError.manifestBlocked("No interview years are available for the final movie.")
        }
        return try await build(
            project: project,
            sessions: orderedSessions,
            store: store,
            buildRoot: buildRoot,
            publicationSessionID: firstSession.id,
            publicationRevision: orderedSessions.map(\.revision).max() ?? firstSession.revision
        )
    }

    private func build(
        project: InterviewStudioProject,
        sessions: [InterviewSession],
        store: InterviewStudioPackageStore,
        buildRoot: URL,
        publicationSessionID: UUID,
        publicationRevision: Int
    ) async throws -> PublicationBuildResult {
        guard !sessions.isEmpty else { throw NativePublishingError.manifestBlocked("No interview years are available for publication.") }
        guard sessions.allSatisfy({ $0.isActive && ($0.lifecycle == .open || $0.lifecycle == .locked) && $0.compatibility.isWritable }) else {
            throw NativePublishingError.manifestBlocked("An archived or unsupported age entry cannot be included in publication.")
        }
        let fingerprintInput = PublicationFingerprintInput(project: project, sessions: sessions, recipe: answerPublisher.recipe)
        let fingerprint = sha256(data: try JSONEncoder.interviewStudio.encode(fingerprintInput))
        let publicationID = UUID()
        let root = buildRoot.appendingPathComponent(project.projectID.uuidString, isDirectory: true).appendingPathComponent(publicationID.uuidString, isDirectory: true)
        let answersRoot = root.appendingPathComponent("Answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answersRoot, withIntermediateDirectories: true)

        var rows: [ManifestRow] = []
        var clipNumber = 1
        for session in sessions {
            for (questionIndex, question) in project.activeQuestions.enumerated() {
                guard let answer = session.answers[question.questionKey] else { continue }
                if answer.state == .skipped { continue }
                guard answer.state == .complete else { throw NativePublishingError.manifestBlocked("Question \(question.questionKey) for \(session.ageLabel) is \(answer.state.rawValue).") }
                let recording: SourceRecording
                let boundaries: RefinedBoundaries?
        let rawMarkers: RawAnswerMarkers
        let sourceSegments: [CandidateSegment]
        let parserConfidence: ManifestParserConfidence?
        let recordingFirstCandidate: AnswerCandidate?
        if session.workflowKind == .recordingFirstV1 {
                    guard let candidateID = answer.assignedCandidateID,
                          let candidate = session.candidates.first(where: { $0.id == candidateID }) else {
                        throw NativePublishingError.manifestBlocked("Question \(question.questionKey) for \(session.ageLabel) has no assigned answer candidate.")
                    }
                    guard candidate.reviewState == .approved else {
                        throw NativePublishingError.manifestBlocked("\(candidate.label) must be approved before publication.")
                    }
                    guard let candidateRecording = session.recordings.first(where: { $0.id == candidate.sourceRecordingID }) else {
                        throw NativePublishingError.sourceMissing(candidate.sourceRecordingID.uuidString)
                    }
                    recording = candidateRecording
                    boundaries = candidate.refinedBoundaries
                    rawMarkers = candidate.rawMarkers
                    sourceSegments = RecordingFirstWorkflow.publicationSegments(for: candidate)
                    parserConfidence = .high
                    recordingFirstCandidate = candidate
                } else {
                    guard let take = answer.selectedTake else { throw NativePublishingError.missingSelectedTake(question.questionKey) }
                    if take.isMultiPart || take.parts.count > 1 { throw NativePublishingError.unsupportedMultiPart(question.questionKey) }
                    guard let part = take.parts.first else { throw NativePublishingError.missingSelectedTake(question.questionKey) }
                    guard let legacyRecording = session.recordings.first(where: { $0.id == part.sourceRecordingID }) else { throw NativePublishingError.sourceMissing(part.sourceRecordingID.uuidString) }
                    recording = legacyRecording
                    boundaries = part.refinedBoundaries
                    rawMarkers = part.rawMarkers
                    sourceSegments = [CandidateSegment(start: boundaries?.safeLeadingStart ?? rawMarkers.answerStart ?? .zero, end: boundaries?.safeTrailingEnd ?? rawMarkers.answerEnd ?? .zero)]
                    parserConfidence = take.confidence.map { $0 >= 0.8 ? .high : .medium }
                    recordingFirstCandidate = nil
                }
                let sourceURL = try store.resolve(relativePath: recording.packageRelativePath)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw NativePublishingError.sourceMissing(recording.packageRelativePath) }
                let safeQuestionKey = InterviewStudioKey.safeFilenameComponent(question.questionKey, fallback: "question")
                let safePersonKey = InterviewStudioKey.safeFilenameComponent(project.person.readableKey, fallback: "person")
                let safeAgeKey = InterviewStudioKey.safeFilenameComponent(session.ageKey, fallback: "age")
                let relativeOutput = sessions.count == 1
                    ? "Answers/\(safeQuestionKey)/\(safePersonKey)--\(safeAgeKey)--\(safeQuestionKey).mov"
                    : "Answers/\(safeAgeKey)/\(safeQuestionKey)/\(safePersonKey)--\(safeAgeKey)--\(safeQuestionKey).mov"
                let outputURL = root.appendingPathComponent(relativeOutput).standardizedFileURL
                guard outputURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                    throw NativePublishingError.manifestBlocked("The generated answer path escaped the publication root.")
                }
                let finalOutputInspection: NativeMediaInspection
                if let candidate = recordingFirstCandidate {
                    finalOutputInspection = try await answerPublisher.generate(candidate: candidate, sourceURL: sourceURL, outputURL: outputURL)
                } else {
                    guard let take = answer.selectedTake, let part = take.parts.first else {
                        throw NativePublishingError.missingSelectedTake(question.questionKey)
                    }
                    finalOutputInspection = try await answerPublisher.generate(part: part, sourceURL: sourceURL, outputURL: outputURL)
                }
                let duration = finalOutputInspection.duration.microseconds
                let outputSignature = ManifestVideoSignature(entries: [
                    .init(
                        colorSpace: finalOutputInspection.colorMatrix,
                        colorTransfer: finalOutputInspection.colorTransfer,
                        colorPrimaries: finalOutputInspection.colorPrimaries,
                        sideDataTypes: finalOutputInspection.hdrMetadataSummary.map { [$0] } ?? []
                    )
                ])
                let candidateOutputRange = recordingFirstCandidate.flatMap {
                    let timeline = RecordingFirstWorkflow.publicationTimeline(for: $0)
                    return timeline.visibleOutputRange(for: $0)
                }
                let outputVisibleStartUS = candidateOutputRange?.start.microseconds
                let outputVisibleEndUS = candidateOutputRange?.end.microseconds
                let sourceDurationUS = recording.mediaSignature.durationMicroseconds ?? sourceSegments.map(\.end.microseconds).max() ?? 0
                let requestedHandleBeforeUS = outputVisibleStartUS.map { max(0, $0) } ?? boundaries.map { max(0, $0.visibleStart.microseconds - $0.safeLeadingStart.microseconds) } ?? 0
                let requestedHandleAfterUS = outputVisibleEndUS.map { max(0, duration - $0) } ?? boundaries.map { max(0, $0.safeTrailingEnd.microseconds - $0.visibleEnd.microseconds) } ?? 0
                let actualHandleBeforeUS = outputVisibleStartUS.map { max(0, $0) } ?? boundaries.map { max(0, $0.visibleStart.microseconds - $0.safeLeadingStart.microseconds) } ?? 0
                let actualHandleAfterUS = outputVisibleEndUS.map { max(0, duration - $0) } ?? boundaries.map { max(0, $0.safeTrailingEnd.microseconds - $0.visibleEnd.microseconds) } ?? 0
                let row = ManifestRow(
                    clipNumber: String(clipNumber),
                    sequenceIndex: questionIndex,
                    person: project.person.displayName,
                    personKey: project.person.readableKey,
                    question: question.displayText,
                    questionKey: question.questionKey,
                    questionOriginalIndex: question.order,
                    age: session.ageLabel,
                    ageRawText: session.ageLabel,
                    ageKey: session.ageKey,
                    ageYears: session.ageSortValue,
                    ageSortKey: session.ageSortValue,
                    outputFile: relativeOutput,
                    exportStatus: "exported",
                    status: "ready",
                    parserConfidence: parserConfidence,
                    notes: "Native Phase 2 answer clip re-inspected after export; source SHA-256 \(recording.mediaSignature.sha256).",
                    sourceIsDolby: (recording.mediaSignature.colorTransfer ?? "").localizedCaseInsensitiveContains("2084"),
                    hdrDolbyValidation: "pending_owner_validation",
                    outputVideoSignature: outputSignature,
                    requestedHandleBeforeUS: requestedHandleBeforeUS,
                    requestedHandleAfterUS: requestedHandleAfterUS,
                    actualHandleBeforeUS: actualHandleBeforeUS,
                    actualHandleAfterUS: actualHandleAfterUS,
                    handleBeforeStatus: "derived_from_validated_export_range",
                    handleAfterStatus: "derived_from_validated_export_range",
                    realMediaStartInOutputUS: recordingFirstCandidate == nil ? boundaries?.visibleStart.microseconds ?? 0 : 0,
                    realMediaEndInOutputUS: recordingFirstCandidate == nil ? boundaries?.visibleEnd.microseconds ?? duration : duration,
                    answerStartInOutputUS: outputVisibleStartUS ?? boundaries?.visibleStart.microseconds ?? 0,
                    answerEndInOutputUS: outputVisibleEndUS ?? boundaries?.visibleEnd.microseconds ?? duration,
                    sourcePartCount: sourceSegments.count,
                    sourceParts: sourceSegments.enumerated().map { index, segment in
                        SourcePart(partIndex: index, sourceFile: recording.packageRelativePath, sourceUUID: recording.id.uuidString, sourceIsDolby: (recording.mediaSignature.colorTransfer ?? "").localizedCaseInsensitiveContains("2084"), parsedSourceInUS: segment.start.microseconds, parsedSourceOutUS: segment.end.microseconds, sourceDurationUS: sourceDurationUS)
                    }
                )
                rows.append(row)
                clipNumber += 1
            }
        }

        let manifestURL = root.appendingPathComponent("final_manifest.json")
        try JSONEncoder.interviewStudio.encode(rows).write(to: manifestURL, options: .atomic)
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: manifestURL, projectFolder: root)
        let legacyDocument = ProjectDocument(
            projectName: "\(project.person.displayName) Interview",
            personName: project.person.displayName,
            manifestFilename: "final_manifest.json",
            openingTitle: project.assemblySettings.openingTitle,
            closingTitle: project.assemblySettings.closingTitle,
            questionOrder: project.activeQuestions.map(\.questionKey),
            questionDisplayTexts: Dictionary(uniqueKeysWithValues: project.activeQuestions.map { ($0.questionKey, $0.displayText) }),
            plexMetadata: project.assemblySettings.plexMetadata,
            renderSettings: project.assemblySettings.renderSettings
        )
        let renderPlan = RenderPlanBuilder().build(project: loaded, document: legacyDocument)
        if renderPlan.summary.blockerCount > 0 {
            throw NativePublishingError.manifestBlocked("Phase 1 render plan contains \(renderPlan.summary.blockerCount) blocker(s).")
        }
        let publication = PublicationRecord(projectID: project.projectID, sessionID: publicationSessionID, revision: publicationRevision, fingerprint: fingerprint, manifestRelativePath: "final_manifest.json", recipe: answerPublisher.recipe, answerCount: rows.count)
        try JSONEncoder.interviewStudio.encode(publication).write(to: root.appendingPathComponent("publication.json"), options: .atomic)
        return PublicationBuildResult(publication: publication, buildRoot: root, manifestURL: manifestURL, rows: rows, renderPlan: renderPlan)
    }
}

public struct FinishAndLockService: Sendable {
    public let publicationBuilder: ManifestPublicationBuilder

    public init(publicationBuilder: ManifestPublicationBuilder = .init()) {
        self.publicationBuilder = publicationBuilder
    }

    public func finishAndLock(project: InterviewStudioProject, session: InterviewSession, store: InterviewStudioPackageStore, buildRoot: URL) async throws -> PublicationBuildResult {
        var staged = session
        staged.lifecycle = .open
        var result = try await publicationBuilder.build(project: project, session: staged, store: store, buildRoot: buildRoot)
        staged.lifecycle = .locked
        staged.revision += 1
        staged.publicationFingerprint = result.publication.fingerprint
        staged.appendAudit("lock", detail: "Published \(result.rows.count) answer(s) as \(result.publication.id.uuidString).")
        result.stagedSession = staged
        return result
    }
}
