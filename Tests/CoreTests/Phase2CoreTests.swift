import Core
import Foundation
import XCTest

final class Phase2CoreTests: XCTestCase {
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
}
