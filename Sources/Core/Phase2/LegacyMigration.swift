import Foundation

public enum LegacyMigrationSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case blocker
}

public struct LegacyMigrationFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var severity: LegacyMigrationSeverity
    public var code: String
    public var message: String
    public var sourcePath: String?

    public init(id: UUID = UUID(), severity: LegacyMigrationSeverity, code: String, message: String, sourcePath: String? = nil) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.sourcePath = sourcePath
    }
}

public struct LegacyMigrationAnalysis: Codable, Hashable, Sendable {
    public var sourceFolder: URL
    public var manifestURL: URL
    public var sidecarURL: URL?
    public var rows: [ManifestRow]
    public var findings: [LegacyMigrationFinding]
    public var personName: String
    public var questionCount: Int
    public var ageCount: Int

    public init(sourceFolder: URL, manifestURL: URL, sidecarURL: URL?, rows: [ManifestRow], findings: [LegacyMigrationFinding], personName: String, questionCount: Int, ageCount: Int) {
        self.sourceFolder = sourceFolder
        self.manifestURL = manifestURL
        self.sidecarURL = sidecarURL
        self.rows = rows
        self.findings = findings
        self.personName = personName
        self.questionCount = questionCount
        self.ageCount = ageCount
    }

    public var canImport: Bool {
        !findings.contains { $0.severity == .blocker }
    }
}

public struct LegacyImportResult: Sendable {
    public var packageURL: URL
    public var analysis: LegacyMigrationAnalysis
    public var migrationRecord: MigrationRecord

    public init(packageURL: URL, analysis: LegacyMigrationAnalysis, migrationRecord: MigrationRecord) {
        self.packageURL = packageURL
        self.analysis = analysis
        self.migrationRecord = migrationRecord
    }
}

/// Restores the coordinate system recorded by a legacy manifest. Manifest
/// answer/handle times are relative to the published clip, not its source.
public struct LegacyRangeRestorer: Sendable {
    public init() {}

    public func effectiveDurationUS(for row: ManifestRow, inspectedDurationUS: Int64?) -> Int64 {
        if let inspectedDurationUS, inspectedDurationUS > 0 { return inspectedDurationUS }
        let answerEnd = max(row.answerEndInOutputUS, 0)
        let realEnd = max(row.realMediaEndInOutputUS, 0)
        let handledEnd = answerEnd + max(row.actualHandleAfterUS, 0) + max(row.syntheticHandleAfterUS, 0)
        return max(realEnd, handledEnd)
    }

    public func boundaries(for row: ManifestRow, durationUS: Int64) -> RefinedBoundaries {
        let duration = max(durationUS, 0)
        let answerStart = clamp(row.answerStartInOutputUS, to: duration)
        let answerEndCandidate = clamp(row.answerEndInOutputUS, to: duration)
        let hasAnswerRange = answerEndCandidate > answerStart
        let visibleStart = hasAnswerRange ? answerStart : 0
        let visibleEnd = hasAnswerRange ? answerEndCandidate : duration

        let fallbackStart = max(0, visibleStart - max(row.actualHandleBeforeUS + row.syntheticHandleBeforeUS, 0))
        let fallbackEnd = min(duration, visibleEnd + max(row.actualHandleAfterUS + row.syntheticHandleAfterUS, 0))
        let safeStartCandidate = row.realMediaStartInOutputUS > 0 ? row.realMediaStartInOutputUS : fallbackStart
        let safeEndCandidate = row.realMediaEndInOutputUS > 0 ? row.realMediaEndInOutputUS : fallbackEnd
        let safeStart = min(visibleStart, clamp(safeStartCandidate, to: duration))
        let safeEnd = max(visibleEnd, clamp(safeEndCandidate, to: duration))

        return RefinedBoundaries(
            visibleStart: .microseconds(visibleStart),
            visibleEnd: .microseconds(visibleEnd),
            safeLeadingStart: .microseconds(safeStart),
            safeTrailingEnd: .microseconds(safeEnd),
            confidence: hasAnswerRange ? 1 : 0.45,
            reasons: hasAnswerRange ? ["Restored legacy manifest clip coordinates."] : ["Legacy manifest did not contain a valid answer range; inspected clip duration used."],
            algorithmIdentifier: "legacy-manifest-restoration",
            algorithmVersion: "1.0"
        )
    }

