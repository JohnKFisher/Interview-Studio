import Foundation

public struct RenderPlanBuilder {
    private let transitionPlanner = TransitionPlanner()

    public init() {}

    public func build(project: LoadedManifestProject, document: ProjectDocument, exportProfile: ExportProfile = .appleHLG4K60) -> RenderPlan {
        let orderedQuestions = orderedQuestions(from: project, using: document)
        let settings = document.renderSettings
        var sequence: [RenderSequenceNode] = []
        var issues = project.issues

        let openingNode = RenderSequenceNode(
            nodeID: "opening-001",
            type: .openingCard,
            text: .init(title: document.openingTitle, subtitle: ""),
            template: .init(templateID: settings.selectedCardSetID, durationSeconds: 2.5, durationSource: "template_default"),
            questionKey: nil,
            questionText: nil,
            clipRef: nil,
            identity: nil,
            timing: nil,
            handles: nil,
            video: nil,
            overlays: [],
            audio: nil,
            confidence: .init(level: .high),
            issues: []
        )
        sequence.append(openingNode)

        var questionClipLookup: [String: [ResolvedManifestClip]] = [:]
        var questionCount = 0
        var answerCount = 0

        for question in orderedQuestions {
            guard !question.clips.isEmpty else {
                issues.append(
                    AssemblyIssue(
                        severity: .warning,
                        code: "EMPTY_QUESTION_OMITTED",
                        humanMessage: "The question '\(question.displayText)' has no usable clips and will be omitted from the final movie.",
                        aiContext: ["question_key": .string(question.questionKey)],
                        suggestedFix: "Regenerate or restore clips for this question if you want it included."
                    )
                )
                continue
            }

            questionCount += 1
            questionClipLookup[question.questionKey] = question.clips

            sequence.append(
                RenderSequenceNode(
                    nodeID: "question-card-\(question.questionKey)",
                    type: .questionCard,
                    text: nil,
                    template: .init(templateID: settings.selectedCardSetID, durationSeconds: 1.75, durationSource: "template_default"),
                    questionKey: question.questionKey,
                    questionText: question.displayText,
                    clipRef: nil,
                    identity: nil,
                    timing: nil,
                    handles: nil,
                    video: nil,
                    overlays: [],
                    audio: nil,
                    confidence: .init(level: .high),
                    issues: question.missingAges.map {
                        AssemblyIssue(
                            severity: .info,
                            code: "MISSING_AGE_IN_QUESTION",
                            humanMessage: "This question is missing \($0), which is informational only.",
                            aiContext: [
                                "question_key": .string(question.questionKey),
                                "missing_age_label": .string($0)
                            ],
                            suggestedFix: "No action is required unless you expected a clip for that age."
                        )
                    }
                )
            )

            for clip in question.clips {
                answerCount += 1
                let clipIssues = clipIssues(for: clip)
                issues.append(contentsOf: clipIssues)
                sequence.append(makeAnswerNode(for: clip, questionText: question.displayText, settings: settings, issues: clipIssues))
            }
        }

        let closingNode = RenderSequenceNode(
            nodeID: "closing-001",
            type: .closingCard,
            text: .init(title: document.closingTitle, subtitle: ""),
            template: .init(templateID: settings.selectedCardSetID, durationSeconds: 2.5, durationSource: "template_default"),
            questionKey: nil,
            questionText: nil,
            clipRef: nil,
            identity: nil,
            timing: nil,
            handles: nil,
            video: nil,
            overlays: [],
            audio: nil,
            confidence: .init(level: .high),
            issues: []
        )
        sequence.append(closingNode)

        let sequenceIssues = sequence.flatMap(\.issues)
        issues.append(contentsOf: sequenceIssues)

        let boundaries = buildBoundaries(sequence: sequence, project: project, questionClipLookup: questionClipLookup, settings: settings, frameRate: exportProfile.frameRate)
        issues.append(contentsOf: boundaries.flatMap(\.issues))
        let plexMetadata = buildPlexMetadataPlan(document: document, sequence: sequence, boundaries: boundaries, issues: &issues)

        let summary = makeSummary(
            sequence: sequence,
            boundaries: boundaries,
            issues: issues,
            questionCount: questionCount,
            answerCount: answerCount
        )

        return RenderPlan(
            schemaVersion: "1.0",
            appName: "Yearly Interview Studio",
            project: .init(
                projectID: project.personKey.isEmpty ? UUID().uuidString : project.personKey,
                projectName: document.projectName,
                manifestPath: project.manifestURL.path,
                mediaRoot: project.mediaRoot.path
            ),
            exportProfile: exportProfile,
            settings: settings,
            plexMetadata: plexMetadata,
            sequence: sequence,
            boundaries: boundaries,
            issues: deduplicatedIssues(issues),
            summary: summary
        )
    }

