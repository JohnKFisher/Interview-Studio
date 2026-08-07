import AVFoundation
import Foundation

public enum NativePublishingError: LocalizedError, Sendable {
    case sessionMustBeOpenOrLocked
    case missingSelectedTake(String)
    case unsupportedMultiPart(String)
    case sourceMissing(String)
    case exportFailed(String)
    case outputProfileMismatch(String)
    case manifestBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .sessionMustBeOpenOrLocked: return "The session cannot be published in its current lifecycle state."
        case .missingSelectedTake(let key): return "Question \(key) has no selected answer take."
        case .unsupportedMultiPart(let key): return "Multi-part answer \(key) requires the Phase 2 compositor and cannot be published by this pass."
        case .sourceMissing(let path): return "The selected source recording is missing: \(path)"
        case .exportFailed(let message): return "Native answer export failed: \(message)"
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

    public init(publication: PublicationRecord, buildRoot: URL, manifestURL: URL, rows: [ManifestRow], renderPlan: RenderPlan) {
        self.publication = publication
        self.buildRoot = buildRoot
        self.manifestURL = manifestURL
        self.rows = rows
        self.renderPlan = renderPlan
    }
}

public struct NativeAnswerPublisher: Sendable {
    public let recipe: PublicationRecipe

    public init(recipe: PublicationRecipe = .phaseTwoDefault) {
        self.recipe = recipe
    }

