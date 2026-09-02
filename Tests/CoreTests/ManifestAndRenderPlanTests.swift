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

        var document = ProjectDocument.makeDefault(for: loaded)
        makePlexReady(&document)
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

    func testRenderPlanIssuesAndSummaryAreDeterministic() throws {
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        let document = ProjectDocument.makeDefault(for: loaded)

        let first = RenderPlanBuilder().build(project: loaded, document: document)
        let second = RenderPlanBuilder().build(project: loaded, document: document)

        XCTAssertEqual(first.issues, second.issues)
        XCTAssertEqual(first.summary.blockerCount, first.issues.filter { $0.severity == .blocker }.count)
        XCTAssertEqual(first.summary.warningCount, first.issues.filter { $0.severity == .warning }.count)
        XCTAssertEqual(first.summary.infoCount, first.issues.filter { $0.severity == .info }.count)
        XCTAssertEqual(try JSONEncoder.interviewStudio.encode(first), try JSONEncoder.interviewStudio.encode(second))
    }

    func testSpeechyHandlesFallBackToConservativeTransitionAudio() throws {
        let workspace = try TestWorkspace.make(audioProfile: .speechyHandles)
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        var document = ProjectDocument.makeDefault(for: loaded)
        makePlexReady(&document)
        let plan = RenderPlanBuilder().build(project: loaded, document: document)

        let answerBoundary = try XCTUnwrap(plan.boundaries.first(where: { $0.boundaryType == "answer_to_answer" }))
        XCTAssertEqual(answerBoundary.audio.mode, "silence_gap")
    }

    func testTitleCaseAppliesToRenderedQuestionTextOnly() throws {
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        var document = ProjectDocument.makeDefault(for: loaded)
        document.questionDisplayTexts["what-is-your-name"] = "what is your name in the world?"
        makePlexReady(&document)

        let plan = RenderPlanBuilder().build(project: loaded, document: document)
        let questionNode = try XCTUnwrap(plan.sequence.first(where: { $0.type == .questionCard }))
        XCTAssertEqual(questionNode.questionText, "What Is Your Name in the World?")
        XCTAssertEqual(document.questionDisplayTexts["what-is-your-name"], "what is your name in the world?")
    }

    func testPlexMetadataMissingBlocksExport() throws {
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        let document = ProjectDocument.makeDefault(for: loaded)

        let plan = RenderPlanBuilder().build(project: loaded, document: document)
        XCTAssertFalse(plan.summary.exportAllowed)
        XCTAssertTrue(plan.issues.contains(where: { $0.code == "PLEX_METADATA_INCOMPLETE" }))
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
            plexMetadata: nil,
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

    private func makePlexReady(_ document: inout ProjectDocument) {
        document.plexMetadata.show = "Family Interviews"
        document.plexMetadata.season = "2026"
        document.plexMetadata.episode = "3"
        document.plexMetadata.episodeTitle = document.openingTitle
        document.plexMetadata.summary = "Test summary"
    }
}