    private func orderedQuestions(from project: LoadedManifestProject, using document: ProjectDocument) -> [QuestionGroup] {
        let byKey = Dictionary(uniqueKeysWithValues: project.questions.map { ($0.questionKey, $0) })
        let orderedKeys = document.questionOrder.filter { byKey[$0] != nil } + project.questions.map(\.questionKey).filter { !document.questionOrder.contains($0) }
        return orderedKeys.compactMap { key in
            guard var question = byKey[key] else { return nil }
            if let editedText = document.questionDisplayTexts[key], !editedText.isEmpty {
                question.displayText = editedText
            }
            if document.titleCaseQuestions {
                question.displayText = TitleCaseFormatter.format(question.displayText)
            }
            return question
        }
    }

    private func makeAnswerNode(for clip: ResolvedManifestClip, questionText: String, settings: RenderSettings, issues: [AssemblyIssue]) -> RenderSequenceNode {
        let row = clip.row
        let confidence = evaluateConfidence(for: row, issues: issues)
        return RenderSequenceNode(
            nodeID: "answer-\(row.questionKey)-\(row.ageKey)",
            type: .answerClip,
            text: nil,
            template: nil,
            questionKey: row.questionKey,
            questionText: questionText,
            clipRef: .init(
                clipID: row.id,
                clipNumber: row.clipNumber,
                outputFile: row.outputFile,
                resolvedPath: clip.resolvedURL.path
            ),
            identity: .init(
                person: row.person,
                personKey: row.personKey,
                questionKey: row.questionKey,
                questionText: questionText,
                age: row.age,
                ageKey: row.ageKey,
                ageSortKey: row.ageSortKey ?? row.ageYears ?? 0
            ),
            timing: .init(
                answerStartInOutputUS: row.answerStartInOutputUS,
                answerEndInOutputUS: row.answerEndInOutputUS,
                realMediaStartInOutputUS: row.realMediaStartInOutputUS,
                realMediaEndInOutputUS: row.realMediaEndInOutputUS,
                durationUS: row.answerDurationUS
            ),
            handles: .init(
                actualHandleBeforeUS: row.actualHandleBeforeUS,
                actualHandleAfterUS: row.actualHandleAfterUS,
                syntheticHandleBeforeUS: row.syntheticHandleBeforeUS,
                syntheticHandleAfterUS: row.syntheticHandleAfterUS,
                handleBeforeStatus: row.handleBeforeStatus,
                handleAfterStatus: row.handleAfterStatus,
                syntheticHandleBeforeStatus: row.syntheticHandleBeforeStatus,
                syntheticHandleAfterStatus: row.syntheticHandleAfterStatus
            ),
            video: .init(
                sourceIsDolby: row.sourceIsDolby,
                hdrDolbyValidation: row.hdrDolbyValidation,
                sourceVideoSignature: row.sourceVideoSignature,
                outputVideoSignature: row.outputVideoSignature
            ),
            overlays: [
                .init(type: "age_overlay", mode: "persistent", text: row.age, styleID: settings.selectedOverlayStyleID, enabled: settings.overlays.showAgeOverlay),
                .init(type: "question_overlay", mode: "persistent", text: questionText, styleID: "question-top-corner-subtle", enabled: settings.overlays.showQuestionOverlay)
            ],
            audio: .init(
                loudnessMatch: settings.audio.gentleLoudnessMatch,
                targetLUFS: settings.audio.targetLUFS,
                truePeakCeilingDBTP: settings.audio.truePeakCeilingDBTP
            ),
            confidence: confidence,
            issues: issues
        )
    }

