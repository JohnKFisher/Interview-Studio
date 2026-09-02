import Core
import XCTest

final class RendererTests: XCTestCase {
    func testRenderOutputValidatorRejectsWrongCodecAndAcceptsProtectedProfile() throws {
        let base = MediaInspectionResult(
            url: URL(fileURLWithPath: "/tmp/output.mov"),
            durationSeconds: 10,
            width: 640,
            height: 360,
            frameRate: 30,
            pixFmt: "yuv420p10le",
            colorSpace: "bt2020nc",
            colorTransfer: "arib-std-b67",
            colorPrimaries: "bt2020",
            hasAudio: true,
            audioChannels: 2,
            colorInfo: ColorInfo(isHDR: true, colorPrimaries: "bt2020", transferFunction: "arib-std-b67", transferFlavor: .hlg, isDisplayP3Like: false),
            codecName: "hevc",
            formatName: "mov"
        )
        XCTAssertNoThrow(try RenderOutputValidator().validate(base, against: .rendererTest, expectedDurationSeconds: 10))

        var wrongCodec = base
        wrongCodec.codecName = "h264"
        XCTAssertThrowsError(try RenderOutputValidator().validate(wrongCodec, against: .rendererTest))
    }

    func testRendererProducesPlayableMovie() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RENDERER_SMOKE_TESTS"] == "1" else {
            throw XCTSkip("Renderer smoke test is opt-in because it depends on the local ffmpeg toolchain and GUI template rendering support.")
        }
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        var document = ProjectDocument.makeDefault(for: loaded)
        document.plexMetadata.show = "Family Interviews"
        document.plexMetadata.season = "2026"
        document.plexMetadata.episode = "3"
        document.plexMetadata.episodeTitle = document.openingTitle
        document.plexMetadata.summary = "Renderer smoke"
        let plan = RenderPlanBuilder().build(project: loaded, document: document, exportProfile: .rendererTest)

        let renderer = Renderer()
        let outputRoot = workspace.rootURL.appendingPathComponent("Output", isDirectory: true)
        let diagnosticsRoot = workspace.rootURL.appendingPathComponent("Diagnostics", isDirectory: true)
        let result = try await renderer.render(plan: plan, diagnosticsRoot: diagnosticsRoot, outputRoot: outputRoot, keepSuccessfulDiagnostics: true) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int64 ?? 0, 0)
        let plexOutputURL = try XCTUnwrap(result.plexOutputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plexOutputURL.path))
        XCTAssertNotNil(result.diagnosticsURL)

        let ffprobePath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFPROBE"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe"
        let ffprobeOutput = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_chapters",
                plexOutputURL.path
            ]
        )

        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ffprobeOutput.stdout.utf8)) as? [String: Any])
        let format = try XCTUnwrap(metadata["format"] as? [String: Any])
        let tags = try XCTUnwrap(format["tags"] as? [String: Any])
        XCTAssertEqual(tags["title"] as? String, document.plexMetadata.episodeTitle)
        XCTAssertEqual(tags["show"] as? String, document.plexMetadata.show)
        XCTAssertEqual(tags["date"] as? String, document.plexMetadata.season)
        XCTAssertFalse((tags["creation_time"] as? String ?? "").isEmpty)

        let chapters = metadata["chapters"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(chapters.count, 2)
    }
}
