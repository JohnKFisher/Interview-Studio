import Core
import XCTest

final class ManifestAndRenderPlanTests: XCTestCase {
    func testManifestParsesIntoTypedRows() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture_manifest", withExtension: "json"))
        let rows = try ManifestParser().parse(url: url)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.questionKey, "what-is-your-name")
        XCTAssertEqual(rows.first?.ageSortKey, 5)
        XCTAssertTrue(rows.allSatisfy(\.isUsableStatus))
    }

    func testProjectLoadsAndRenderPlanBuilds() throws {
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        XCTAssertEqual(loaded.questions.count, 1)
        XCTAssertEqual(loaded.questions.first?.clips.count, 2)

        let document = ProjectDocument.makeDefault(for: loaded)
        let plan = RenderPlanBuilder().build(project: loaded, document: document)

        XCTAssertEqual(plan.summary.questionCount, 1)
        XCTAssertEqual(plan.summary.answerClipCount, 2)
        XCTAssertTrue(plan.summary.exportAllowed)
        XCTAssertTrue(plan.sequence.contains { $0.type == .openingCard })
        XCTAssertTrue(plan.sequence.contains { $0.type == .closingCard })
        let answerBoundary = try XCTUnwrap(plan.boundaries.first(where: { $0.boundaryType == "answer_to_answer" }))
        XCTAssertEqual(plan.boundaries.filter { $0.boundaryType == "answer_to_answer" }.count, 1)
        XCTAssertEqual(answerBoundary.audio.mode, "full_crossfade")
    }

    func testSpeechyHandlesFallBackToConservativeTransitionAudio() throws {
        let workspace = try TestWorkspace.make(audioProfile: .speechyHandles)
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        let document = ProjectDocument.makeDefault(for: loaded)
        let plan = RenderPlanBuilder().build(project: loaded, document: document)

        let answerBoundary = try XCTUnwrap(plan.boundaries.first(where: { $0.boundaryType == "answer_to_answer" }))
        XCTAssertEqual(answerBoundary.audio.mode, "silence_gap")
    }

    func testPreviewSelectionPrefersLongestQuestionOverlay() {
        let shortNode = RenderSequenceNode(
            nodeID: "answer-short",
            type: .answerClip,
            text: nil,
            template: nil,
            questionKey: "q1",
            questionText: "Short",
            clipRef: nil,
            identity: nil,
            timing: nil,
            handles: nil,
            video: nil,
            overlays: [],
            audio: nil,
            confidence: nil,
            issues: []
        )
        let longNode = RenderSequenceNode(
            nodeID: "answer-long",
            type: .answerClip,
            text: nil,
            template: nil,
            questionKey: "q2",
            questionText: "This is the much longer overlay question text for the preview chooser.",
            clipRef: nil,
            identity: nil,
            timing: nil,
            handles: nil,
            video: nil,
            overlays: [],
            audio: nil,
            confidence: nil,
            issues: []
        )
        let plan = RenderPlan(
            schemaVersion: "1.0",
            appName: "Test",
            project: .init(projectID: "p", projectName: "P", manifestPath: "", mediaRoot: ""),
            exportProfile: .rendererTest,
            settings: .default,
            sequence: [shortNode, longNode],
            boundaries: [],
            issues: [],
            summary: .init(
                questionCount: 0,
                answerClipCount: 2,
                estimatedRuntimeSeconds: 0,
                blockerCount: 0,
                warningCount: 0,
                infoCount: 0,
                confidenceCounts: .init(high: 0, medium: 0, low: 0),
                transitionCounts: .init(realHandleCrossfade: 0, syntheticCrossfade: 0, cleanCutFallback: 0),
                exportAllowed: true
            )
        )

        XCTAssertEqual(PreviewSelection.riskiestOverlayNode(in: plan)?.nodeID, "answer-long")
    }
}