    private func buildBoundaries(
        sequence: [RenderSequenceNode],
        project: LoadedManifestProject,
        questionClipLookup: [String: [ResolvedManifestClip]],
        settings: RenderSettings,
        frameRate: Double
    ) -> [BoundaryTransition] {
        var boundaries: [BoundaryTransition] = []
        let clipLookup = Dictionary(uniqueKeysWithValues: project.rows.map { ($0.row.id, $0) })

        for index in sequence.indices.dropLast() {
            let current = sequence[index]
            let next = sequence[index + 1]

            if current.type == .answerClip, next.type == .answerClip,
               let currentID = current.clipRef?.clipID,
               let nextID = next.clipRef?.clipID,
               let currentClip = clipLookup[currentID],
               let nextClip = clipLookup[nextID],
               current.questionKey == next.questionKey {
                boundaries.append(
                    transitionPlanner.planAnswerBoundary(
                        from: current,
                        fromClip: currentClip,
                        to: next,
                        toClip: nextClip,
                        settings: settings,
                        frameRate: frameRate
                    )
                )
            } else if current.type == .openingCard || next.type == .questionCard || next.type == .closingCard || current.type == .questionCard {
                let style: String
                if current.type == .questionCard && next.type == .answerClip {
                    style = "cut"
                } else if current.type == .openingCard && next.type == .questionCard {
                    style = settings.questionCardTransition.style
                } else if current.type == .answerClip && (next.type == .questionCard || next.type == .closingCard) {
                    style = settings.questionCardTransition.style
                } else if current.type == .questionCard && next.type == .questionCard {
                    style = settings.questionCardTransition.style
                } else {
                    style = "cut"
                }
                boundaries.append(
                    transitionPlanner.planStructuralBoundary(
                        from: current,
                        to: next,
                        style: style,
                        durationFrames: style == "cut" ? 0 : settings.questionCardTransition.durationFrames,
                        frameRate: frameRate,
                        boundaryType: "\(current.type.rawValue)_to_\(next.type.rawValue)"
                    )
                )
            }
        }

        return boundaries
    }

    private func clipIssues(for clip: ResolvedManifestClip) -> [AssemblyIssue] {
        let row = clip.row
        var issues: [AssemblyIssue] = []

        if row.isHDRLike && row.hdrDolbyValidation.lowercased() != "passed" {
            issues.append(
                AssemblyIssue(
                    severity: .blocker,
                    code: "HDR_VALIDATION_FAILED",
                    humanMessage: "Cannot export: the HDR/Dolby clip for '\(row.question)' at \(row.age) did not pass HDR validation.",
                    aiContext: [
                        "question_key": .string(row.questionKey),
                        "age_key": .string(row.ageKey),
                        "hdr_dolby_validation": .string(row.hdrDolbyValidation)
                    ],
                    suggestedFix: "Regenerate or replace the HDR clip with one that passes validation."
                )
            )
        }

        if row.answerDurationUS <= 0 {
            issues.append(
                AssemblyIssue(
                    severity: .blocker,
                    code: "INVALID_ANSWER_TIMING",
                    humanMessage: "Cannot export: the clip for '\(row.question)' at \(row.age) has invalid answer timing.",
                    aiContext: [
                        "answer_start_us": .number(Double(row.answerStartInOutputUS)),
                        "answer_end_us": .number(Double(row.answerEndInOutputUS))
                    ],
                    suggestedFix: "Regenerate the clip so the answer timing fields are valid."
                )
            )
        }

        if row.handleBeforeStatus != "full" || row.handleAfterStatus != "full" {
            issues.append(
                AssemblyIssue(
                    severity: .warning,
                    code: "PARTIAL_REAL_HANDLES",
                    humanMessage: "The clip for '\(row.question)' at \(row.age) does not have full real handle coverage.",
                    aiContext: [
                        "question_key": .string(row.questionKey),
                        "age_key": .string(row.ageKey),
                        "handle_before_status": .string(row.handleBeforeStatus),
                        "handle_after_status": .string(row.handleAfterStatus)
                    ],
                    suggestedFix: "This is non-blocking, but regenerating the clip with more source room may improve transitions."
                )
            )
        }

        if row.sourcePartCount > 1 || !row.warnings.isEmpty {
            issues.append(
                AssemblyIssue(
                    severity: .warning,
                    code: "SOURCE_ROW_WARNINGS",
                    humanMessage: "The clip for '\(row.question)' at \(row.age) carries source/export warnings that may affect smooth assembly.",
                    aiContext: [
                        "question_key": .string(row.questionKey),
                        "age_key": .string(row.ageKey),
                        "warnings": .string(row.warnings),
                        "source_part_count": .number(Double(row.sourcePartCount))
                    ],
                    suggestedFix: "Review the source row warnings if this clip looks unusual in the preview or final render."
                )
            )
        }

        return issues
    }

