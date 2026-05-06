import Foundation

public struct ResolvedManifestClip: Hashable, Sendable {
    public var row: ManifestRow
    public var resolvedURL: URL
}

public struct QuestionGroup: Hashable, Sendable, Identifiable {
    public var id: String { questionKey }
    public var questionKey: String
    public var displayText: String
    public var originalIndex: Int
    public var clips: [ResolvedManifestClip]
    public var missingAges: [String]
}

public struct LoadedManifestProject: Sendable {
    public var manifestURL: URL
    public var mediaRoot: URL
    public var personName: String
    public var personKey: String
    public var projectName: String
    public var rows: [ResolvedManifestClip]
    public var questions: [QuestionGroup]
    public var issues: [AssemblyIssue]
}

public struct QuestionGroupBuilder {
    private let pathResolver = ManifestPathResolver()

    public init() {}

    public func loadProject(manifestURL: URL, projectFolder: URL) throws -> LoadedManifestProject {
        let rows = try ManifestParser().parse(url: manifestURL)
        let usableRows = rows.filter(\.isUsableStatus)
        guard !usableRows.isEmpty else {
            throw ManifestParserError.noUsableClips
        }

        let personKeys = Set(usableRows.map(\.personKey))
        var issues: [AssemblyIssue] = []
        if personKeys.count > 1 {
            issues.append(
                AssemblyIssue(
                    severity: .blocker,
                    code: "MULTIPLE_PERSON_KEYS",
                    humanMessage: "Phase 1 only supports one person per project, but this manifest contains multiple people.",
                    aiContext: ["person_keys": .array(personKeys.sorted().map(JSONValue.string))],
                    suggestedFix: "Split the manifest into separate per-person projects before importing it into Assembly Studio."
                )
            )
        }

        let personName = usableRows.first?.person ?? "Interview"
        let personKey = usableRows.first?.personKey ?? ""
        let projectName = projectFolder.lastPathComponent

        let resolvedRows: [ResolvedManifestClip] = usableRows.compactMap { row in
            let resolution = pathResolver.resolve(row: row, projectFolder: projectFolder)
            issues.append(contentsOf: resolution.issues)
            guard let resolvedURL = resolution.resolvedURL else { return nil }
            return ResolvedManifestClip(row: row, resolvedURL: resolvedURL)
        }

        var grouped: [String: [ResolvedManifestClip]] = [:]
        for clip in resolvedRows {
            grouped[clip.row.questionKey, default: []].append(clip)
        }

        let allAgeLabels = resolvedRows.reduce(into: [Double: String]()) { partial, clip in
            guard let ageSortKey = clip.row.ageSortKey else { return }
            if partial[ageSortKey] == nil {
                partial[ageSortKey] = clip.row.age
            }
        }

        let questions = grouped.map { questionKey, clips -> QuestionGroup in
            let displayText = clips.first?.row.question ?? questionKey
            let originalIndex = clips.compactMap(\.row.questionOriginalIndex).min() ?? .max
            let sortedClips = clips.sorted(by: clipSort(lhs:rhs:))
            let availableAgeKeys = Set(sortedClips.compactMap { $0.row.ageSortKey })
            let missingAges = Array(allAgeLabels.keys).sorted().compactMap { ageValue -> String? in
                guard !availableAgeKeys.contains(ageValue) else { return nil }
                return allAgeLabels[ageValue]
            }
            return QuestionGroup(
                questionKey: questionKey,
                displayText: displayText,
                originalIndex: originalIndex,
                clips: sortedClips,
                missingAges: missingAges
            )
        }.sorted {
            if $0.originalIndex != $1.originalIndex {
                return $0.originalIndex < $1.originalIndex
            }
            if $0.displayText != $1.displayText {
                return $0.displayText.localizedCaseInsensitiveCompare($1.displayText) == .orderedAscending
            }
            return $0.questionKey < $1.questionKey
        }

        return LoadedManifestProject(
            manifestURL: manifestURL,
            mediaRoot: projectFolder,
            personName: personName,
            personKey: personKey,
            projectName: projectName,
            rows: resolvedRows,
            questions: questions,
            issues: issues
        )
    }

    private func clipSort(lhs: ResolvedManifestClip, rhs: ResolvedManifestClip) -> Bool {
        if (lhs.row.ageSortKey ?? .greatestFiniteMagnitude) != (rhs.row.ageSortKey ?? .greatestFiniteMagnitude) {
            return (lhs.row.ageSortKey ?? .greatestFiniteMagnitude) < (rhs.row.ageSortKey ?? .greatestFiniteMagnitude)
        }
        if (lhs.row.ageYears ?? .greatestFiniteMagnitude) != (rhs.row.ageYears ?? .greatestFiniteMagnitude) {
            return (lhs.row.ageYears ?? .greatestFiniteMagnitude) < (rhs.row.ageYears ?? .greatestFiniteMagnitude)
        }
        if (lhs.row.sequenceIndex ?? .max) != (rhs.row.sequenceIndex ?? .max) {
            return (lhs.row.sequenceIndex ?? .max) < (rhs.row.sequenceIndex ?? .max)
        }
        return lhs.row.id < rhs.row.id
    }
}
