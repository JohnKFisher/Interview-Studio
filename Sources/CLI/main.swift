import Core
import Foundation

@main
struct YearlyInterviewStudioCLI {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let folderPath = arguments.first else {
            fputs("usage: YearlyInterviewStudioCLI <project-folder> [output-root]\n", stderr)
            Foundation.exit(2)
        }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let outputRoot = arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let diagnosticsRoot = outputRoot?.appendingPathComponent("Diagnostics", isDirectory: true)
        let manifestURL = folderURL.appendingPathComponent("final_manifest.json")
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: manifestURL, projectFolder: folderURL)
        let document = ProjectDocument.makeDefault(for: loaded)
        let plan = RenderPlanBuilder().build(project: loaded, document: document)
        let renderer = Renderer()

        let result = try await renderer.render(plan: plan, diagnosticsRoot: diagnosticsRoot, outputRoot: outputRoot) { state in
            print("[\(state.phase)] \(state.detail)")
        }

        print("render_output=\(result.outputURL.path)")
        print("diagnostics=\(result.diagnosticsURL.path)")
    }
}