    private func buildPlexMetadataPlan(
        document: ProjectDocument,
        sequence: [RenderSequenceNode],
        boundaries: [BoundaryTransition],
        issues: inout [AssemblyIssue]
    ) -> PlexMetadataPlan? {
        let input = document.plexMetadata
        guard input.isEnabled else { return nil }

        let missingFields = plexMissingFields(for: input)
        guard missingFields.isEmpty,
              let seasonNumber = Int(input.season.trimmingCharacters(in: .whitespacesAndNewlines)),
              let episodeNumber = Int(input.episode.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            issues.append(
                AssemblyIssue(
                    severity: .blocker,
                    code: "PLEX_METADATA_INCOMPLETE",
                    humanMessage: "Plex companion export is enabled, but Show, Season, Episode, Episode Title, and Summary must all be filled before export.",
                    aiContext: [
                        "missing_fields": .array(missingFields.map(JSONValue.string))
                    ],
                    suggestedFix: "Fill the required Plex metadata fields or turn off Plex companion export for this project."
                )
            )
            return nil
        }

        return PlexMetadataPlan(
            show: input.show.trimmingCharacters(in: .whitespacesAndNewlines),
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            episodeTitle: input.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: input.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapterPlan(sequence: sequence, boundaries: boundaries)
        )
    }