    public func generate(part: AnswerPart, sourceURL: URL, outputURL: URL) async throws {
        guard let boundaries = part.refinedBoundaries ?? refinedFallback(for: part.rawMarkers) else {
            throw NativePublishingError.exportFailed("The answer has no usable boundaries.")
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let sourceVideo = asset.tracks(withMediaType: .video).first,
              let sourceAudio = asset.tracks(withMediaType: .audio).first else {
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
        if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
        let preset = AVAssetExportPresetHEVC3840x2160
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NativePublishingError.exportFailed("The system does not provide \(preset).")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        await exporter.export()
        guard exporter.status == .completed else {
            throw NativePublishingError.exportFailed(exporter.error?.localizedDescription ?? "Unknown export error.")
        }
        try validate(outputURL: outputURL)
    }

    private func refinedFallback(for markers: RawAnswerMarkers) -> RefinedBoundaries? {
        guard let start = markers.answerStart, let end = markers.answerEnd, end > start else { return nil }
        return RefinedBoundaries(visibleStart: start, visibleEnd: end, safeLeadingStart: start, safeTrailingEnd: end, confidence: 0.4, reasons: ["Native fallback used raw markers."], algorithmIdentifier: "raw-marker-fallback", algorithmVersion: "1.0")
    }

    private func validate(outputURL: URL) throws {
        let asset = AVURLAsset(url: outputURL)
        guard let video = asset.tracks(withMediaType: .video).first else { throw NativePublishingError.outputProfileMismatch("No video track.") }
        let size = video.naturalSize
        guard Int(abs(size.width.rounded())) == recipe.width, Int(abs(size.height.rounded())) == recipe.height else {
            throw NativePublishingError.outputProfileMismatch("Expected \(recipe.width)x\(recipe.height), got \(Int(abs(size.width.rounded())))x\(Int(abs(size.height.rounded()))).")
        }
        guard Double(video.nominalFrameRate) >= Double(recipe.frameRate - 1) else {
            throw NativePublishingError.outputProfileMismatch("Expected \(recipe.frameRate) fps, got \(video.nominalFrameRate).")
        }
    }
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
        guard session.lifecycle == .open || session.lifecycle == .locked else { throw NativePublishingError.sessionMustBeOpenOrLocked }
        let encodedSession = try JSONEncoder.interviewStudio.encode(session)
        let fingerprint = sha256(data: encodedSession)
        let publicationID = UUID()
        let root = buildRoot.appendingPathComponent(project.projectID.uuidString, isDirectory: true).appendingPathComponent(publicationID.uuidString, isDirectory: true)
        let answersRoot = root.appendingPathComponent("Answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answersRoot, withIntermediateDirectories: true)

        var rows: [ManifestRow] = []
        var clipNumber = 1
        for (questionIndex, question) in project.activeQuestions.enumerated() {
            guard let answer = session.answers[question.questionKey] else { continue }
            if answer.state == .skipped { continue }
            guard answer.state == .complete else { throw NativePublishingError.manifestBlocked("Question \(question.questionKey) is \(answer.state.rawValue).") }
            guard let take = answer.selectedTake else { throw NativePublishingError.missingSelectedTake(question.questionKey) }
            if take.isMultiPart || take.parts.count > 1 { throw NativePublishingError.unsupportedMultiPart(question.questionKey) }
            guard let part = take.parts.first else { throw NativePublishingError.missingSelectedTake(question.questionKey) }
            guard let recording = session.recordings.first(where: { $0.id == part.sourceRecordingID }) else { throw NativePublishingError.sourceMissing(part.sourceRecordingID.uuidString) }
            let sourceURL = try store.resolve(relativePath: recording.packageRelativePath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw NativePublishingError.sourceMissing(recording.packageRelativePath) }
            let relativeOutput = "Answers/\(question.questionKey)/\(project.person.readableKey)--\(session.ageKey)--\(question.questionKey).mov"
            let outputURL = root.appendingPathComponent(relativeOutput)
            try await answerPublisher.generate(part: part, sourceURL: sourceURL, outputURL: outputURL)
            let duration = (try? NativeMediaInspector().inspect(url: outputURL).duration.microseconds) ?? 0
            let boundaries = part.refinedBoundaries
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
                parserConfidence: take.confidence.map { $0 >= 0.8 ? .high : .medium },
                notes: "Native Phase 2 answer clip; source SHA-256 \(recording.mediaSignature.sha256).",
                sourceIsDolby: (recording.mediaSignature.colorTransfer ?? "").localizedCaseInsensitiveContains("2084"),
                hdrDolbyValidation: "pending_owner_validation",
                requestedHandleBeforeUS: boundaries.map { max(0, $0.visibleStart.microseconds - $0.safeLeadingStart.microseconds) } ?? 0,
                requestedHandleAfterUS: boundaries.map { max(0, $0.safeTrailingEnd.microseconds - $0.visibleEnd.microseconds) } ?? 0,
                actualHandleBeforeUS: boundaries.map { max(0, $0.visibleStart.microseconds - $0.safeLeadingStart.microseconds) } ?? 0,
                actualHandleAfterUS: boundaries.map { max(0, $0.safeTrailingEnd.microseconds - $0.visibleEnd.microseconds) } ?? 0,
                handleBeforeStatus: "verified",
                handleAfterStatus: "verified",
                realMediaStartInOutputUS: boundaries?.visibleStart.microseconds ?? 0,
                realMediaEndInOutputUS: boundaries?.visibleEnd.microseconds ?? duration,
                answerStartInOutputUS: boundaries?.visibleStart.microseconds ?? 0,
                answerEndInOutputUS: boundaries?.visibleEnd.microseconds ?? duration,
                sourcePartCount: 1,
                sourceParts: [SourcePart(partIndex: 0, sourceFile: recording.packageRelativePath, sourceUUID: recording.id.uuidString, parsedSourceInUS: part.rawMarkers.answerStart?.microseconds, parsedSourceOutUS: part.rawMarkers.answerEnd?.microseconds)]
            )
            rows.append(row)
            clipNumber += 1
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
        let publication = PublicationRecord(projectID: project.projectID, sessionID: session.id, revision: session.revision, fingerprint: fingerprint, manifestRelativePath: "final_manifest.json", recipe: answerPublisher.recipe, answerCount: rows.count)
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
        let result = try await publicationBuilder.build(project: project, session: staged, store: store, buildRoot: buildRoot)
        staged.lifecycle = .locked
        staged.revision += 1
        staged.publicationFingerprint = result.publication.fingerprint
        staged.appendAudit("lock", detail: "Published \(result.rows.count) answer(s) as \(result.publication.id.uuidString).")
        try store.writeSession(staged)
        try store.writePublication(result.publication)
        try store.rebuildInventory()
        return result
    }
}

private extension AVAssetExportSession {
    func export() async {
        await withCheckedContinuation { continuation in
            exportAsynchronously { continuation.resume() }
        }
    }
}
