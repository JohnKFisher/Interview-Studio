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

    func testLegacyImportAttachesPublishedClipsAndLocksImportedYears() throws {
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
        let manifestURL = legacyRoot.appendingPathComponent("final_manifest.json")
        try JSONEncoder.interviewStudio.encode([row]).write(to: manifestURL, options: .atomic)

        let service = LegacyMigrationService()
        let analysis = try service.analyze(sourceFolder: legacyRoot)
        let result = try service.import(analysis: analysis, to: packageRoot)
        let store = try InterviewStudioPackageStore(rootURL: result.packageURL)
        try store.verifyInventory()
        let session = try XCTUnwrap(store.listSessions().first)
        let recording = try XCTUnwrap(session.recordings.first)
        let answer = try XCTUnwrap(session.answers["favorite_memory"])
        let part = try XCTUnwrap(answer.selectedTake?.parts.first)

        XCTAssertEqual(session.lifecycle, .locked)
        XCTAssertEqual(session.revision, 1)
        XCTAssertTrue(session.auditEvents.contains { $0.action == "legacy_import_locked" })
        XCTAssertEqual(recording.importSource, .legacy)
        XCTAssertEqual(part.sourceRecordingID, recording.id)
        XCTAssertEqual(answer.state, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.resolve(relativePath: recording.packageRelativePath).path))
    }

    func testReadableQuestionKeysAreStableAndCollisionSafe() {
        let existing: Set<String> = ["favorite_memory", "favorite_memory_2"]
        XCTAssertEqual(InterviewStudioKey.readableKey(from: "Favorite Memory", existing: existing), "favorite_memory_3")
        XCTAssertEqual(InterviewStudioKey.readableKey(from: "  2026?  ", existing: []), "question_2026")
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
}