    public func repair(session: InterviewSession, rows: [ManifestRow]) -> InterviewSession {
        var repaired = session
        let rowsByIdentity = rows.reduce(into: [String: ManifestRow]()) { result, row in
            result[Self.identity(for: row)] = row
        }
        for questionKey in repaired.answers.keys {
            guard var answer = repaired.answers[questionKey] else { continue }
            for takeIndex in answer.takes.indices {
                for partIndex in answer.takes[takeIndex].parts.indices {
                    let part = answer.takes[takeIndex].parts[partIndex]
                    guard let metadata = part.extensions["legacy_manifest_row"],
                          case .object(let values) = metadata,
                          case .string(let clipNumber) = values["clip_number"],
                          case .string(let outputFile) = values["output_file"],
                          let row = rowsByIdentity["\(clipNumber)|\(outputFile)"] else { continue }
                    let inspectedDuration = repaired.recordings.first(where: { $0.id == part.sourceRecordingID })?.mediaSignature.durationMicroseconds
                    let duration = effectiveDurationUS(for: row, inspectedDurationUS: inspectedDuration)
                    let restoredBoundaries = boundaries(for: row, durationUS: duration)
                    answer.takes[takeIndex].parts[partIndex].rawMarkers.answerStart = restoredBoundaries.visibleStart
                    answer.takes[takeIndex].parts[partIndex].rawMarkers.answerEnd = restoredBoundaries.visibleEnd
                    answer.takes[takeIndex].parts[partIndex].refinedBoundaries = restoredBoundaries
                    answer.takes[takeIndex].parts[partIndex].extensions["legacy_manifest_timing"] = .object([
                        "answer_start_in_output_us": .number(Double(row.answerStartInOutputUS)),
                        "answer_end_in_output_us": .number(Double(row.answerEndInOutputUS)),
                        "real_media_start_in_output_us": .number(Double(row.realMediaStartInOutputUS)),
                        "real_media_end_in_output_us": .number(Double(row.realMediaEndInOutputUS))
                    ])
                }
            }
            repaired.answers[questionKey] = answer
        }
        return repaired
    }

    private static func identity(for row: ManifestRow) -> String { "\(row.clipNumber)|\(row.outputFile)" }
    private func clamp(_ value: Int64, to duration: Int64) -> Int64 { min(max(value, 0), duration) }
}

public struct LegacyMigrationService: Sendable {
    public init() {}

    public func analyze(sourceFolder: URL) throws -> LegacyMigrationAnalysis {
        let sourceFolder = sourceFolder.standardizedFileURL
        let manifestURL = sourceFolder.appendingPathComponent("final_manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ManifestParserError.invalidJSON("Legacy project is missing final_manifest.json.")
        }
        let sidecar = sourceFolder.appendingPathComponent("yearly_interview_studio_project.json")
        let sidecarURL = FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil
        let rows = try ManifestParser().parse(url: manifestURL)
        var findings: [LegacyMigrationFinding] = []
        let usable = rows.filter(\.isUsableStatus)
        let personKeys = Set(usable.map(\.personKey))
        if personKeys.count > 1 {
            findings.append(.init(severity: .blocker, code: "MULTIPLE_PERSONS", message: "The legacy manifest contains more than one person."))
        }
        if usable.isEmpty {
            findings.append(.init(severity: .blocker, code: "NO_USABLE_ROWS", message: "The legacy manifest contains no exported rows."))
        }
        for row in rows {
            if row.ageKey.isEmpty {
                findings.append(.init(severity: .blocker, code: "MISSING_AGE_KEY", message: "A manifest row has no immutable age key.", sourcePath: row.outputFile))
            }
            if row.questionKey.isEmpty {
                findings.append(.init(severity: .blocker, code: "MISSING_QUESTION_KEY", message: "A manifest row has no immutable question key.", sourcePath: row.outputFile))
            }
            if row.outputFile.isEmpty && (row.outputPath ?? "").isEmpty {
                findings.append(.init(severity: .blocker, code: "MISSING_OUTPUT_PATH", message: "A manifest row has no clip path."))
            }
        }
        let personName = usable.first?.person.nonEmpty ?? "Interview"
        return LegacyMigrationAnalysis(
            sourceFolder: sourceFolder,
            manifestURL: manifestURL,
            sidecarURL: sidecarURL,
            rows: rows,
            findings: findings,
            personName: personName,
            questionCount: Set(usable.map(\.questionKey)).count,
            ageCount: Set(usable.map(\.ageKey)).count
        )
    }

