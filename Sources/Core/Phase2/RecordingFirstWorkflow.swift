import Foundation

public enum RecordingFirstWorkflowError: LocalizedError, Sendable {
    case invalidIO
    case unfinishedInPoint
    case candidateNotFound
    case candidateNotApproved
    case discardedCandidate
    case questionAlreadyAssigned
    case candidateAlreadyAssigned
    case sessionUnavailable
    case sessionLocked
    case invalidSegment
    public var errorDescription: String? {
        switch self {
        case .invalidIO: return "The Out point must be later than the In point."
        case .unfinishedInPoint: return "An In point has no matching Out point."
        case .candidateNotFound: return "The answer candidate was not found."
        case .candidateNotApproved: return "Only an approved candidate can be assigned."
        case .discardedCandidate: return "A discarded candidate cannot be assigned."
        case .questionAlreadyAssigned: return "That question already has an assigned candidate. Compare or replace it first."
        case .candidateAlreadyAssigned: return "That candidate is already assigned to a question."
        case .sessionUnavailable: return "The session is archived or read-only and cannot be edited."
        case .sessionLocked: return "Unlock the session before editing its assignments."
        case .invalidSegment: return "The retained segment must have a positive duration and lie inside the candidate."
        }
    }
}

public struct RecordingCaptureState: Codable, Sendable, Hashable {
    public var inPoint: MediaTime?
    public var outPoint: MediaTime?
    public init(inPoint: MediaTime? = nil, outPoint: MediaTime? = nil) { self.inPoint = inPoint; self.outPoint = outPoint }
    public var hasValidPair: Bool { guard let i = inPoint, let o = outPoint else { return false }; return o > i }
    public mutating func markIn(at timestamp: MediaTime) -> [CandidateSegment] { inPoint = timestamp; outPoint = nil; return [] }
    public mutating func markOut(at timestamp: MediaTime) throws { guard let i = inPoint, timestamp > i else { throw RecordingFirstWorkflowError.invalidIO }; outPoint = timestamp }
}

public struct RecordingFirstReadinessReport: Codable, Hashable, Sendable {
    public var blockers: [String]
    public var warnings: [String]
    public init(blockers: [String] = [], warnings: [String] = []) { self.blockers = blockers; self.warnings = warnings }
    public var isReady: Bool { blockers.isEmpty }
}

public struct CandidateComparison: Codable, Hashable, Sendable, Identifiable {
    public var current: AnswerCandidate
    public var proposed: AnswerCandidate
    public init(current: AnswerCandidate, proposed: AnswerCandidate) { self.current = current; self.proposed = proposed }
    public var id: UUID { proposed.id }
    public var proposedDuration: MediaTime { proposed.visibleRange?.duration ?? .zero }
}

public struct CandidatePublicationPlacement: Codable, Hashable, Sendable {
    public var sourceSegment: CandidateSegment
    public var outputStart: MediaTime
    public var outputEnd: MediaTime

    public init(sourceSegment: CandidateSegment, outputStart: MediaTime, outputEnd: MediaTime) {
        self.sourceSegment = sourceSegment
        self.outputStart = outputStart
        self.outputEnd = outputEnd
    }
}

public struct CandidatePublicationTimeline: Codable, Hashable, Sendable {
    public var placements: [CandidatePublicationPlacement]
    public var duration: MediaTime

    public init(placements: [CandidatePublicationPlacement], duration: MediaTime) {
        self.placements = placements
        self.duration = duration
    }

    public func outputTime(for sourceTime: MediaTime) -> MediaTime? {
        guard let first = placements.first, let last = placements.last else { return nil }
        if sourceTime <= first.sourceSegment.start { return first.outputStart }
        if sourceTime >= last.sourceSegment.end { return last.outputEnd }
        guard let placement = placements.first(where: { sourceTime >= $0.sourceSegment.start && sourceTime <= $0.sourceSegment.end }) else { return nil }
        let offset = sourceTime.microseconds - placement.sourceSegment.start.microseconds
        return .microseconds(placement.outputStart.microseconds + offset)
    }

    public func visibleOutputRange(for candidate: AnswerCandidate) -> CandidateSegment? {
        guard let visible = candidate.visibleRange,
              let start = outputTime(for: visible.start),
              let end = outputTime(for: visible.end),
              end > start else { return nil }
        return CandidateSegment(start: start, end: end)
    }
}

public enum RecordingFirstWorkflow {
    public static let defaultHandleDurationUS: Int64 = 2_000_000
    public static let maximumReviewHandleDurationUS: Int64 = 3_000_000

