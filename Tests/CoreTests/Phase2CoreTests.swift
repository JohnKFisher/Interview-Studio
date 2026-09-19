@testable import Core
import CoreGraphics
import Foundation
import XCTest

final class Phase2CoreTests: XCTestCase {
    func testPackageBackedAssemblyDefaultsOptionalPlexCompanionOff() {
        XCTAssertFalse(AssemblySettings().plexMetadata.isEnabled)
        XCTAssertTrue(PlexMetadataInput().isEnabled)
    }

    func testAccidentalEmptyPlexCompanionMigrationIsExactAndIdempotent() {
        let original = InterviewStudioProject(
            person: InterviewPerson(readableKey: "ellie", displayName: "Ellie"),
            assemblySettings: AssemblySettings(plexMetadata: PlexMetadataInput()),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let migrationDate = Date(timeIntervalSince1970: 200)

        let result = InterviewStudioPackageMigration.repairAccidentalEmptyPlexCompanion(
            in: original,
            sourcePathDescription: "Ellie Interview.interviewstudio",
            date: migrationDate
        )

        XCTAssertFalse(result.project.assemblySettings.plexMetadata.isEnabled)
        XCTAssertEqual(result.project.createdAt, original.createdAt)
        XCTAssertEqual(result.project.updatedAt, migrationDate)
        XCTAssertEqual(result.project.migrationHistoryIDs, [InterviewStudioPackageMigration.accidentalEmptyPlexCompanionDefaultID])
        XCTAssertEqual(result.migrationRecord?.id, InterviewStudioPackageMigration.accidentalEmptyPlexCompanionDefaultID)

        let secondPass = InterviewStudioPackageMigration.repairAccidentalEmptyPlexCompanion(
            in: result.project,
            sourcePathDescription: "Ellie Interview.interviewstudio",
            date: Date(timeIntervalSince1970: 300)
        )
        XCTAssertNil(secondPass.migrationRecord)
        XCTAssertEqual(secondPass.project, result.project)
    }

    func testAccidentalEmptyPlexCompanionMigrationDoesNotChangeExplicitSettings() {
        var configured = InterviewStudioProject(person: InterviewPerson(readableKey: "ellie", displayName: "Ellie"))
        configured.assemblySettings.plexMetadata.isEnabled = true
        configured.assemblySettings.plexMetadata.show = "Family Interviews"
        let configuredResult = InterviewStudioPackageMigration.repairAccidentalEmptyPlexCompanion(
            in: configured,
            sourcePathDescription: "configured"
        )
        XCTAssertNil(configuredResult.migrationRecord)
        XCTAssertTrue(configuredResult.project.assemblySettings.plexMetadata.isEnabled)

        var disabled = InterviewStudioProject(person: InterviewPerson(readableKey: "ellie", displayName: "Ellie"))
        disabled.assemblySettings.plexMetadata.isEnabled = false
        let disabledResult = InterviewStudioPackageMigration.repairAccidentalEmptyPlexCompanion(
            in: disabled,
            sourcePathDescription: "disabled"
        )
        XCTAssertNil(disabledResult.migrationRecord)
        XCTAssertFalse(disabledResult.project.assemblySettings.plexMetadata.isEnabled)
    }

    func testMigrationRecordIsIncludedInPackageInventory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).interviewstudio", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InterviewStudioPackageStore.create(
            project: InterviewStudioProject(person: InterviewPerson(readableKey: "ellie", displayName: "Ellie")),
            at: root
        )
        let record = MigrationRecord(
            id: UUID(),
            sourcePathDescription: "test",
            decisionSummary: ["test migration"]
        )

        try store.writeMigrationRecord(record)
        try store.rebuildInventory()
        try store.verifyInventory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.migrationHistoryURL(for: record.id).path))
    }

    func testPackageRoundTripAndInventoryVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).interviewstudio", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = InterviewStudioProject(
            person: InterviewPerson(readableKey: "ellie", displayName: "Ellie"),
            questions: [InterviewQuestion(questionKey: "favorite_memory", displayText: "What is your favorite memory?", order: 0)],
            extensions: ["vendor.example": .object(["kept": .bool(true)])]
        )
        let store = try InterviewStudioPackageStore.create(project: project, at: root)
        XCTAssertEqual(try store.readProject().person.displayName, "Ellie")
        try store.verifyInventory()

        let session = InterviewSession(ageKey: "age_5", ageLabel: "5 Years Old", ageSortValue: 5)
        try store.writeSession(session)
        try store.rebuildInventory()
        try store.verifyInventory()

        project = try store.readProject()
        XCTAssertEqual(project.extensions["vendor.example"], .object(["kept": .bool(true)]))
        XCTAssertEqual(try store.listSessions().map(\.ageKey), ["age_5"])
    }

    func testRecordingConsolidationJournalPromotesBytesBeforeInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).interviewstudio", isDirectory: true)
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        try Data("recording bytes".utf8).write(to: sourceURL)
        let project = InterviewStudioProject(person: InterviewPerson(readableKey: "ellie", displayName: "Ellie"))
        let store = try InterviewStudioPackageStore.create(project: project, at: root)
        let stagingRoot = root.appendingPathComponent(".recording-staging/test", isDirectory: true)
        let staged = try await store.stageRecordingImport(
            from: sourceURL,
            ageKey: "age_5",
            ageLabel: "Age 5",
            source: .finder,
            stagingRoot: stagingRoot,
            recordingNumber: 1
        )
        let recording = staged.imported.recording
        let stagedURL = try XCTUnwrap(staged.stagedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        let session = InterviewSession(
            workflowKind: .recordingFirstV1,
            ageKey: "age_5",
            ageLabel: "Age 5",
            ageSortValue: 5,
            recordings: [recording]
        )
        try store.writeConsolidationJournal(.init(entries: [
            .init(id: recording.id, relativePath: recording.packageRelativePath, byteCount: recording.mediaSignature.byteCount, sha256: recording.mediaSignature.sha256, sessionID: session.id, recording: recording, stagedRelativePath: store.packageRelativePath(for: stagedURL))
        ]))
        try store.consolidateStagedRecording(from: stagedURL, recording: recording)
        try FileManager.default.removeItem(at: stagedURL)
        try store.writeSession(session)
        try store.rebuildInventory()
        try store.removeConsolidationJournal()
        try store.verifyInventory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.resolve(relativePath: recording.packageRelativePath).path))

        try Data("not json".utf8).write(to: store.consolidationJournalURL)
        XCTAssertThrowsError(try store.readConsolidationJournal())
    }

    func testRecordingImportMergeRebasesOntoConcurrentEdits() {
        let existingID = UUID()
        let existing = SourceRecording(
            id: existingID,
            ageKey: "age_5",
            ageLabel: "5 Years Old",
            packageRelativePath: "Source Recordings/age_5/existing.mov",
            originalFilename: "existing.mov",
            importSource: .finder,
            order: 4,
            recordingNumber: 9,
            mediaSignature: .init(byteCount: 10, sha256: "existing")
        )
        var session = InterviewSession(
            workflowKind: .recordingFirstV1,
            ageKey: "age_5",
            ageLabel: "5 Years Old",
            ageSortValue: 5,
            recordings: [existing]
        )
        session.revision = 7
        session.publicationFingerprint = "published-before-edit"
        session.answers["favorite_memory"] = InterviewAnswer(questionKey: "favorite_memory", state: .inProgress)
        session.revision = 8

        let imported = SourceRecording(
            id: UUID(),
            ageKey: "stale-age",
            ageLabel: "Stale Age",
            packageRelativePath: "Source Recordings/stale-age/imported.mov",
            originalFilename: "imported.mov",
            importSource: .finder,
            order: 0,
            recordingNumber: 1,
            mediaSignature: .init(byteCount: 11, sha256: "imported")
        )
        let duplicate = SourceRecording(
            id: UUID(),
            ageKey: "age_5",
            ageLabel: "5 Years Old",
            packageRelativePath: "Source Recordings/age_5/duplicate.mov",
            originalFilename: "duplicate.mov",
            importSource: .finder,
            mediaSignature: .init(byteCount: 10, sha256: "existing")
        )

        let result = session.mergeImportedRecordings([imported, duplicate], importedAtRevision: 7)

        XCTAssertTrue(result.wasRebased)
        XCTAssertEqual(result.previousRevision, 8)
        XCTAssertEqual(result.resultingRevision, 9)
        XCTAssertEqual(result.addedRecordings.count, 1)
        XCTAssertEqual(session.recordings.count, 2)
        XCTAssertEqual(session.recordings.last?.ageKey, "age_5")
        XCTAssertEqual(session.recordings.last?.order, 5)
        XCTAssertEqual(session.recordings.last?.recordingNumber, 10)
        XCTAssertEqual(session.answers["favorite_memory"]?.state, .inProgress)
        XCTAssertNil(session.publicationFingerprint)
        XCTAssertTrue(session.auditEvents.contains { $0.action == "recordings_imported" && $0.detail.contains("concurrent edits") })
    }

    func testLockGateRequiresCompleteOrSkippedAnswers() throws {
        var session = InterviewSession(ageKey: "age_6", ageLabel: "6 Years Old", ageSortValue: 6)
        session.answers["favorite_memory"] = InterviewAnswer(questionKey: "favorite_memory", state: .inProgress)
        XCTAssertThrowsError(try session.lock())

        session.answers["favorite_memory"]?.state = .skipped
        XCTAssertNoThrow(try session.lock())
        XCTAssertEqual(session.lifecycle, .locked)
        XCTAssertEqual(session.revision, 1)
    }

    func testLegacyImportAttachesPublishedClipsAndLocksImportedYears() async throws {
        let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("imported-\(UUID().uuidString).interviewstudio", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: legacyRoot)
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let clipRelativePath = "clips/favorite-memory.mov"
        let clipURL = legacyRoot.appendingPathComponent(clipRelativePath)
        try FileManager.default.createDirectory(at: clipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy clip".utf8).write(to: clipURL)

        let secondClipRelativePath = "clips/second-answer.mov"
        try Data("second legacy clip".utf8).write(to: legacyRoot.appendingPathComponent(secondClipRelativePath))

        let row = ManifestRow(
            clipNumber: "1",
            person: "Ellie",
            personKey: "ellie",
            question: "What is your favorite memory?",
            questionKey: "favorite_memory",
            age: "5 Years Old",
            ageKey: "age_5",
            ageSortKey: 5,
            outputFile: clipRelativePath
        )
        let secondRow = ManifestRow(
            clipNumber: "2",
            person: "Ellie",
            personKey: "ellie",
            question: "What is your favorite color?",
            questionKey: "favorite_color",
            age: "6 Years Old",
            ageKey: "age_6",
            ageSortKey: 6,
            outputFile: secondClipRelativePath
        )
        let manifestURL = legacyRoot.appendingPathComponent("final_manifest.json")
        try JSONEncoder.interviewStudio.encode([row, secondRow]).write(to: manifestURL, options: .atomic)

        let service = LegacyMigrationService()
        let analysis = try service.analyze(sourceFolder: legacyRoot)
        let result = try await service.import(analysis: analysis, to: packageRoot)
        let store = try InterviewStudioPackageStore(rootURL: result.packageURL)
        try store.verifyInventory()
        let sessions = try store.listSessions()
        let session = try XCTUnwrap(sessions.first(where: { $0.ageKey == "age_5" }))
        let recording = try XCTUnwrap(session.recordings.first)
        let answer = try XCTUnwrap(session.answers["favorite_memory"])
        let part = try XCTUnwrap(answer.selectedTake?.parts.first)
        let skippedAnswer = try XCTUnwrap(session.answers["favorite_color"])

        XCTAssertEqual(session.lifecycle, .locked)
        XCTAssertEqual(session.revision, 1)
        XCTAssertTrue(session.auditEvents.contains { $0.action == "legacy_import_locked" })
        XCTAssertEqual(recording.importSource, .legacy)
        XCTAssertEqual(part.sourceRecordingID, recording.id)
        XCTAssertEqual(answer.state, .complete)
        XCTAssertEqual(skippedAnswer.state, .skipped)
        XCTAssertEqual(skippedAnswer.extensions["legacy_import_assumption"], .string("blank_response"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.resolve(relativePath: recording.packageRelativePath).path))
    }

    func testInterviewAnswerRemainsReadableWithoutOptionalTranscript() throws {
        let data = Data(#"{"questionKey":"favorite_memory","selectedTakeID":null,"takes":[],"state":"not_started","lastReviewedAt":null,"extensions":{}}"#.utf8)
        let answer = try JSONDecoder.interviewStudio.decode(InterviewAnswer.self, from: data)
        XCTAssertNil(answer.transcript)
    }

    func testInterviewAnswerRoundTripsTimedTranscript() throws {
        let recordingID = UUID()
        let transcript = AnswerTranscript(
            text: "Hello there.",
            segments: [TranscriptSegment(text: "Hello there.", start: .microseconds(0), end: .microseconds(1_200_000))],
            localeIdentifier: "en_US",
            sourceRecordingID: recordingID
        )
        let answer = InterviewAnswer(questionKey: "favorite_memory", transcript: transcript)
        let data = try JSONEncoder.interviewStudio.encode(answer)
        let decoded = try JSONDecoder.interviewStudio.decode(InterviewAnswer.self, from: data)

        XCTAssertEqual(decoded.transcript?.text, "Hello there.")
        XCTAssertEqual(decoded.transcript?.segments.first?.start.microseconds, 0)
        XCTAssertEqual(decoded.transcript?.segments.first?.end.microseconds, 1_200_000)
        XCTAssertEqual(decoded.transcript?.sourceRecordingID, recordingID)
    }

    func testReadableQuestionKeysAreStableAndCollisionSafe() {
        let existing: Set<String> = ["favorite_memory", "favorite_memory_2"]
        XCTAssertEqual(InterviewStudioKey.readableKey(from: "Favorite Memory", existing: existing), "favorite_memory_3")
        XCTAssertEqual(InterviewStudioKey.readableKey(from: "  2026?  ", existing: []), "question_2026")
        XCTAssertEqual(InterviewStudioKey.safeFilenameComponent("..", fallback: "question"), "question")
    }

    func testProductionQuestionOrderIsStableAndPreservesUnknownQuestions() {
        let questions = [
            InterviewQuestion(questionKey: "unknown", displayText: "A later custom question", order: 0),
            InterviewQuestion(questionKey: "color", displayText: "What’s your favorite color?", order: 1),
            InterviewQuestion(questionKey: "what-is-your-name", displayText: "What is Your Name?", order: 2),
            InterviewQuestion(questionKey: "book", displayText: "What's your favorite book?", order: 3),
            InterviewQuestion(questionKey: "whats-your-favorite-part-of-school", displayText: "What's your favorite part of school?", order: 4),
            InterviewQuestion(questionKey: "is-there-anything-you-want-to-tell-me", displayText: "Is there anything you want to tell me?", order: 5)
        ]

        let ordered = InterviewProductionQuestionOrder.ordered(questions)
        XCTAssertEqual(ordered.map(\.questionKey), [
            "what-is-your-name",
            "color",
            "book",
            "whats-your-favorite-part-of-school",
            "is-there-anything-you-want-to-tell-me",
            "unknown"
        ])
        XCTAssertEqual(ordered.map(\.order), [0, 1, 2, 3, 4, 5])
    }

    func testManifestPathResolverRejectsTraversalAndExternalAbsoluteMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-path-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a movie".utf8).write(to: outside)

        let traversalRow = ManifestRow(
            clipNumber: "1",
            person: "Ellie",
            personKey: "ellie",
            question: "Memory",
            questionKey: "memory",
            age: "5 Years Old",
            ageKey: "age_5",
            outputFile: "../\(outside.lastPathComponent)"
        )
        let externalRow = ManifestRow(
            clipNumber: "2",
            person: "Ellie",
            personKey: "ellie",
            question: "Memory",
            questionKey: "memory",
            age: "5 Years Old",
            ageKey: "age_5",
            outputFile: "missing.mov",
            outputPath: outside.path
        )

        let resolver = ManifestPathResolver()
        let traversal = resolver.resolve(row: traversalRow, projectFolder: root)
        let external = resolver.resolve(row: externalRow, projectFolder: root)

        XCTAssertNil(traversal.resolvedURL)
        XCTAssertEqual(traversal.issues.first?.code, "UNSAFE_RELATIVE_OUTPUT_PATH")
        XCTAssertNil(external.resolvedURL)
        XCTAssertEqual(external.issues.first?.code, "ABSOLUTE_OUTPUT_PATH_OUTSIDE_PROJECT")
    }

    func testNativePublisherDoesNotOverwriteExistingOutput() async throws {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("existing-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try Data("existing output".utf8).write(to: outputURL)

        do {
            _ = try await NativeAnswerPublisher().generate(
                part: AnswerPart(sourceRecordingID: UUID(), rawMarkers: .init()),
                sourceURL: outputURL,
                outputURL: outputURL
            )
            XCTFail("An existing output must be rejected before export.")
        } catch let error as NativePublishingError {
            guard case .outputAlreadyExists(let url) = error else {
                return XCTFail("Expected outputAlreadyExists, got \(error)")
            }
            XCTAssertEqual(url, outputURL)
        }
    }

    func testLegacyNativePublisherUsesProtected4KCanvas() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-publisher-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let sourceURL = rootURL.appendingPathComponent("source-1920x1080.mov")
        let outputURL = rootURL.appendingPathComponent("legacy-answer.mov")
        try makeMediaFixture(width: 1_920, height: 1_080, duration: 2, at: sourceURL)
        let part = AnswerPart(
            sourceRecordingID: UUID(),
            rawMarkers: .init(
                answerStart: .microseconds(500_000),
                answerEnd: .microseconds(1_500_000)
            )
        )

        let inspection = try await NativeAnswerPublisher().generate(part: part, sourceURL: sourceURL, outputURL: outputURL)

        XCTAssertEqual(inspection.width, 3_840)
        XCTAssertEqual(inspection.height, 2_160)
        XCTAssertTrue(inspection.hasVideo)
        XCTAssertTrue(inspection.hasAudio)
    }

    func testNativePublisherCentersRotatedSourceOnProtectedCanvas() throws {
        let naturalSize = CGSize(width: 1_440, height: 1_080)
        let preferredTransform = CGAffineTransform(rotationAngle: -.pi / 2)
        let transform = try NativeAnswerPublisher().compositionTransform(
            for: naturalSize,
            preferredTransform: preferredTransform
        )
        let renderedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)

        XCTAssertEqual(renderedRect.width, 1_620, accuracy: 0.001)
        XCTAssertEqual(renderedRect.height, 2_160, accuracy: 0.001)
        XCTAssertEqual(renderedRect.minX, 1_110, accuracy: 0.001)
        XCTAssertEqual(renderedRect.minY, 0, accuracy: 0.001)
    }

    func testInventoryRejectsAnUnlistedPackageEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).interviewstudio", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = InterviewStudioProject(person: InterviewPerson(readableKey: "ellie", displayName: "Ellie"))
        let store = try InterviewStudioPackageStore.create(project: project, at: root)
        let unlistedURL = root.appendingPathComponent("unlisted.txt")
        try Data("unexpected".utf8).write(to: unlistedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlistedURL.path))
        let inventory = try JSONDecoder.interviewStudio.decode(PackageInventory.self, from: Data(contentsOf: store.inventoryURL))
        XCTAssertFalse(inventory.entries.contains { $0.relativePath == "unlisted.txt" })
        XCTAssertThrowsError(try store.verifyInventory()) { error in
            guard case InterviewStudioPackageError.inventoryMismatch = error else {
                return XCTFail("Expected inventory mismatch, got \(error)")
            }
        }
    }

    func testUnknownRequiredFeatureForcesReadOnlyCompatibility() {
        let descriptor = SchemaDescriptor(name: InterviewStudioSchema.project, requiredFeatures: ["vendor.future.feature"])
        guard case .readOnly(let message) = descriptor.compatibility() else {
            return XCTFail("Unknown required features must open read-only.")
        }
        XCTAssertTrue(message.contains("vendor.future.feature"))
    }

    func testBoundaryRefinementUsesSustainedSpeechAndCapsSearch() {
        let sampleRate = 1_000.0
        var samples = Array(repeating: Float(0.0001), count: 4_000)
        for index in 1_000..<2_000 {
            samples[index] = 0.15
        }
        let markers = RawAnswerMarkers(
            answerStart: .microseconds(1_050_000),
            answerEnd: .microseconds(1_900_000),
            interviewerResumes: .microseconds(2_800_000)
        )
        let result = AnswerBoundaryRefiner().refine(
            markers: markers,
            audio: AudioAnalysisBuffer(samples: samples, sampleRate: sampleRate),
            duration: .microseconds(4_000_000)
        )

        XCTAssertFalse(result.needsReview)
        XCTAssertGreaterThanOrEqual(result.speechThresholdDBFS, -36)
        XCTAssertLessThanOrEqual(result.boundaries.visibleStart.microseconds, 1_000_000)
        XCTAssertGreaterThan(result.boundaries.visibleEnd.microseconds, 1_900_000)
        XCTAssertLessThanOrEqual(result.boundaries.safeTrailingEnd.microseconds, 2_650_000)
    }

    func testLegacyRangeRestorerPreservesManifestCoordinatesAndClampsToClip() {
        let row = ManifestRow(
            clipNumber: "7", person: "Ellie", personKey: "ellie", question: "Memory", questionKey: "memory",
            age: "5 Years Old", ageKey: "age_5", outputFile: "clip.mov",
            actualHandleBeforeUS: 500_000, actualHandleAfterUS: 600_000,
            realMediaStartInOutputUS: 400_000, realMediaEndInOutputUS: 4_600_000,
            answerStartInOutputUS: 1_000_000, answerEndInOutputUS: 4_000_000
        )
        let boundaries = LegacyRangeRestorer().boundaries(for: row, durationUS: 5_000_000)
        XCTAssertEqual(boundaries.visibleStart.microseconds, 1_000_000)
        XCTAssertEqual(boundaries.visibleEnd.microseconds, 4_000_000)
        XCTAssertEqual(boundaries.safeLeadingStart.microseconds, 400_000)
        XCTAssertEqual(boundaries.safeTrailingEnd.microseconds, 4_600_000)

        let invalid = ManifestRow(
            clipNumber: "8", person: "Ellie", personKey: "ellie", question: "Memory", questionKey: "memory",
            age: "5 Years Old", ageKey: "age_5", outputFile: "invalid.mov",
            realMediaStartInOutputUS: -10, realMediaEndInOutputUS: 99_000_000,
            answerStartInOutputUS: 4_000_000, answerEndInOutputUS: 1_000_000
        )
        let fallback = LegacyRangeRestorer().boundaries(for: invalid, durationUS: 5_000_000)
        XCTAssertEqual(fallback.visibleStart.microseconds, 0)
        XCTAssertEqual(fallback.visibleEnd.microseconds, 5_000_000)
        XCTAssertEqual(fallback.safeLeadingStart.microseconds, 0)
        XCTAssertEqual(fallback.safeTrailingEnd.microseconds, 5_000_000)

        let noInspectionDuration = LegacyRangeRestorer().effectiveDurationUS(for: row, inspectedDurationUS: nil)
        XCTAssertEqual(noInspectionDuration, 4_600_000)
        let noInspection = LegacyRangeRestorer().boundaries(for: row, durationUS: noInspectionDuration)
        XCTAssertEqual(noInspection.visibleStart.microseconds, 1_000_000)
        XCTAssertEqual(noInspection.visibleEnd.microseconds, 4_000_000)
        XCTAssertEqual(noInspection.safeTrailingEnd.microseconds, 4_600_000)
    }

    func testLegacyRangeRestorerRepairsMatchingImportedPartWithoutWriting() {
        let recordingID = UUID()
        var session = InterviewSession(ageKey: "age_5", ageLabel: "5 Years Old", ageSortValue: 5)
        let part = AnswerPart(
            sourceRecordingID: recordingID,
            rawMarkers: .init(),
            refinedBoundaries: .init(visibleStart: .microseconds(0), visibleEnd: .microseconds(5_000_000), safeLeadingStart: .microseconds(0), safeTrailingEnd: .microseconds(5_000_000), confidence: 1),
            extensions: ["legacy_manifest_row": .object(["clip_number": .string("7"), "output_file": .string("clip.mov")])]
        )
        let take = AnswerTake(parts: [part])
        session.answers["memory"] = InterviewAnswer(questionKey: "memory", selectedTakeID: take.id, takes: [take], state: .complete)
        session.recordings = [SourceRecording(id: recordingID, ageKey: "age_5", ageLabel: "5 Years Old", packageRelativePath: "Legacy Published Media/clip.mov", originalFilename: "clip.mov", importSource: .legacy, mediaSignature: .init(byteCount: 1, sha256: "x", durationMicroseconds: 5_000_000))]

        let row = ManifestRow(
            clipNumber: "7", person: "Ellie", personKey: "ellie", question: "Memory", questionKey: "memory",
            age: "5 Years Old", ageKey: "age_5", outputFile: "clip.mov",
            realMediaStartInOutputUS: 500_000, realMediaEndInOutputUS: 4_500_000,
            answerStartInOutputUS: 1_000_000, answerEndInOutputUS: 4_000_000
        )
        let repaired = LegacyRangeRestorer().repair(session: session, rows: [row])
        let repairedPart = repaired.answers["memory"]?.selectedTake?.parts.first
        XCTAssertEqual(repairedPart?.rawMarkers.answerStart?.microseconds, 1_000_000)
        XCTAssertEqual(repairedPart?.rawMarkers.answerEnd?.microseconds, 4_000_000)
        XCTAssertEqual(repairedPart?.refinedBoundaries?.visibleStart.microseconds, 1_000_000)
        XCTAssertEqual(repairedPart?.refinedBoundaries?.safeTrailingEnd.microseconds, 4_500_000)
        XCTAssertEqual(repairedPart?.extensions["legacy_manifest_timing"], .object([
            "answer_start_in_output_us": .number(1_000_000),
            "answer_end_in_output_us": .number(4_000_000),
            "real_media_start_in_output_us": .number(500_000),
            "real_media_end_in_output_us": .number(4_500_000)
        ]))
    }

    func testLegacyRangeRestorerPreservesManualTimelineEdits() {
        let recordingID = UUID()
        let manualBoundaries = RefinedBoundaries(
            visibleStart: .microseconds(1_250_000),
            visibleEnd: .microseconds(3_750_000),
            safeLeadingStart: .microseconds(750_000),
            safeTrailingEnd: .microseconds(4_250_000),
            confidence: 1,
            reasons: ["Adjusted manually on the legacy timeline."],
            algorithmIdentifier: "legacy-manual-boundaries",
            manualOverride: true
        )
        var session = InterviewSession(ageKey: "age_5", ageLabel: "5 Years Old", ageSortValue: 5)
        let part = AnswerPart(
            sourceRecordingID: recordingID,
            rawMarkers: .init(answerStart: .microseconds(1_250_000), answerEnd: .microseconds(3_750_000)),
            refinedBoundaries: manualBoundaries,
            extensions: ["legacy_manifest_row": .object(["clip_number": .string("7"), "output_file": .string("clip.mov")])]
        )
        let take = AnswerTake(parts: [part])
        session.answers["memory"] = InterviewAnswer(questionKey: "memory", selectedTakeID: take.id, takes: [take], state: .inProgress)
        session.recordings = [SourceRecording(id: recordingID, ageKey: "age_5", ageLabel: "5 Years Old", packageRelativePath: "Legacy Published Media/clip.mov", originalFilename: "clip.mov", importSource: .legacy, mediaSignature: .init(byteCount: 1, sha256: "x", durationMicroseconds: 5_000_000))]

        let row = ManifestRow(
            clipNumber: "7", person: "Ellie", personKey: "ellie", question: "Memory", questionKey: "memory",
            age: "5 Years Old", ageKey: "age_5", outputFile: "clip.mov",
            realMediaStartInOutputUS: 500_000, realMediaEndInOutputUS: 4_500_000,
            answerStartInOutputUS: 1_000_000, answerEndInOutputUS: 4_000_000
        )

        let repaired = LegacyRangeRestorer().repair(session: session, rows: [row])
        let repairedPart = repaired.answers["memory"]?.selectedTake?.parts.first
        XCTAssertEqual(repairedPart?.rawMarkers.answerStart?.microseconds, 1_250_000)
        XCTAssertEqual(repairedPart?.rawMarkers.answerEnd?.microseconds, 3_750_000)
        XCTAssertEqual(repairedPart?.refinedBoundaries, manualBoundaries)
    }

    func testRecordingFirstCaptureUsesDirectTimestampsAndCommitsProvisionalPair() throws {
        var state = RecordingCaptureState()
        XCTAssertNil(try RecordingFirstWorkflow.captureIO(timestamp: .microseconds(1_000_000), state: &state, mark: "i"))
        XCTAssertEqual(state.inPoint?.microseconds, 1_000_000)
        XCTAssertThrowsError(try RecordingFirstWorkflow.captureIO(timestamp: .microseconds(900_000), state: &state, mark: "o"))
        XCTAssertNil(try RecordingFirstWorkflow.captureIO(timestamp: .microseconds(4_000_000), state: &state, mark: "o"))
        let completed = try XCTUnwrap(try RecordingFirstWorkflow.captureIO(timestamp: .microseconds(5_000_000), state: &state, mark: "i"))
        XCTAssertEqual(completed.start.microseconds, 1_000_000)
        XCTAssertEqual(completed.end.microseconds, 4_000_000)
        XCTAssertEqual(state.inPoint?.microseconds, 5_000_000)
        XCTAssertThrowsError(try RecordingFirstWorkflow.commitProvisional(&state), "The second mark is still provisional and must not be fabricated into a valid range.")
    }

    func testRecordingFirstRetainedSegmentsKeepDisjointPiecesAndRejectOverlappingCuts() throws {
        let outer = CandidateSegment(start: .microseconds(0), end: .microseconds(10_000_000))
        let retained = try RecordingFirstWorkflow.retainedSegments(
            for: outer,
            removing: [
                CandidateSegment(start: .microseconds(2_000_000), end: .microseconds(3_000_000)),
                CandidateSegment(start: .microseconds(7_000_000), end: .microseconds(8_000_000))
            ]
        )
        XCTAssertEqual(retained.map { $0.start.microseconds }, [0, 3_000_000, 8_000_000])
        XCTAssertEqual(retained.map { $0.end.microseconds }, [2_000_000, 7_000_000, 10_000_000])
        XCTAssertThrowsError(try RecordingFirstWorkflow.retainedSegments(for: outer, removing: [
            CandidateSegment(start: .microseconds(2_000_000), end: .microseconds(4_000_000)),
            CandidateSegment(start: .microseconds(3_000_000), end: .microseconds(5_000_000))
        ]))
    }

    func testRecordingFirstPublicationSegmentsAddBuffersOnlyAtRetainedBoundaries() {
        let candidate = AnswerCandidate(
            sourceRecordingID: UUID(), recordingNumber: 1, clipNumber: 1,
            rawMarkers: .init(answerStart: .microseconds(2_000_000), answerEnd: .microseconds(8_000_000)),
            refinedBoundaries: .init(
                visibleStart: .microseconds(2_000_000), visibleEnd: .microseconds(8_000_000),
                safeLeadingStart: .microseconds(1_000_000), safeTrailingEnd: .microseconds(9_000_000), confidence: 0.8
            ),
            retainedSegments: [
                CandidateSegment(start: .microseconds(2_000_000), end: .microseconds(4_000_000)),
                CandidateSegment(start: .microseconds(6_000_000), end: .microseconds(8_000_000))
            ]
        )

        let preview = RecordingFirstWorkflow.previewSegments(for: candidate, withBuffers: false)
        XCTAssertEqual(preview.map { $0.start.microseconds }, [2_000_000, 6_000_000])
        XCTAssertEqual(preview.map { $0.end.microseconds }, [4_000_000, 8_000_000])

        let publication = RecordingFirstWorkflow.publicationSegments(for: candidate)
        XCTAssertEqual(publication.map { $0.start.microseconds }, [1_000_000, 6_000_000])
        XCTAssertEqual(publication.map { $0.end.microseconds }, [4_000_000, 9_000_000])

        let timeline = RecordingFirstWorkflow.publicationTimeline(for: candidate)
        XCTAssertEqual(timeline.duration.microseconds, 5_880_000)
        XCTAssertEqual(timeline.visibleOutputRange(for: candidate)?.start.microseconds, 1_000_000)
        XCTAssertEqual(timeline.visibleOutputRange(for: candidate)?.end.microseconds, 4_880_000)
    }

    func testRecordingFirstReviewDefaultsUseTwoSecondHandlesAndThreeSecondViewport() throws {
        let visible = CandidateSegment(start: .microseconds(5_000_000), end: .microseconds(10_000_000))
        let boundaries = try XCTUnwrap(RecordingFirstWorkflow.reviewBoundaries(visible: visible, sourceDurationUS: 20_000_000))
        XCTAssertEqual(boundaries.safeLeadingStart.microseconds, 3_000_000)
        XCTAssertEqual(boundaries.safeTrailingEnd.microseconds, 12_000_000)

        let viewport = try XCTUnwrap(RecordingFirstWorkflow.reviewViewport(for: visible, sourceDurationUS: 20_000_000))
        XCTAssertEqual(viewport.start.microseconds, 2_000_000)
        XCTAssertEqual(viewport.end.microseconds, 13_000_000)
    }

    func testRecordingFirstReviewHandleEditsAreBoundedAndPreserveVisibleRange() throws {
        let visible = CandidateSegment(start: .microseconds(5_000_000), end: .microseconds(10_000_000))
        let boundaries = try XCTUnwrap(RecordingFirstWorkflow.reviewBoundaries(
            visible: visible,
            sourceDurationUS: 20_000_000,
            leadingStartUS: 0,
            trailingEndUS: 20_000_000,
            manualOverride: true
        ))
        XCTAssertEqual(boundaries.safeLeadingStart.microseconds, 2_000_000)
        XCTAssertEqual(boundaries.safeTrailingEnd.microseconds, 13_000_000)
        XCTAssertEqual(boundaries.visibleStart, visible.start)
        XCTAssertEqual(boundaries.visibleEnd, visible.end)
        XCTAssertTrue(boundaries.manualOverride)
    }

    func testRecordingFirstReviewDefaultsClampAtSourceEdges() throws {
        let visible = CandidateSegment(start: .microseconds(500_000), end: .microseconds(19_500_000))
        let boundaries = try XCTUnwrap(RecordingFirstWorkflow.reviewBoundaries(visible: visible, sourceDurationUS: 20_000_000))
        XCTAssertEqual(boundaries.safeLeadingStart.microseconds, 0)
        XCTAssertEqual(boundaries.safeTrailingEnd.microseconds, 20_000_000)
    }

    func testRecordingFirstPublisherExportsAndReinspectsInternalCuts() async throws {
        let workspace = try TestWorkspace.make()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let sourceURL = workspace.rootURL
            .appendingPathComponent("Ellie - What is Your Name", isDirectory: true)
            .appendingPathComponent("Ellie-What-is-Your-Name-5-Years-Old.mov")
        let outputURL = workspace.rootURL.appendingPathComponent("recording-first-answer.mov")
        let candidate = AnswerCandidate(
            sourceRecordingID: UUID(), recordingNumber: 1, clipNumber: 1,
            rawMarkers: .init(answerStart: .microseconds(500_000), answerEnd: .microseconds(1_500_000)),
            refinedBoundaries: .init(
                visibleStart: .microseconds(500_000), visibleEnd: .microseconds(1_500_000),
                safeLeadingStart: .microseconds(250_000), safeTrailingEnd: .microseconds(1_750_000), confidence: 0.9
            ),
            retainedSegments: [
                CandidateSegment(start: .microseconds(500_000), end: .microseconds(750_000)),
                CandidateSegment(start: .microseconds(800_000), end: .microseconds(1_050_000)),
                CandidateSegment(start: .microseconds(1_100_000), end: .microseconds(1_500_000))
            ],
            reviewState: .approved
        )

        let timeline = RecordingFirstWorkflow.publicationTimeline(for: candidate)
        XCTAssertEqual(timeline.duration.microseconds, 1_160_000)
        let inspection = try await NativeAnswerPublisher().generate(candidate: candidate, sourceURL: sourceURL, outputURL: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(inspection.width, 3_840)
        XCTAssertEqual(inspection.height, 2_160)
        XCTAssertTrue(inspection.hasVideo)
        XCTAssertTrue(inspection.hasAudio)
        XCTAssertGreaterThan(inspection.duration.microseconds, 0)
        XCTAssertEqual(inspection.duration.microseconds, timeline.duration.microseconds, accuracy: 50_000)

        let ffmpegPath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFMPEG"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
        let centerPixelProbe = Process()
        centerPixelProbe.executableURL = URL(fileURLWithPath: ffmpegPath)
        centerPixelProbe.arguments = [
            "-v", "error", "-ss", "0.5", "-i", outputURL.path,
            "-vf", "crop=1:1:1920:1080,format=rgb24", "-frames:v", "1", "-f", "rawvideo", "pipe:1"
        ]
        let centerPixelPipe = Pipe()
        centerPixelProbe.standardOutput = centerPixelPipe
        centerPixelProbe.standardError = FileHandle.nullDevice
        try centerPixelProbe.run()
        let centerPixel = centerPixelPipe.fileHandleForReading.readDataToEndOfFile()
        centerPixelProbe.waitUntilExit()
        XCTAssertEqual(centerPixelProbe.terminationStatus, 0)
        XCTAssertGreaterThan(centerPixel.count, 2)
        XCTAssertGreaterThan(centerPixel[0], 120, "The composed source should fill the centered 4K frame instead of remaining in the upper-left corner.")
    }

    func testRecordingFirstAssignmentsAreOneToOneAndLockAllowsWarningsOnly() throws {
        let recording = SourceRecording(
            ageKey: "age_5", ageLabel: "Age 5", packageRelativePath: "Source Recordings/clip.mov",
            originalFilename: "clip.mov", importSource: .finder, order: 0, recordingNumber: 1,
            mediaSignature: .init(byteCount: 10, sha256: "hash", durationMicroseconds: 10_000_000)
        )
        let candidate = AnswerCandidate(
            sourceRecordingID: recording.id, recordingNumber: 1, clipNumber: 1,
            rawMarkers: .init(answerStart: .microseconds(1_000_000), answerEnd: .microseconds(3_000_000)),
            retainedSegments: [CandidateSegment(start: .microseconds(1_000_000), end: .microseconds(3_000_000))],
            reviewState: .approved
        )
        var session = InterviewSession(workflowKind: .recordingFirstV1, ageKey: "age_5", ageLabel: "Age 5", ageSortValue: 5, recordings: [recording], candidates: [candidate])
        try RecordingFirstWorkflow.assign(candidateID: candidate.id, to: "memory", in: &session)
        XCTAssertEqual(session.answers["memory"]?.assignedCandidateID, candidate.id)
        XCTAssertThrowsError(try RecordingFirstWorkflow.assign(candidateID: candidate.id, to: "color", in: &session))
        XCTAssertTrue(RecordingFirstWorkflow.readiness(for: session, requiredQuestionKeys: ["memory"]).isReady)

        let warnings = try session.lockWithWarnings()
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(session.lifecycle, .locked)
    }

    func testRecordingFirstReadinessBlocksMissingOrInvalidCandidateMedia() {
        let recording = SourceRecording(
            ageKey: "age_5", ageLabel: "Age 5", packageRelativePath: "Source Recordings/clip.mov",
            originalFilename: "clip.mov", importSource: .finder, order: 0, recordingNumber: 1,
            mediaSignature: .init(byteCount: 10, sha256: "hash", durationMicroseconds: 2_000_000)
        )
        let missingSourceCandidate = AnswerCandidate(
            sourceRecordingID: UUID(), recordingNumber: 1, clipNumber: 1,
            rawMarkers: .init(answerStart: .microseconds(0), answerEnd: .microseconds(1_000_000)),
            retainedSegments: [CandidateSegment(start: .microseconds(0), end: .microseconds(1_000_000))],
            reviewState: .approved
        )
        let invalidRangeCandidate = AnswerCandidate(
            sourceRecordingID: recording.id, recordingNumber: 1, clipNumber: 2,
            rawMarkers: .init(answerStart: .microseconds(0), answerEnd: .microseconds(3_000_000)),
            refinedBoundaries: .init(
                visibleStart: .microseconds(0), visibleEnd: .microseconds(3_000_000),
                safeLeadingStart: .zero, safeTrailingEnd: .microseconds(3_000_000), confidence: 0.5
            ),
            retainedSegments: [CandidateSegment(start: .microseconds(0), end: .microseconds(3_000_000))],
            reviewState: .approved
        )
        let session = InterviewSession(
            workflowKind: .recordingFirstV1, ageKey: "age_5", ageLabel: "Age 5", ageSortValue: 5,
            recordings: [recording], candidates: [missingSourceCandidate, invalidRangeCandidate]
        )
        let report = RecordingFirstWorkflow.readiness(for: session)
        XCTAssertTrue(report.blockers.contains { $0.contains("missing source recording") })
        XCTAssertTrue(report.blockers.contains { $0.contains("extends beyond its source recording") })
    }

    func testRecordingFirstAgeIdentityAndArchiveRestoreAreStable() throws {
        let normalized = try XCTUnwrap(RecordingFirstWorkflow.normalizedAge(value: 5))
        XCTAssertEqual(normalized.key, "age_5")
        XCTAssertEqual(normalized.label, "5 Years Old")
        var session = InterviewSession(workflowKind: .recordingFirstV1, ageKey: normalized.key, ageLabel: normalized.label, ageSortValue: normalized.sortValue)
        XCTAssertTrue(RecordingFirstWorkflow.sameAge(session, normalized: normalized))
        try session.archive()
        XCTAssertTrue(session.isArchived)
        try session.restore()
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.ageKey, "age_5")
    }

    func testRecordingFirstDisplayAgeLabelRepairsLegacyPresentationText() {
        let session = InterviewSession(
            workflowKind: .recordingFirstV1,
            ageKey: "age_10",
            ageLabel: "Age 10",
            ageSortValue: 10
        )

        XCTAssertEqual(RecordingFirstWorkflow.displayAgeLabel(for: session), "10 Years Old")
    }

    func testRecordingFirstSchemaAddsDefaultsAndUnknownWorkflowIsReadOnly() throws {
        let recording = SourceRecording(
            ageKey: "age_5", ageLabel: "5 Years Old", packageRelativePath: "Source Recordings/clip.mov",
            originalFilename: "clip.mov", importSource: .finder, mediaSignature: .init(byteCount: 1, sha256: "hash")
        )
        let session = InterviewSession(ageKey: "age_5", ageLabel: "5 Years Old", ageSortValue: 5, recordings: [recording])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.interviewStudio.encode(session)) as? [String: Any])
        object.removeValue(forKey: "workflowKind")
        object.removeValue(forKey: "candidates")
        var recordingObject = try XCTUnwrap((object["recordings"] as? [[String: Any]])?.first)
        recordingObject.removeValue(forKey: "recordingNumber")
        recordingObject.removeValue(forKey: "recordingState")
        recordingObject.removeValue(forKey: "provisionalInPointUS")
        object["recordings"] = [recordingObject]
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.interviewStudio.decode(InterviewSession.self, from: oldData)
        XCTAssertEqual(decoded.workflowKind, .questionFirstV1)
        XCTAssertEqual(decoded.recordings.first?.recordingNumber, 1)
        XCTAssertEqual(decoded.recordings.first?.recordingState, .notStarted)

        object["workflowKind"] = "future_recording_workflow"
        let futureData = try JSONSerialization.data(withJSONObject: object)
        let future = try JSONDecoder.interviewStudio.decode(InterviewSession.self, from: futureData)
        XCTAssertFalse(future.compatibility.isWritable)
    }

    private func makeMediaFixture(width: Int, height: Int, duration: Int, at outputURL: URL) throws {
        let ffmpegPath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFMPEG"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-f", "lavfi",
            "-i", "color=c=red:s=\(width)x\(height):d=\(duration):r=30",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=\(duration)",
            "-map", "0:v",
            "-map", "1:a",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-shortest",
            outputURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