    public func `import`(analysis: LegacyMigrationAnalysis, to packageURL: URL) throws -> LegacyImportResult {
        guard analysis.canImport else {
            throw InterviewStudioCompatibilityError.invalid("The legacy project has unresolved blockers. Resolve them before importing.")
        }
        let personKey = InterviewStudioKey.readableKey(from: analysis.personName)
        let rows = analysis.rows.filter(\.isUsableStatus)
        let questionRows = Dictionary(grouping: rows, by: \.questionKey)
        let questions = questionRows.enumerated().map { index, item in
            InterviewQuestion(questionKey: item.key, displayText: item.value.first?.question.nonEmpty ?? item.key, order: index)
        }.sorted { $0.order < $1.order }
        var settings = AssemblySettings()
        if let sidecarURL = analysis.sidecarURL, let data = try? Data(contentsOf: sidecarURL), let legacy = try? JSONDecoder.interviewStudio.decode(ProjectDocument.self, from: data) {
            settings = AssemblySettings(renderSettings: legacy.renderSettings, plexMetadata: legacy.plexMetadata, openingTitle: legacy.openingTitle, closingTitle: legacy.closingTitle)
        }
        let project = InterviewStudioProject(person: InterviewPerson(readableKey: personKey, displayName: analysis.personName), questions: questions, assemblySettings: settings)
        let store = try InterviewStudioPackageStore.create(project: project, at: packageURL)
        let legacyRoot = store.rootURL.appendingPathComponent("Legacy Import/Original", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: analysis.manifestURL, to: legacyRoot.appendingPathComponent("final_manifest.json"))
        if let sidecarURL = analysis.sidecarURL {
            try FileManager.default.copyItem(at: sidecarURL, to: legacyRoot.appendingPathComponent("yearly_interview_studio_project.json"))
        }

        let rowsData = try JSONEncoder.interviewStudio.encode(rows)
        try rowsData.write(to: legacyRoot.appendingPathComponent("legacy_rows.json"), options: .atomic)
        var sessionByAge: [String: InterviewSession] = [:]
        for row in rows {
            if sessionByAge[row.ageKey] == nil {
                sessionByAge[row.ageKey] = InterviewSession(ageKey: row.ageKey, ageLabel: row.age, ageSortValue: row.ageSortKey)
            }
            let sourceURL = ManifestPathResolver().resolve(row: row, projectFolder: analysis.sourceFolder).resolvedURL
            if let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) {
                let extensionName = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
                let destinationName = "\(InterviewStudioKey.safeFilenameComponent(row.personKey, fallback: "person"))--\(InterviewStudioKey.safeFilenameComponent(row.ageKey, fallback: "age"))--\(InterviewStudioKey.safeFilenameComponent(row.questionKey, fallback: "question"))--\(InterviewStudioKey.safeFilenameComponent(row.clipNumber, fallback: "clip")).\(extensionName)"
                let relativePath = "Legacy Published Media/\(destinationName)"
                let destination = try store.resolve(relativePath: relativePath)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }

                var signature = MediaSignature(
                    byteCount: ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value) ?? 0,
                    sha256: sha256(fileURL: destination)
                )
                let inspection = try? NativeMediaInspector().inspect(url: destination)
                if let inspection {
                    signature.durationMicroseconds = inspection.duration.microseconds
                    signature.width = inspection.width
                    signature.height = inspection.height
                    signature.nominalFrameRate = inspection.nominalFrameRate
                    signature.actualFrameRate = inspection.actualFrameRate
                    signature.audioChannels = inspection.audioChannels
                    signature.colorPrimaries = inspection.colorPrimaries
                    signature.colorTransfer = inspection.colorTransfer
                    signature.colorMatrix = inspection.colorMatrix
                }

                let recording = SourceRecording(
                    ageKey: row.ageKey,
                    ageLabel: row.age,
                    packageRelativePath: relativePath,
                    originalFilename: sourceURL.lastPathComponent,
                    importSource: .legacy,
                    order: sessionByAge[row.ageKey]?.recordings.count ?? 0,
                    firstQuestionHint: row.questionKey,
                    mediaSignature: signature,
                    extensions: ["legacy_manifest_row": .object([
                        "output_file": .string(row.outputFile),
                        "clip_number": .string(row.clipNumber)
                    ])]
                )
                sessionByAge[row.ageKey]?.recordings.append(recording)

