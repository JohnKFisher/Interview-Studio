import Foundation

public struct ManifestPathResolution: Sendable {
    public var resolvedURL: URL?
    public var issues: [AssemblyIssue]
}

public struct ManifestPathResolver {
    public init() {}

    public func resolve(row: ManifestRow, projectFolder: URL) -> ManifestPathResolution {
        let projectRoot = projectFolder.standardizedFileURL.resolvingSymlinksInPath()

        if isSafeRelativePath(row.outputFile) {
            let relativeURL = projectRoot.appendingPathComponent(row.outputFile).standardizedFileURL
            if let safeURL = existingURL(relativeURL, within: projectRoot) {
                return .init(resolvedURL: safeURL, issues: [])
            }
        } else if !row.outputFile.isEmpty {
            return .init(
                resolvedURL: nil,
                issues: [unsafePathIssue(row: row, code: "UNSAFE_RELATIVE_OUTPUT_PATH", message: "The manifest's relative output path is not a safe project-relative path.")]
            )
        }

        if let outputPath = row.outputPath, !outputPath.isEmpty {
            guard outputPath.hasPrefix("/") else {
                return .init(
                    resolvedURL: nil,
                    issues: [unsafePathIssue(row: row, code: "UNSAFE_ABSOLUTE_OUTPUT_PATH", message: "The manifest's fallback output path is not an absolute local path.")]
                )
            }
            let absoluteURL = URL(fileURLWithPath: outputPath)
            if let safeURL = existingURL(absoluteURL, within: projectRoot) {
                return .init(
                    resolvedURL: safeURL,
                    issues: [
                        AssemblyIssue(
                            severity: .warning,
                            code: "USED_ABSOLUTE_OUTPUT_PATH",
                            humanMessage: "The clip for '\(row.question)' at \(row.age) was found via the manifest's absolute output path instead of the selected project folder.",
                            aiContext: [
                                "question_key": .string(row.questionKey),
                                "age_key": .string(row.ageKey),
                                "relative_path": .string(row.outputFile),
                                "absolute_path": .string(outputPath)
                            ],
                            suggestedFix: "Keep the project folder and manifest together so relative path lookup succeeds."
                        )
                    ]
                )
            }

            if FileManager.default.fileExists(atPath: absoluteURL.path) {
                return .init(
                    resolvedURL: nil,
                    issues: [unsafePathIssue(row: row, code: "ABSOLUTE_OUTPUT_PATH_OUTSIDE_PROJECT", message: "The manifest points outside the selected project folder, so the clip was not opened.")]
                )
            }
        }

        return .init(
            resolvedURL: nil,
            issues: [
                AssemblyIssue(
                    severity: .blocker,
                    code: "MISSING_MEDIA_FILE",
                    humanMessage: "Cannot find the exported clip for '\(row.question)' at \(row.age).",
                    aiContext: [
                        "question_key": .string(row.questionKey),
                        "age_key": .string(row.ageKey),
                        "relative_path": .string(row.outputFile),
                        "selected_project_folder": .string(projectRoot.path),
                        "absolute_path": .string(row.outputPath ?? "")
                    ],
                    suggestedFix: "Confirm the selected project folder is correct or regenerate the missing clip."
                )
            ]
        )
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !components.isEmpty && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func existingURL(_ candidate: URL, within root: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path == resolvedRoot.path || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return resolvedCandidate
    }

    private func unsafePathIssue(row: ManifestRow, code: String, message: String) -> AssemblyIssue {
        AssemblyIssue(
            severity: .blocker,
            code: code,
            humanMessage: message,
            aiContext: [
                "question_key": .string(row.questionKey),
                "age_key": .string(row.ageKey),
                "relative_path": .string(row.outputFile),
                "absolute_path": .string(row.outputPath ?? "")
            ],
            suggestedFix: "Keep generated media inside the selected project folder and use a normalized relative output path."
        )
    }
}
