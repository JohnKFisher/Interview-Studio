import AVFoundation
import Darwin
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
    case derivedBuildInProgress
    case derivedBuildLockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sessionMustBeOpenOrLocked: return "The session cannot be published in its current lifecycle state."
        case .missingSelectedTake(let key): return "Question \(key) has no selected answer take."
        case .unsupportedMultiPart(let key): return "Multi-part answer \(key) requires the Phase 2 compositor and cannot be published by this pass."
        case .sourceMissing(let path): return "The selected source recording is missing: \(path)"
        case .exportFailed(let message): return "Native answer export failed: \(message)"
        case .outputAlreadyExists(let url): return "The answer output already exists and was not overwritten: \(url.path)"
        case .outputProfileMismatch(let message): return "Native answer output did not meet the protected publication profile: \(message)"
        case .manifestBlocked(let message): return "Publication is blocked: \(message)"
        case .derivedBuildInProgress: return "A derived publication is already in progress for this project."
        case .derivedBuildLockFailed(let message): return "Could not reserve the derived publication workspace: \(message)"
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
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let start = CMTime(value: boundaries.safeLeadingStart.value, timescale: boundaries.safeLeadingStart.timescale)
        let end = CMTime(value: boundaries.safeTrailingEnd.value, timescale: boundaries.safeTrailingEnd.timescale)
        let duration = CMTimeSubtract(end, start)
        guard duration.isNumeric, duration > .zero else { throw NativePublishingError.exportFailed("The selected range is empty.") }
        let renderTransform = try compositionTransform(for: naturalSize, preferredTransform: preferredTransform)

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
        videoTrack.preferredTransform = .identity

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(renderTransform, at: .zero)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: recipe.width, height: recipe.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(recipe.frameRate))
        videoComposition.instructions = [instruction]

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

    internal func compositionTransform(for naturalSize: CGSize, preferredTransform: CGAffineTransform) throws -> CGAffineTransform {
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
        let centering = CGAffineTransform(
            translationX: (CGFloat(recipe.width) - renderedWidth) / 2,
            y: (CGFloat(recipe.height) - renderedHeight) / 2
        )
        let scaling = CGAffineTransform(scaleX: scale, y: scale)
        let normalization = CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
        return preferredTransform
            .concatenating(normalization)
            .concatenating(scaling)
            .concatenating(centering)
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

/// A cross-process lease for one project's derived publication cache.
/// The descriptor-backed lock is released by the kernel if the owner exits.
public final class DerivedBuildLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    public func release() {
        stateLock.lock()
        guard let fileDescriptor else {
            stateLock.unlock()
            return
        }
        self.fileDescriptor = nil
        stateLock.unlock()
        _ = flock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }

    deinit { release() }
}

public struct ManifestPublicationBuilder: Sendable {
    public let answerPublisher: NativeAnswerPublisher

    /// Timing fields for a published answer are relative to the generated
    /// output file, not to the source recording. Legacy publication exports a
    /// source range into a new file whose timeline starts at zero.
    internal struct PublishedOutputTiming: Equatable, Sendable {
        let requestedHandleBeforeUS: Int64
        let requestedHandleAfterUS: Int64
        let actualHandleBeforeUS: Int64
        let actualHandleAfterUS: Int64
        let realMediaStartUS: Int64
        let realMediaEndUS: Int64
        let answerStartUS: Int64
        let answerEndUS: Int64
    }

    public init(answerPublisher: NativeAnswerPublisher = .init()) {
        self.answerPublisher = answerPublisher
    }

    /// Converts source-relative legacy markers to the zero-based timeline of
    /// the native answer export. The export contains the complete safe range,
    /// so all of that output is real media and the visible answer is offset by
    /// the exported range's source start.
    internal static func legacyPublishedOutputTiming(
        boundaries: RefinedBoundaries?,
        rawMarkers: RawAnswerMarkers,
        outputDurationUS: Int64
    ) -> PublishedOutputTiming {
        let durationUS = max(0, outputDurationUS)
        let exportedSourceStartUS = boundaries?.safeLeadingStart.microseconds
            ?? rawMarkers.answerStart?.microseconds
            ?? 0
        let sourceVisibleStartUS = boundaries?.visibleStart.microseconds
            ?? rawMarkers.answerStart?.microseconds
            ?? exportedSourceStartUS
        let sourceVisibleEndUS = boundaries?.visibleEnd.microseconds
            ?? rawMarkers.answerEnd?.microseconds
            ?? boundaries?.safeTrailingEnd.microseconds
            ?? (exportedSourceStartUS + durationUS)

        let answerStartUS = min(durationUS, max(0, sourceVisibleStartUS - exportedSourceStartUS))
        let answerEndUS = min(durationUS, max(answerStartUS, sourceVisibleEndUS - exportedSourceStartUS))
        return PublishedOutputTiming(
            requestedHandleBeforeUS: answerStartUS,
            requestedHandleAfterUS: max(0, durationUS - answerEndUS),
            actualHandleBeforeUS: answerStartUS,
            actualHandleAfterUS: max(0, durationUS - answerEndUS),
            realMediaStartUS: 0,
            realMediaEndUS: durationUS,
            answerStartUS: answerStartUS,
            answerEndUS: answerEndUS
        )
    }