                var answer = sessionByAge[row.ageKey]?.answers[row.questionKey] ?? InterviewAnswer(questionKey: row.questionKey)
                let restorer = LegacyRangeRestorer()
                let clipDurationUS = restorer.effectiveDurationUS(for: row, inspectedDurationUS: inspection?.duration.microseconds)
                let markers = RawAnswerMarkers(
                    answerStart: clipDurationUS > 0 ? .microseconds(max(0, min(row.answerStartInOutputUS, clipDurationUS))) : nil,
                    answerEnd: clipDurationUS > 0 ? .microseconds(max(0, min(max(row.answerEndInOutputUS, row.answerStartInOutputUS), clipDurationUS))) : nil
                )
                let boundaries = restorer.boundaries(for: row, durationUS: clipDurationUS)
                let timingMetadata: [String: JSONValue] = [
                    "output_file": .string(row.outputFile),
                    "clip_number": .string(row.clipNumber),
                    "answer_start_in_output_us": .number(Double(row.answerStartInOutputUS)),
                    "answer_end_in_output_us": .number(Double(row.answerEndInOutputUS)),
                    "real_media_start_in_output_us": .number(Double(row.realMediaStartInOutputUS)),
                    "real_media_end_in_output_us": .number(Double(row.realMediaEndInOutputUS))
                ]
                let existingParts = answer.selectedTake?.parts ?? []
                let part = AnswerPart(
                    sourceRecordingID: recording.id,
                    rawMarkers: markers,
                    refinedBoundaries: boundaries,
                    sourceOrder: existingParts.count,
                    extensions: ["legacy_manifest_row": .object(timingMetadata), "legacy_manifest_timing": .object(timingMetadata)]
                )
                let take = AnswerTake(
                    parts: existingParts + [part],
                    isMultiPart: existingParts.count > 0,
                    reviewState: .reviewed,
                    confidence: 1,
                    extensions: ["import_source": .string("legacy")]
                )
                answer.takes = [take]
                answer.selectedTakeID = take.id
                answer.state = .complete
                answer.lastReviewedAt = Date()
                answer.extensions["legacy_manifest_row"] = .object([
                    "output_file": .string(row.outputFile),
                    "clip_number": .string(row.clipNumber)
                ])
                sessionByAge[row.ageKey]?.answers[row.questionKey] = answer
            } else {
                sessionByAge[row.ageKey]?.appendAudit("legacy_missing_media", detail: row.outputFile)
                var answer = sessionByAge[row.ageKey]?.answers[row.questionKey] ?? InterviewAnswer(questionKey: row.questionKey)
                answer.state = .needsReview
                answer.extensions["legacy_manifest_row"] = .object([
                    "output_file": .string(row.outputFile),
                    "clip_number": .string(row.clipNumber)
                ])
                sessionByAge[row.ageKey]?.answers[row.questionKey] = answer
            }
        }
        for ageKey in sessionByAge.keys {
            guard var session = sessionByAge[ageKey] else { continue }
            for question in questions where session.answers[question.questionKey] == nil {
                session.answers[question.questionKey] = InterviewAnswer(
                    questionKey: question.questionKey,
                    state: .skipped,
                    extensions: ["legacy_import_assumption": .string("blank_response")]
                )
            }
            sessionByAge[ageKey] = session
        }
        for var session in sessionByAge.values {
            session.lifecycle = .locked
            session.revision = 1
            session.appendAudit("legacy_import_locked", detail: "Imported legacy years start locked to protect prior answers. Unlock to edit.")
            try store.writeSession(session)
        }
        let record = MigrationRecord(sourcePathDescription: analysis.sourceFolder.lastPathComponent, importedManifestSHA256: sha256(fileURL: analysis.manifestURL), decisionSummary: ["Legacy source was copied into Legacy Import/Original.", "Legacy published media was copied without modifying the source folder."])
        try store.writeJSONForMigration(record)
        var updatedProject = try store.readProject()
        updatedProject.migrationHistoryIDs.append(record.id)
        try store.writeProject(updatedProject)
        try store.rebuildInventory()
        return LegacyImportResult(packageURL: store.rootURL, analysis: analysis, migrationRecord: record)
    }
}

private extension InterviewStudioPackageStore {
    func writeJSONForMigration(_ record: MigrationRecord) throws {
        let url = rootURL.appendingPathComponent("Migration History", isDirectory: true).appendingPathComponent("\(record.id.uuidString).json")
        try JSONEncoder.interviewStudio.encode(record).write(to: url, options: .atomic)
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