    private func plexMissingFields(for input: PlexMetadataInput) -> [String] {
        var missing: [String] = []
        if input.show.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("Show")
        }
        if input.season.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(input.season.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            missing.append("Season")
        }
        if input.episode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(input.episode.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            missing.append("Episode")
        }
        if input.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("Episode Title")
        }
        if input.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("Summary")
        }
        return missing
    }

    private func chapterPlan(sequence: [RenderSequenceNode], boundaries: [BoundaryTransition]) -> [RenderChapter] {
        let boundaryLookup = Dictionary(uniqueKeysWithValues: boundaries.map { ("\($0.fromNodeID)->\($0.toNodeID)", $0) })
        var markers: [(title: String, startUS: Int64)] = []
        var cursorUS: Int64 = 0

        for index in sequence.indices {
            let node = sequence[index]
            if let chapterTitle = chapterTitle(for: node) {
                markers.append((chapterTitle, cursorUS))
            }

            cursorUS += durationUS(for: node)
            guard index < sequence.count - 1 else { continue }

            let next = sequence[index + 1]
            if let boundary = boundaryLookup["\(node.nodeID)->\(next.nodeID)"],
               boundary.boundaryType == "answer_to_answer",
               boundary.resolved.style == "soft_crossfade" {
                cursorUS += boundary.requested.durationUS
            }
        }

        let totalDurationUS = cursorUS
        return markers.enumerated().compactMap { index, marker in
            let endUS = index < markers.count - 1 ? markers[index + 1].startUS : totalDurationUS
            guard endUS > marker.startUS else { return nil }
            return RenderChapter(title: marker.title, startUS: marker.startUS, endUS: endUS)
        }
    }

    private func chapterTitle(for node: RenderSequenceNode) -> String? {
        switch node.type {
        case .openingCard:
            return (node.text?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : node.text?.title
        case .questionCard:
            return node.questionText
        case .closingCard:
            return (node.text?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : node.text?.title
        case .answerClip:
            return nil
        }
    }

    private func durationUS(for node: RenderSequenceNode) -> Int64 {
        if let template = node.template {
            return Int64((template.durationSeconds * 1_000_000).rounded())
        }
        return node.timing?.durationUS ?? 0
    }

    private func evaluateConfidence(for row: ManifestRow, issues: [AssemblyIssue]) -> Confidence {
        var reasons: [String] = []
        var level: ConfidenceLevel = .high

        if row.parserConfidence == .medium {
            level = .medium
            reasons.append("The source manifest marked this row with medium parser confidence.")
        } else if row.parserConfidence == .low {
            level = .low
            reasons.append("The source manifest marked this row with low parser confidence.")
        }

        if row.handleBeforeStatus != "full" || row.handleAfterStatus != "full" {
            level = max(level, .medium)
            reasons.append("Real handle coverage is partial.")
        }

        if row.syntheticHandleBeforeUS > 0 || row.syntheticHandleAfterUS > 0 {
            level = max(level, .medium)
            reasons.append("Synthetic handle padding is present in the exported clip.")
        }

        if row.sourcePartCount > 1 || !row.warnings.isEmpty {
            level = max(level, .medium)
            reasons.append("The manifest row includes merge/export warnings.")
        }

        if issues.contains(where: { $0.code == "HDR_VALIDATION_FAILED" }) {
            level = .low
            reasons.append("HDR validation failed for a required HDR/Dolby clip.")
        }

        return Confidence(level: level, reasons: reasons)
    }

    private func makeSummary(
        sequence: [RenderSequenceNode],
        boundaries: [BoundaryTransition],
        issues: [AssemblyIssue],
        questionCount: Int,
        answerCount: Int
    ) -> RenderPlanSummary {
        let blockerCount = issues.filter { $0.severity == .blocker }.count
        let warningCount = issues.filter { $0.severity == .warning }.count
        let infoCount = issues.filter { $0.severity == .info }.count
        let confidences = sequence.compactMap(\.confidence?.level)
        let runtime = sequence.reduce(0.0) { partial, node in
            partial + (node.template?.durationSeconds ?? 0) + (node.timing.map { Double($0.durationUS) / 1_000_000 } ?? 0)
        } + boundaries
            .filter { $0.boundaryType == "answer_to_answer" && $0.resolved.style == "soft_crossfade" }
            .reduce(0.0) { $0 + (Double($1.requested.durationUS) / 1_000_000) }

        return RenderPlanSummary(
            questionCount: questionCount,
            answerClipCount: answerCount,
            estimatedRuntimeSeconds: runtime,
            blockerCount: blockerCount,
            warningCount: warningCount,
            infoCount: infoCount,
            confidenceCounts: .init(
                high: confidences.filter { $0 == .high }.count,
                medium: confidences.filter { $0 == .medium }.count,
                low: confidences.filter { $0 == .low }.count
            ),
            transitionCounts: .init(
                realHandleCrossfade: boundaries.filter { $0.resolved.method == "real_handles" }.count,
                syntheticCrossfade: boundaries.filter { $0.resolved.method == "synthetic_handles" || $0.resolved.method == "synthetic_generated" }.count,
                cleanCutFallback: boundaries.filter { $0.resolved.method == "fallback_clean_cut" }.count
            ),
            exportAllowed: blockerCount == 0
        )
    }

    private func deduplicatedIssues(_ issues: [AssemblyIssue]) -> [AssemblyIssue] {
        var seen: Set<String> = []
        return issues.filter { issue in
            let key = "\(issue.severity.rawValue)|\(issue.code)|\(issue.humanMessage)"
            return seen.insert(key).inserted
        }
    }
}

private func max(_ lhs: ConfidenceLevel, _ rhs: ConfidenceLevel) -> ConfidenceLevel {
    let rank: [ConfidenceLevel: Int] = [.high: 0, .medium: 1, .low: 2]
    return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
}
