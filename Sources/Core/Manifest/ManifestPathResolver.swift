import Foundation

public struct ManifestPathResolution: Sendable {
    public var resolvedURL: URL?
    public var issues: [AssemblyIssue]
}

public struct ManifestPathResolver {
    public init() {}

    public func resolve(row: ManifestRow, projectFolder: URL) -> ManifestPathResolution {
        let relativeURL = projectFolder.appendingPathComponent(row.outputFile)
        if FileManager.default.fileExists(atPath: relativeURL.path) {
            return .init(resolvedURL: relativeURL, issues: [])
        }

        if let outputPath = row.outputPath, !outputPath.isEmpty {
            let absoluteURL = URL(fileURLWithPath: outputPath)
            if FileManager.default.fileExists(atPath: absoluteURL.path) {
                return .init(
                    resolvedURL: absoluteURL,
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
                        "selected_project_folder": .string(projectFolder.path),
                        "absolute_path": .string(row.outputPath ?? "")
                    ],
                    suggestedFix: "Confirm the selected project folder is correct or regenerate the missing clip."
                )
            ]
        )
    }
}
