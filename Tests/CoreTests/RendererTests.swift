import Core
import XCTest

final class RendererTests: XCTestCase {
    func testRendererProducesPlayableMovie() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RENDERER_SMOKE_TESTS"] == "1" else {
            throw XCTSkip("Renderer smoke test is opt-in because it depends on the local ffmpeg toolchain and GUI template rendering support.")
        }
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        let document = ProjectDocument.makeDefault(for: loaded)
        let plan = RenderPlanBuilder().build(project: loaded, document: document, exportProfile: .rendererTest)

        let renderer = Renderer()
        let outputRoot = workspace.rootURL.appendingPathComponent("Output", isDirectory: true)
        let diagnosticsRoot = workspace.rootURL.appendingPathComponent("Diagnostics", isDirectory: true)
        let result = try await renderer.render(plan: plan, diagnosticsRoot: diagnosticsRoot, outputRoot: outputRoot) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int64 ?? 0, 0)
    }
}
