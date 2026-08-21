import Core
import Foundation

@main
struct YearlyInterviewStudioCLI {
    static func main() async throws {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let first = arguments.first else {
            printUsage()
            Foundation.exit(2)
        }

        switch first {
        case "inspect-package":
            try inspectPackage(at: try pathArgument(arguments, index: 1))
        case "validate-package":
            try validatePackage(at: try pathArgument(arguments, index: 1))
        case "generate-manifest":
            try await generateManifest(packageURL: try pathArgument(arguments, index: 1), outputURL: try requiredOption("--output", in: arguments))
        case "generate-answer":
            try await generateAnswer(
                packageURL: try pathArgument(arguments, index: 1),
                sessionID: try requiredUUIDOption("--session", in: arguments),
                questionKey: try requiredOption("--question", in: arguments).pathValue,
                outputURL: try requiredOption("--output", in: arguments)
            )
        case "render":
            try await renderPackage(packageURL: try pathArgument(arguments, index: 1), outputURL: try requiredOption("--output", in: arguments))
        case "--help", "-h":
            printUsage()
        default:
            try await renderLegacyProject(folderURL: URL(fileURLWithPath: first, isDirectory: true), outputRoot: arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
    }

    private static func inspectPackage(at url: URL) throws {
        let store = try InterviewStudioPackageStore(rootURL: url)
        let project = try store.readProjectAllowingReadOnly()
        print("package=\(store.rootURL.path)")
        print("project_id=\(project.projectID.uuidString)")
        print("person=\(project.person.displayName)")
        print("schema=\(project.schema.major).\(project.schema.minor)")
        print("compatibility=\(project.compatibility)")
        print("questions=\(project.questions.count)")
        print("sessions=\(try store.listSessions().count)")
        if FileManager.default.fileExists(atPath: store.inventoryURL.path) {
            try store.verifyInventory()
            print("inventory=verified")
        } else {
            print("inventory=missing")
        }
    }

    private static func validatePackage(at url: URL) throws {
        let store = try InterviewStudioPackageStore(rootURL: url)
        let project = try store.readProjectAllowingReadOnly()
        guard project.compatibility.isWritable else { throw InterviewStudioPackageError.incompatible(project.compatibility) }
        try store.verifyInventory()
        let sessions = try store.listSessions()
        for session in sessions {
            guard session.compatibility.isWritable else { throw InterviewStudioPackageError.incompatible(session.compatibility) }
            for recording in session.recordings {
                let source = try store.resolve(relativePath: recording.packageRelativePath)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw InterviewStudioPackageError.invalidPackage("Missing source recording \(recording.packageRelativePath).")
                }
                guard sha256(fileURL: source) == recording.mediaSignature.sha256 else {
                    throw InterviewStudioPackageError.inventoryMismatch("Source recording \(recording.packageRelativePath) does not match its recorded SHA-256.")
                }
            }
        }
        print("valid package=\(store.rootURL.path)")
        print("sessions=\(sessions.count)")
        print("authoritative sources=\(sessions.reduce(0) { $0 + $1.recordings.count })")
    }

    private static func generateManifest(packageURL: URL, outputURL: URL) async throws {
        let store = try InterviewStudioPackageStore(rootURL: packageURL)
        let project = try store.readProject()
        let sessions = try store.listSessions()
        guard !sessions.isEmpty else { throw InterviewStudioPackageError.invalidPackage("The package contains no interview sessions.") }
        try createNewDirectory(outputURL)
        let builder = ManifestPublicationBuilder()
        var rows: [ManifestRow] = []
        for session in sessions {
            let result = try await builder.build(project: project, session: session, store: store, buildRoot: outputURL.appendingPathComponent(".staging", isDirectory: true))
            for row in result.rows {
                let source = result.buildRoot.appendingPathComponent(row.outputFile)
                let destination = outputURL.appendingPathComponent(row.outputFile)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
                rows.append(row)
            }
        }
        let manifestURL = outputURL.appendingPathComponent("final_manifest.json")
        try JSONEncoder.interviewStudio.encode(rows).write(to: manifestURL, options: .atomic)
        print("manifest=\(manifestURL.path)")
        print("rows=\(rows.count)")
    }

    private static func generateAnswer(packageURL: URL, sessionID: UUID, questionKey: String, outputURL: URL) async throws {
        let store = try InterviewStudioPackageStore(rootURL: packageURL)
        let session = try store.readSession(id: sessionID)
        guard let answer = session.answers[questionKey], let take = answer.selectedTake, let part = take.parts.first else {
            throw NativePublishingError.missingSelectedTake(questionKey)
        }
        guard take.parts.count == 1, !take.isMultiPart else {
            throw NativePublishingError.unsupportedMultiPart(questionKey)
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw InterviewStudioPackageError.fileExists(outputURL)
        }
        guard let recording = session.recordings.first(where: { $0.id == part.sourceRecordingID }) else {
            throw NativePublishingError.sourceMissing(part.sourceRecordingID.uuidString)
        }
        let sourceURL = try store.resolve(relativePath: recording.packageRelativePath)
        _ = try await NativeAnswerPublisher().generate(part: part, sourceURL: sourceURL, outputURL: outputURL)
        print("answer=\(outputURL.path)")
    }

    private static func renderPackage(packageURL: URL, outputURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw InterviewStudioPackageError.fileExists(outputURL) }
        let manifestURL = try findGeneratedManifest(in: packageURL)
        let mediaRoot = manifestURL.deletingLastPathComponent()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: manifestURL, projectFolder: mediaRoot)
        let document = ProjectDocument.makeDefault(for: loaded)
        let result = try await Renderer().render(plan: RenderPlanBuilder().build(project: loaded, document: document), outputRoot: outputURL.deletingLastPathComponent()) { state in
            print("[\(state.phase)] \(state.detail)")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: result.outputURL, to: outputURL)
        print("render_output=\(outputURL.path)")
    }

    private static func renderLegacyProject(folderURL: URL, outputRoot: URL?) async throws {
        let manifestURL = folderURL.appendingPathComponent("final_manifest.json")
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: manifestURL, projectFolder: folderURL)
        let document = ProjectDocument.makeDefault(for: loaded)
        let plan = RenderPlanBuilder().build(project: loaded, document: document)
        let diagnosticsRoot = outputRoot?.appendingPathComponent("Diagnostics")
        let result = try await Renderer().render(plan: plan, diagnosticsRoot: diagnosticsRoot, outputRoot: outputRoot, keepSuccessfulDiagnostics: true) { state in
            print("[\(state.phase)] \(state.detail)")
        }
        print("render_output=\(result.outputURL.path)")
        if let plexOutputURL = result.plexOutputURL { print("plex_output=\(plexOutputURL.path)") }
        if let diagnosticsURL = result.diagnosticsURL { print("diagnostics=\(diagnosticsURL.path)") }
    }

    private static func findGeneratedManifest(in packageURL: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: packageURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw InterviewStudioPackageError.invalidPackage("Could not enumerate the package.")
        }
        let candidates = enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == "final_manifest.json" &&
            !$0.path.contains("/Documentation/") &&
            !$0.path.contains("/.staging/")
        }
        guard let candidate = candidates.sorted(by: { $0.path < $1.path }).first else {
            throw InterviewStudioPackageError.invalidPackage("No generated final_manifest.json exists. Generate the manifest before rendering.")
        }
        return candidate
    }

    private static func pathArgument(_ arguments: [String], index: Int) throws -> URL {
        guard arguments.indices.contains(index) else { throw CLIError.missingArgument }
        return URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL
    }

    private static func requiredOption(_ option: String, in arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { throw CLIError.missingOption(option) }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func requiredUUIDOption(_ option: String, in arguments: [String]) throws -> UUID {
        let value = try requiredOption(option, in: arguments).pathValue
        guard let uuid = UUID(uuidString: value) else { throw CLIError.invalidOption(option) }
        return uuid
    }

    private static func createNewDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw InterviewStudioPackageError.fileExists(url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func printUsage() {
        print("""
        usage:
          YearlyInterviewStudioCLI <legacy-project-folder> [output-root]
          YearlyInterviewStudioCLI inspect-package <package>
          YearlyInterviewStudioCLI validate-package <package>
          YearlyInterviewStudioCLI generate-manifest <package> --output <directory>
          YearlyInterviewStudioCLI generate-answer <package> --session <id> --question <key> --output <file>
          YearlyInterviewStudioCLI render <package> --output <master.mov>
        """)
    }
}

private enum CLIError: LocalizedError {
    case missingArgument
    case missingOption(String)
    case invalidOption(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument: return "A required command argument is missing."
        case .missingOption(let option): return "Missing required option \(option)."
        case .invalidOption(let option): return "The value for \(option) is invalid."
        }
    }
}

private extension URL {
    var pathValue: String { path }
}