    /// Reserves the current project's canonical derived cache until the
    /// caller finishes consuming its publication build.
    public static func acquireDerivedBuildLease(at buildRoot: URL, for projectID: UUID) throws -> DerivedBuildLease {
        guard let normalizedRoot = canonicalDerivedBuildRoot(buildRoot) else {
            throw NativePublishingError.derivedBuildLockFailed("The derived build root is not a canonical Interview Studio cache root.")
        }
        let projectRoot = normalizedRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        if let values = try? projectRoot.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw NativePublishingError.derivedBuildLockFailed("The project cache directory is a symbolic link.")
        }
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        guard canonicalDerivedBuildRoot(buildRoot) != nil else {
            throw NativePublishingError.derivedBuildLockFailed("The derived build root became a symbolic link.")
        }
        guard !pathContainsSymbolicLink(from: projectRoot, through: normalizedRoot) else {
            throw NativePublishingError.derivedBuildLockFailed("The project cache path contains a symbolic link.")
        }
        let lockURL = projectRoot.appendingPathComponent(".publication.lock")
        let fileDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw NativePublishingError.derivedBuildLockFailed(String(cString: strerror(errno)))
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(fileDescriptor)
            if lockError == EACCES || lockError == EAGAIN || lockError == EWOULDBLOCK {
                throw NativePublishingError.derivedBuildInProgress
            }
            throw NativePublishingError.derivedBuildLockFailed(String(cString: strerror(lockError)))
        }
        return DerivedBuildLease(fileDescriptor: fileDescriptor)
    }

    /// Removes a derived publication directory after its consumer no longer
    /// needs the generated answer clips. The caller must provide the canonical
    /// cache root and project ID so UUID-shaped paths outside that exact
    /// ownership boundary are never removed.
    public static func cleanupDerivedBuild(at buildURL: URL, in buildRoot: URL, for projectID: UUID) throws {
        guard let normalizedRoot = canonicalDerivedBuildRoot(buildRoot) else { return }
        try cleanupBuildDirectory(at: buildURL, under: normalizedRoot, for: projectID)
    }

    /// Removes stale derived publications for one project before a new build.
    /// Import staging lives elsewhere and is intentionally not touched.
    public static func pruneDerivedBuilds(at buildRoot: URL, for projectID: UUID) throws {
        guard let normalizedRoot = canonicalDerivedBuildRoot(buildRoot) else { return }
        let projectRoot = normalizedRoot.appendingPathComponent(projectID.uuidString, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: projectRoot.path) else { return }
        guard !pathContainsSymbolicLink(from: projectRoot, through: normalizedRoot) else { return }
        let values = try projectRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return }
        let entries = try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            try cleanupBuildDirectory(at: entry, under: normalizedRoot, for: projectID)
        }
    }

    static func canonicalDerivedBuildRoot(_ buildRoot: URL, cachesDirectory overrideCachesDirectory: URL? = nil) -> URL? {
        let normalizedRoot = buildRoot.standardizedFileURL
        guard ["Generated", "FinalRenders"].contains(normalizedRoot.lastPathComponent) else { return nil }
        guard let cachesRoot = overrideCachesDirectory?.standardizedFileURL
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.standardizedFileURL else { return nil }
        let expectedRoot = cachesRoot
            .appendingPathComponent("YearlyInterviewStudio", isDirectory: true)
            .appendingPathComponent(normalizedRoot.lastPathComponent, isDirectory: true)
            .standardizedFileURL
        guard normalizedRoot == expectedRoot else { return nil }
        return pathContainsSymbolicLink(from: normalizedRoot, through: cachesRoot) ? nil : normalizedRoot
    }

    private static func pathContainsSymbolicLink(from path: URL, through ancestor: URL) -> Bool {
        let normalizedPath = path.standardizedFileURL
        let normalizedAncestor = ancestor.standardizedFileURL
        guard normalizedPath == normalizedAncestor || normalizedPath.path.hasPrefix(normalizedAncestor.path + "/") else {
            return true
        }

        var current = normalizedPath
        while true {
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                return true
            }
            if current == normalizedAncestor { return false }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { return true }
            current = parent
        }
    }

    private static func cleanupBuildDirectory(at buildURL: URL, under buildRoot: URL, for projectID: UUID) throws {
        let normalizedRoot = buildRoot.standardizedFileURL
        let expectedProjectRoot = normalizedRoot
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .standardizedFileURL
        let normalizedURL = buildURL.standardizedFileURL
        guard normalizedURL.deletingLastPathComponent() == expectedProjectRoot,
              UUID(uuidString: normalizedURL.lastPathComponent) != nil else {
            return
        }
        guard !pathContainsSymbolicLink(from: expectedProjectRoot, through: normalizedRoot) else { return }
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else { return }
        let values = try normalizedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return }
        try FileManager.default.removeItem(at: normalizedURL)
    }

    public func build(
        project: InterviewStudioProject,
        session: InterviewSession,
        store: InterviewStudioPackageStore,
        buildRoot: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PublicationBuildResult {
        try await build(
            project: project,
            sessions: [session],
            store: store,
            buildRoot: buildRoot,
            publicationSessionID: session.id,
            publicationRevision: session.revision,
            progress: progress
        )
    }

    public func buildAggregate(
        project: InterviewStudioProject,
        sessions: [InterviewSession],
        store: InterviewStudioPackageStore,
        buildRoot: URL,
        progress: (@Sendable (String) -> Void)? = nil
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
            publicationRevision: orderedSessions.map(\.revision).max() ?? firstSession.revision,
            progress: progress
        )
    }

    private func build(
        project: InterviewStudioProject,
        sessions: [InterviewSession],
        store: InterviewStudioPackageStore,
        buildRoot: URL,
        publicationSessionID: UUID,
        publicationRevision: Int,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PublicationBuildResult {
        guard !sessions.isEmpty else { throw NativePublishingError.manifestBlocked("No interview years are available for publication.") }
        guard sessions.allSatisfy({ $0.isActive && ($0.lifecycle == .open || $0.lifecycle == .locked) && $0.compatibility.isWritable }) else {
            throw NativePublishingError.manifestBlocked("An archived or unsupported age entry cannot be included in publication.")
        }
        let fingerprintInput = PublicationFingerprintInput(project: project, sessions: sessions, recipe: answerPublisher.recipe)
        let fingerprint = sha256(data: try JSONEncoder.interviewStudio.encode(fingerprintInput))
        let publicationID = UUID()
        let root = buildRoot.appendingPathComponent(project.projectID.uuidString, isDirectory: true).appendingPathComponent(publicationID.uuidString, isDirectory: true)
        var buildCompleted = false
        defer {
            if !buildCompleted {
                try? Self.cleanupBuildDirectory(at: root, under: buildRoot, for: project.projectID)
            }
        }
        let answersRoot = root.appendingPathComponent("Answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answersRoot, withIntermediateDirectories: true)

        let answerCount = sessions.reduce(0) { count, session in
            count + project.activeQuestions.filter { session.answers[$0.questionKey]?.state == .complete }.count
        }
        if answerCount == 0 {
            progress?("No answer clips need preparation; building the render plan…")
        } else {
            progress?("Preparing 0 of \(answerCount) answer clips…")
        }

        var rows: [ManifestRow] = []
        var clipNumber = 1
        var preparedAnswerCount = 0
        for session in sessions {
            let displayAgeLabel = RecordingFirstWorkflow.displayAgeLabel(for: session)
            for (questionIndex, question) in project.activeQuestions.enumerated() {
                guard let answer = session.answers[question.questionKey] else { continue }
                if answer.state == .skipped { continue }
                guard answer.state == .complete else { throw NativePublishingError.manifestBlocked("Question \(question.questionKey) for \(displayAgeLabel) is \(answer.state.rawValue).") }
                let answerOrdinal = preparedAnswerCount + 1
                progress?("Preparing \(answerOrdinal) of \(answerCount): \(displayAgeLabel) · \(question.displayText)…")
                let recording: SourceRecording
                let boundaries: RefinedBoundaries?
        let rawMarkers: RawAnswerMarkers
        let sourceSegments: [CandidateSegment]
        let parserConfidence: ManifestParserConfidence?
        let recordingFirstCandidate: AnswerCandidate?
        if session.workflowKind == .recordingFirstV1 {
                    guard let candidateID = answer.assignedCandidateID,
                          let candidate = session.candidates.first(where: { $0.id == candidateID }) else {
                        throw NativePublishingError.manifestBlocked("Question \(question.questionKey) for \(displayAgeLabel) has no assigned answer candidate.")
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
                let outputTiming: PublishedOutputTiming
                if let candidateOutputRange {
                    let outputVisibleStartUS = candidateOutputRange.start.microseconds
                    let outputVisibleEndUS = candidateOutputRange.end.microseconds
                    outputTiming = PublishedOutputTiming(
                        requestedHandleBeforeUS: max(0, outputVisibleStartUS),
                        requestedHandleAfterUS: max(0, duration - outputVisibleEndUS),
                        actualHandleBeforeUS: max(0, outputVisibleStartUS),
                        actualHandleAfterUS: max(0, duration - outputVisibleEndUS),
                        realMediaStartUS: 0,
                        realMediaEndUS: duration,
                        answerStartUS: outputVisibleStartUS,
                        answerEndUS: outputVisibleEndUS
                    )
                } else {
                    outputTiming = Self.legacyPublishedOutputTiming(
                        boundaries: boundaries,
                        rawMarkers: rawMarkers,
                        outputDurationUS: duration
                    )
                }
                let sourceDurationUS = recording.mediaSignature.durationMicroseconds ?? sourceSegments.map(\.end.microseconds).max() ?? 0
                let row = ManifestRow(
                    clipNumber: String(clipNumber),
                    sequenceIndex: questionIndex,
                    person: project.person.displayName,
                    personKey: project.person.readableKey,
                    question: question.displayText,
                    questionKey: question.questionKey,
                    questionOriginalIndex: question.order,
                    age: displayAgeLabel,
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
                    requestedHandleBeforeUS: outputTiming.requestedHandleBeforeUS,
                    requestedHandleAfterUS: outputTiming.requestedHandleAfterUS,
                    actualHandleBeforeUS: outputTiming.actualHandleBeforeUS,
                    actualHandleAfterUS: outputTiming.actualHandleAfterUS,
                    handleBeforeStatus: "derived_from_validated_export_range",
                    handleAfterStatus: "derived_from_validated_export_range",
                    realMediaStartInOutputUS: outputTiming.realMediaStartUS,
                    realMediaEndInOutputUS: outputTiming.realMediaEndUS,
                    answerStartInOutputUS: outputTiming.answerStartUS,
                    answerEndInOutputUS: outputTiming.answerEndUS,
                    sourcePartCount: sourceSegments.count,
                    sourceParts: sourceSegments.enumerated().map { index, segment in
                        SourcePart(partIndex: index, sourceFile: recording.packageRelativePath, sourceUUID: recording.id.uuidString, sourceIsDolby: (recording.mediaSignature.colorTransfer ?? "").localizedCaseInsensitiveContains("2084"), parsedSourceInUS: segment.start.microseconds, parsedSourceOutUS: segment.end.microseconds, sourceDurationUS: sourceDurationUS)
                    }
                )
                rows.append(row)
                clipNumber += 1
                preparedAnswerCount += 1
                progress?("Prepared \(preparedAnswerCount) of \(answerCount) answer clips.")
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
            throw NativePublishingError.manifestBlocked(Self.blockingMessage(for: renderPlan))
        }
        let publication = PublicationRecord(projectID: project.projectID, sessionID: publicationSessionID, revision: publicationRevision, fingerprint: fingerprint, manifestRelativePath: "final_manifest.json", recipe: answerPublisher.recipe, answerCount: rows.count)
        try JSONEncoder.interviewStudio.encode(publication).write(to: root.appendingPathComponent("publication.json"), options: .atomic)
        buildCompleted = true
        return PublicationBuildResult(publication: publication, buildRoot: root, manifestURL: manifestURL, rows: rows, renderPlan: renderPlan)
    }

    internal static func blockingMessage(for renderPlan: RenderPlan) -> String {
        let blockers = renderPlan.issues.filter { $0.severity == .blocker }
        let details = blockers.enumerated().map { index, issue in
            var detail = "\(index + 1). \(issue.humanMessage) [\(issue.code)]"
            if !issue.suggestedFix.isEmpty {
                detail += " Suggested fix: \(issue.suggestedFix)"
            }
            return detail
        }.joined(separator: "\n")
        let summary = "Phase 1 render plan contains \(blockers.count) blocker(s)."
        return details.isEmpty ? summary : "\(summary)\n\(details)"
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