    public static func normalizedAge(value: Double) -> NormalizedAge? {
        guard value.isFinite, value >= 0 else { return nil }
        let rounded = (value * 100).rounded() / 100
        let display = rounded.formatted(.number.precision(.fractionLength(0...2)))
        let keyDisplay = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
            .trimmingCharacters(in: CharacterSet(charactersIn: "0"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let stableDisplay = keyDisplay.isEmpty ? "0" : keyDisplay
        let unit = display == "1" ? "Year" : "Years"
        return NormalizedAge(key: "age_\(stableDisplay)", label: "\(display) \(unit) Old", sortValue: rounded)
    }

    /// Returns the presentation label for a recording-first age entry.
    /// Older entries may still persist the pre-normalization form, such as
    /// "Age 10"; publication must not carry that legacy wording into the
    /// on-screen overlay.
    public static func displayAgeLabel(for session: InterviewSession) -> String {
        guard session.workflowKind == .recordingFirstV1 else { return session.ageLabel }
        return session.normalizedAge().label
    }

    public static func sameAge(_ session: InterviewSession, normalized: NormalizedAge) -> Bool {
        if session.ageKey == normalized.key { return true }
        guard let existing = session.ageSortValue, let requested = normalized.sortValue else { return false }
        return abs(existing - requested) < 0.000001
    }

    public static func makeCandidate(segment: CandidateSegment, recording: SourceRecording, clipNumber: Int, sourceOrder: Int = 0, now: Date = Date()) -> AnswerCandidate {
        AnswerCandidate(sourceRecordingID: recording.id, recordingNumber: recording.recordingNumber, clipNumber: clipNumber, sourceOrder: sourceOrder, rawMarkers: RawAnswerMarkers(answerStart: segment.start, answerEnd: segment.end), retainedSegments: [segment], createdAt: now, updatedAt: now)
    }

    /// Creates the recording-first review range from explicit In/Out marks.
    /// Handles are deterministic: two seconds by default, clamped to the
    /// recording and bounded to three seconds when adjusted in Review.
    public static func reviewBoundaries(
        visible: CandidateSegment,
        sourceDurationUS: Int64,
        leadingStartUS: Int64? = nil,
        trailingEndUS: Int64? = nil,
        manualOverride: Bool = false
    ) -> RefinedBoundaries? {
        guard visible.isValid,
              visible.start.microseconds >= 0,
              sourceDurationUS >= visible.end.microseconds else { return nil }

        let visibleStartUS = visible.start.microseconds
        let visibleEndUS = visible.end.microseconds
        let defaultLeadingStartUS = max(0, visibleStartUS - defaultHandleDurationUS)
        let defaultTrailingEndUS = min(sourceDurationUS, visibleEndUS + defaultHandleDurationUS)
        let minimumLeadingStartUS = max(0, visibleStartUS - maximumReviewHandleDurationUS)
        let maximumTrailingEndUS = min(sourceDurationUS, visibleEndUS + maximumReviewHandleDurationUS)
        let safeLeadingStartUS = min(max(leadingStartUS ?? defaultLeadingStartUS, minimumLeadingStartUS), visibleStartUS)
        let safeTrailingEndUS = min(max(trailingEndUS ?? defaultTrailingEndUS, visibleEndUS), maximumTrailingEndUS)

        return RefinedBoundaries(
            visibleStart: visible.start,
            visibleEnd: visible.end,
            safeLeadingStart: .microseconds(safeLeadingStartUS),
            safeTrailingEnd: .microseconds(safeTrailingEndUS),
            confidence: manualOverride ? 1 : 0.4,
            reasons: [manualOverride ? "Adjusted manually in Review." : "Fixed 2-second handles around In/Out marks."],
            algorithmIdentifier: manualOverride ? "recording-first-manual-boundaries" : "recording-first-io-default",
            algorithmVersion: "1.0",
            manualOverride: manualOverride
        )
    }

    public static func reviewViewport(for visible: CandidateSegment, sourceDurationUS: Int64) -> CandidateSegment? {
        guard visible.isValid,
              visible.start.microseconds >= 0,
              sourceDurationUS >= visible.end.microseconds else { return nil }
        let startUS = max(0, visible.start.microseconds - maximumReviewHandleDurationUS)
        let endUS = min(sourceDurationUS, visible.end.microseconds + maximumReviewHandleDurationUS)
        return CandidateSegment(start: .microseconds(startUS), end: .microseconds(endUS))
    }

    public static func compare(current: AnswerCandidate, proposed: AnswerCandidate) -> CandidateComparison { CandidateComparison(current: current, proposed: proposed) }

    /// Uses the supplied player timestamp directly; no periodic UI timestamp is substituted.
    public static func captureIO(timestamp: MediaTime, state: inout RecordingCaptureState, mark: Character) throws -> CandidateSegment? {
        switch mark.lowercased() {
        case "i":
            if state.hasValidPair { let candidate = CandidateSegment(start: state.inPoint!, end: state.outPoint!); state.inPoint = timestamp; state.outPoint = nil; return candidate }
            state.inPoint = timestamp; state.outPoint = nil; return nil
        case "o":
            try state.markOut(at: timestamp); return nil
        default: return nil
        }
    }

    public static func commitProvisional(_ state: inout RecordingCaptureState) throws -> CandidateSegment {
        guard state.hasValidPair, let i = state.inPoint, let o = state.outPoint else { throw RecordingFirstWorkflowError.unfinishedInPoint }
        state = .init(); return CandidateSegment(start: i, end: o)
    }

    public static func assign(candidateID: UUID, to questionKey: String, in session: inout InterviewSession, replacing: Bool = false) throws {
        guard session.compatibility.isWritable, session.isActive else { throw RecordingFirstWorkflowError.sessionUnavailable }
        guard session.lifecycle == .open else { throw RecordingFirstWorkflowError.sessionLocked }
        guard let index = session.candidates.firstIndex(where: { $0.id == candidateID }) else { throw RecordingFirstWorkflowError.candidateNotFound }
        guard session.candidates[index].reviewState != .discarded else { throw RecordingFirstWorkflowError.discardedCandidate }
        guard session.candidates[index].reviewState == .approved else { throw RecordingFirstWorkflowError.candidateNotApproved }
        if session.answers[questionKey]?.assignedCandidateID != nil && !replacing { throw RecordingFirstWorkflowError.questionAlreadyAssigned }
        if session.answers.values.contains(where: { $0.assignedCandidateID == candidateID && $0.questionKey != questionKey }) { throw RecordingFirstWorkflowError.candidateAlreadyAssigned }
        var answer = session.answers[questionKey] ?? InterviewAnswer(questionKey: questionKey)
        answer.assignedCandidateID = candidateID; answer.state = .complete; session.answers[questionKey] = answer
        session.candidates[index].updatedAt = Date(); session.revision += 1
    }

    public static func validateAssignments(in session: InterviewSession) -> [String] {
        var problems: [String] = []
        var seen: Set<UUID> = []
        for (questionKey, answer) in session.answers {
            guard let candidateID = answer.assignedCandidateID else { continue }
            guard let candidate = session.candidates.first(where: { $0.id == candidateID }) else { problems.append("Question \(questionKey) references a missing candidate."); continue }
            if candidate.reviewState != .approved { problems.append("Question \(questionKey) references a candidate that is not approved.") }
            if candidate.reviewState == .discarded { problems.append("Question \(questionKey) references a discarded candidate.") }
            if !seen.insert(candidateID).inserted { problems.append("Candidate \(candidate.label) is assigned more than once.") }
        }
        return problems.sorted()
    }

    public static func duplicateAgeKeys(in sessions: [InterviewSession]) -> [String] {
        Dictionary(grouping: sessions.filter(\.isActive), by: \.ageKey).filter { $0.value.count > 1 }.keys.sorted()
    }

    public static func readiness(for session: InterviewSession, requiredQuestionKeys: Set<String> = []) -> RecordingFirstReadinessReport {
        var blockers = validateAssignments(in: session)
        if session.recordings.contains(where: { $0.provisionalInPointUS != nil }) {
            blockers.append("A recording has an unmatched provisional In mark.")
        }
        for candidate in session.activeCandidates {
            guard let recording = session.recordings.first(where: { $0.id == candidate.sourceRecordingID }) else {
                blockers.append("\(candidate.label) references a missing source recording.")
                continue
            }
            guard let visible = candidate.visibleRange, visible.isValid else {
                blockers.append("\(candidate.label) has invalid answer boundaries.")
                continue
            }
            let sourceDuration = recording.mediaSignature.durationMicroseconds.map { MediaTime.microseconds($0) }
            if let sourceDuration, visible.end > sourceDuration {
                blockers.append("\(candidate.label) extends beyond its source recording.")
            }
            for segment in candidate.retainedSegments {
                guard validateInternalSegment(segment, for: candidate), sourceDuration.map({ segment.end <= $0 }) ?? true else {
                    blockers.append("\(candidate.label) has an invalid retained segment.")
                    break
                }
            }
        }
        let assigned = Set(session.answers.compactMap { $0.value.assignedCandidateID })
        for question in requiredQuestionKeys where session.answers[question]?.assignedCandidateID == nil { blockers.append("Question \(question) has no assigned candidate.") }
        let warnings = session.candidates.filter { $0.reviewState == .unreviewed || $0.reviewState == .needsReview }.map { "\($0.label) needs review." } + session.candidates.filter { $0.reviewState == .approved && !assigned.contains($0.id) }.map { "\($0.label) is approved but unassigned." }
        return RecordingFirstReadinessReport(blockers: Array(Set(blockers)).sorted(), warnings: Array(Set(warnings)).sorted())
    }

    public static func validateInternalSegment(_ segment: CandidateSegment, for candidate: AnswerCandidate) -> Bool {
        guard segment.isValid, let outer = candidate.visibleRange else { return false }; return segment.start >= outer.start && segment.end <= outer.end
    }

    /// Returns the exact retained answer pieces, adding the refined safety
    /// buffers only when the corresponding visible boundary was retained.
    /// This is the single range adapter shared by preview metadata and export.
    public static func publicationSegments(for candidate: AnswerCandidate) -> [CandidateSegment] {
        guard let visible = candidate.visibleRange, visible.isValid else { return [] }
        var segments = candidate.retainedSegments.filter { validateInternalSegment($0, for: candidate) }.sorted { $0.start < $1.start }
        if segments.isEmpty { segments = [visible] }
        guard let safe = candidate.safeRange, safe.isValid else { return segments }
        if segments[0].start == visible.start {
            segments[0].start = safe.start
        }
        if segments[segments.count - 1].end == visible.end {
            segments[segments.count - 1].end = safe.end
        }
        return segments.filter(\.isValid)
    }

    public static func publicationTimeline(for candidate: AnswerCandidate, transitionUS: Int64 = 120_000) -> CandidatePublicationTimeline {
        let segments = publicationSegments(for: candidate)
        var placements: [CandidatePublicationPlacement] = []
        var cursorUS: Int64 = 0
        for segment in segments {
            let segmentDurationUS = max(0, segment.end.microseconds - segment.start.microseconds)
            let previousDurationUS = placements.last.map { $0.sourceSegment.end.microseconds - $0.sourceSegment.start.microseconds } ?? 0
            let overlapUS = placements.isEmpty ? 0 : min(max(0, transitionUS), min(previousDurationUS / 2, segmentDurationUS / 2))
            let outputStartUS = max(0, cursorUS - overlapUS)
            let outputEndUS = outputStartUS + segmentDurationUS
            placements.append(CandidatePublicationPlacement(
                sourceSegment: segment,
                outputStart: .microseconds(outputStartUS),
                outputEnd: .microseconds(outputEndUS)
            ))
            cursorUS = outputEndUS
        }
        return CandidatePublicationTimeline(placements: placements, duration: .microseconds(max(0, cursorUS)))
    }

    public static func previewSegments(for candidate: AnswerCandidate, withBuffers: Bool) -> [CandidateSegment] {
        if withBuffers { return publicationSegments(for: candidate) }
        guard let visible = candidate.visibleRange, visible.isValid else { return [] }
        let retained = candidate.retainedSegments.filter { validateInternalSegment($0, for: candidate) }.sorted { $0.start < $1.start }
        return retained.isEmpty ? [visible] : retained
    }

    public static func retainedSegments(for outer: CandidateSegment, removing cuts: [CandidateSegment]) throws -> [CandidateSegment] {
        guard outer.isValid, cuts.allSatisfy({ $0.isValid && $0.start >= outer.start && $0.end <= outer.end }) else { throw RecordingFirstWorkflowError.invalidSegment }
        let sortedCuts = cuts.sorted(by: { $0.start < $1.start })
        for pair in zip(sortedCuts, sortedCuts.dropFirst()) where pair.1.start < pair.0.end {
            throw RecordingFirstWorkflowError.invalidSegment
        }
        var pieces = [outer]
        for cut in sortedCuts {
            pieces = pieces.flatMap { piece -> [CandidateSegment] in
                // A cut may be disjoint from a retained piece. Keep that piece
                // intact; only split the piece that actually contains the cut.
                if cut.end <= piece.start || cut.start >= piece.end { return [piece] }
                guard cut.start >= piece.start, cut.end <= piece.end else { return [] }
                var result: [CandidateSegment] = []
                if cut.start > piece.start { result.append(.init(start: piece.start, end: cut.start)) }
                if cut.end < piece.end { result.append(.init(start: cut.end, end: piece.end)) }
                return result
            }
        }
        return pieces.filter(\.isValid)
    }
}
