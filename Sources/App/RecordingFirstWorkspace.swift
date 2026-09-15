import AVFoundation
import AVKit
import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

enum RecordingFirstStage: String, CaseIterable, Identifiable {
    case capture
    case refine
    case assign
    case finish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Capture"
        case .refine: return "Refine"
        case .assign: return "Assign"
        case .finish: return "Finish"
        }
    }

    var systemImage: String {
        switch self {
        case .capture: return "record.circle"
        case .refine: return "slider.horizontal.3"
        case .assign: return "arrow.right.circle"
        case .finish: return "checkmark.seal"
        }
    }
}

struct RecordingFirstReadOnlyView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    let title: String
    let message: String
    let allowsRestore: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: allowsRestore ? "archivebox" : "lock.doc")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(model.selectedSession?.ageLabel ?? "Age Entry")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 500)
            if allowsRestore, let sessionID = model.selectedSessionID {
                Button("Restore Age Entry") { model.recordingFirstRestoreAge(sessionID) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(minWidth: 1_100, minHeight: 680)
        .padding(40)
    }
}

private extension InterviewStudioWorkspaceModel {
    var recordingFirstSession: InterviewSession? {
        guard let session = selectedSession, session.workflowKind == .recordingFirstV1 else { return nil }
        return session
    }

    @discardableResult
    func requireRecordingFirstEditingSession() -> Bool {
        guard let session = recordingFirstSession, session.isActive, session.compatibility.isWritable else {
            errorMessage = "This age entry is read-only. Restore it or open a compatible project before editing."
            return false
        }
        guard session.lifecycle == .open else {
            errorMessage = "Unlock the age entry before editing it."
            return false
        }
        return true
    }

    var recordingFirstRecording: SourceRecording? {
        guard let session = recordingFirstSession else { return nil }
        return session.recordings.first { $0.id == selectedRecordingID } ?? session.recordings.first
    }

    var recordingFirstCandidates: [AnswerCandidate] {
        guard let session = recordingFirstSession else { return [] }
        return session.candidates.sorted {
            let left = ($0.sourceOrder, $0.createdAt, $0.id.uuidString)
            let right = ($1.sourceOrder, $1.createdAt, $1.id.uuidString)
            return left.0 == right.0 ? (left.1 == right.1 ? left.2 < right.2 : left.1 < right.1) : left.0 < right.0
        }
    }

    var recordingFirstActiveCandidates: [AnswerCandidate] {
        recordingFirstCandidates.filter { $0.reviewState != .discarded }
    }

    var recordingFirstDiscardedCandidates: [AnswerCandidate] {
        recordingFirstCandidates.filter { $0.reviewState == .discarded }
    }

    var recordingFirstSelectedCandidate: AnswerCandidate? {
        guard let candidateID = recordingFirstSelectedCandidateID else { return nil }
        return recordingFirstSession?.candidates.first { $0.id == candidateID }
    }

    var recordingFirstAssignedQuestionKey: String? {
        guard let candidateID = recordingFirstSelectedCandidateID,
              let session = recordingFirstSession else { return nil }
        return session.answers.values.first { $0.assignedCandidateID == candidateID }?.questionKey
    }

    var recordingFirstReadiness: RecordingFirstReadinessReport {
        guard let session = recordingFirstSession else { return .init() }
        var report = RecordingFirstWorkflow.readiness(for: session)
        let unavailableRecordings = session.recordings.filter { document?.recordingURL(for: $0) == nil }
        if !unavailableRecordings.isEmpty {
            report.blockers.append("One or more source recordings are unavailable from the package. Re-import or recover them before locking.")
        }
        if session.recordings.contains(where: { $0.mediaSignature.sha256.isEmpty || $0.mediaSignature.byteCount <= 0 }) {
            report.blockers.append("One or more source recordings do not have a verified media signature.")
        }
        if document?.hasPendingRecordingImports == true || document?.consolidationRecoveryMessage != nil {
            report.blockers.append("Recording storage has pending recovery work. Save and resolve it before locking.")
        }
        if session.recordings.isEmpty {
            report.warnings.append("No recordings have been added.")
        }
        if session.recordings.contains(where: { $0.recordingState != .finished }) {
            report.warnings.append("One or more recordings are not marked Finished.")
        }
        report.warnings = Array(Set(report.warnings)).sorted()
        return report
    }

    func recordingFirstRestoreProvisionalIfNeeded() {
        guard recordingFirstCaptureState.inPoint == nil,
              let recording = recordingFirstRecording,
              let provisionalInPointUS = recording.provisionalInPointUS else { return }
        recordingFirstCaptureState = RecordingCaptureState(inPoint: .microseconds(provisionalInPointUS))
    }

    var recordingFirstUnresolvedCount: Int {
        recordingFirstActiveCandidates.filter { $0.reviewState == .unreviewed || $0.reviewState == .needsReview || $0.reviewState == .skipped }.count
    }

    var recordingFirstApprovedUnassignedCount: Int {
        let assigned = Set(recordingFirstSession?.answers.values.compactMap(\.assignedCandidateID) ?? [])
        return recordingFirstActiveCandidates.filter { $0.reviewState == .approved && !assigned.contains($0.id) }.count
    }

    var recordingFirstTimelineRange: SelectedTimelineRange? {
        guard let recording = recordingFirstRecording else { return nil }
        let duration = waveform?.durationUS ?? recording.mediaSignature.durationMicroseconds ?? 0
        guard duration > 0 else { return nil }
        guard let candidate = recordingFirstSelectedCandidate,
              candidate.sourceRecordingID == recording.id else {
            return SelectedTimelineRange(durationUS: duration, visibleStartUS: 0, visibleEndUS: duration, safeLeadingStartUS: nil, safeTrailingEndUS: nil)
        }
        let visible = candidate.visibleRange
        let safe = candidate.safeRange
        let start = min(max(visible?.start.microseconds ?? 0, 0), duration)
        let end = min(max(visible?.end.microseconds ?? duration, start), duration)
        return SelectedTimelineRange(
            durationUS: duration,
            visibleStartUS: start,
            visibleEndUS: end,
            safeLeadingStartUS: safe?.start.microseconds,
            safeTrailingEndUS: safe?.end.microseconds
        )
    }

    func recordingFirstSelectRecording(_ recordingID: UUID) {
        selectedRecordingID = recordingID
        recordingFirstSelectedCandidateID = nil
        recordingFirstCutStartUS = nil
        recordingFirstCutEndUS = nil
        if let recording = recordingFirstSession?.recordings.first(where: { $0.id == recordingID }),
           let provisionalInPointUS = recording.provisionalInPointUS {
            recordingFirstCaptureState = RecordingCaptureState(inPoint: .microseconds(provisionalInPointUS))
        } else {
            recordingFirstCaptureState = .init()
        }
        if let recording = recordingFirstSession?.recordings.first(where: { $0.id == recordingID }),
           let url = document?.recordingURL(for: recording) {
            replacePlayer(with: url)
        }
    }

    func recordingFirstSelectAge(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID && $0.isActive }) else { return }
        selectedSessionID = session.id
        selectedRecordingID = session.recordings.first?.id
        recordingFirstSelectedCandidateID = nil
        recordingFirstCaptureState = .init()
        recordingFirstCutStartUS = nil
        recordingFirstCutEndUS = nil
        recordingFirstStage = .capture
        player?.pause()
    }

    func recordingFirstSelectCandidate(_ candidateID: UUID) {
        guard let candidate = recordingFirstSession?.candidates.first(where: { $0.id == candidateID }) else { return }
        recordingFirstSelectedCandidateID = candidateID
        selectedRecordingID = candidate.sourceRecordingID
        recordingFirstCutStartUS = nil
        recordingFirstCutEndUS = nil
        if let url = document?.recordingURL(for: recordingFirstSession?.recordings.first(where: { $0.id == candidate.sourceRecordingID }) ?? SourceRecording.placeholder(for: candidate)) {
            replacePlayer(with: url)
        }
        if let start = candidate.visibleRange?.start.microseconds {
            seek(to: start)
        }
    }

    func recordingFirstPlayerTimestamp() -> Int64? {
        guard let player else {
            errorMessage = "Choose a recording before marking it."
            return nil
        }
        let time = player.currentTime()
        guard time.isNumeric, time.seconds.isFinite else {
            errorMessage = "The recording time is not available yet. Try again when playback is ready."
            return nil
        }
        let value = max(0, Int64((time.seconds * 1_000_000).rounded()))
        if let duration = recordingFirstRecording?.mediaSignature.durationMicroseconds, value > duration {
            return duration
        }
        return value
    }

    func recordingFirstMarkIn() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let recording = recordingFirstRecording, let timestamp = recordingFirstPlayerTimestamp() else { return }
        do {
            var state = recordingFirstCaptureState
            let completed = try RecordingFirstWorkflow.captureIO(timestamp: .microseconds(timestamp), state: &state, mark: "i")
            if let completed {
                appendRecordingFirstCandidate(completed, recordingID: recording.id)
            }
            recordingFirstCaptureState = state
            updateRecordingFirstState(recordingID: recording.id, state: .inProgress, provisionalInPointUS: state.inPoint?.microseconds)
            progressMessage = completed == nil ? "In marked at \(formatMicroseconds(timestamp))." : "Clip committed. In marked at \(formatMicroseconds(timestamp)); press O for its Out point."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstMarkOut() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let recording = recordingFirstRecording, let timestamp = recordingFirstPlayerTimestamp() else { return }
        do {
            var state = recordingFirstCaptureState
            _ = try RecordingFirstWorkflow.captureIO(timestamp: .microseconds(timestamp), state: &state, mark: "o")
            recordingFirstCaptureState = state
            updateRecordingFirstState(recordingID: recording.id, state: .inProgress, provisionalInPointUS: state.inPoint?.microseconds)
            progressMessage = "Out marked at \(formatMicroseconds(timestamp)). Press I to commit this clip and begin the next one."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstUndoCapture() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        if recordingFirstCaptureState.inPoint != nil {
            recordingFirstCaptureState = .init()
            progressMessage = "The provisional mark was removed."
            if let recordingID = recordingFirstRecording?.id {
                updateRecordingFirstState(recordingID: recordingID, state: .inProgress, provisionalInPointUS: nil)
            }
            return
        }
        guard let recording = recordingFirstRecording,
              let candidateIndex = sessions[sessionIndex].candidates.lastIndex(where: { $0.sourceRecordingID == recording.id && $0.reviewState != .discarded }) else {
            return
        }
        sessions[sessionIndex].candidates[candidateIndex].reviewState = .discarded
        sessions[sessionIndex].candidates[candidateIndex].updatedAt = Date()
        sessions[sessionIndex].revision += 1
        progressMessage = "The most recent clip was moved to Recently Discarded. Undo is available in the Edit menu."
        flushToDocument()
    }

    @discardableResult
    func recordingFirstFinishRecording(discardUnmatched: Bool = false) -> Bool {
        guard requireRecordingFirstEditingSession() else { return false }
        guard let recording = recordingFirstRecording,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return false }
        guard sessions[sessionIndex].lifecycle != .locked else {
            errorMessage = "Unlock the age entry before finishing this recording."
            return false
        }
        if recordingFirstCaptureState.inPoint != nil && !recordingFirstCaptureState.hasValidPair {
            guard discardUnmatched else {
                recordingFirstNeedsFinishConfirmation = true
                errorMessage = nil
                return false
            }
            recordingFirstCaptureState = .init()
        }
        if recordingFirstCaptureState.hasValidPair,
           let segment = try? RecordingFirstWorkflow.commitProvisional(&recordingFirstCaptureState) {
            appendRecordingFirstCandidate(segment, recordingID: recording.id)
        }
        updateRecordingFirstState(recordingID: recording.id, state: .finished, provisionalInPointUS: nil)
        recordingFirstNeedsFinishConfirmation = false
        recordingFirstStage = .refine
        recordingFirstSelectedCandidateID = sessions[sessionIndex].candidates.first(where: { $0.sourceRecordingID == recording.id && $0.reviewState != .discarded })?.id
        player?.pause()
        progressMessage = "\(recording.originalFilename) is finished. Review its clips next."
        flushToDocument()
        return true
    }

    private func appendRecordingFirstCandidate(_ segment: CandidateSegment, recordingID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let recording = sessions[sessionIndex].recordings.first(where: { $0.id == recordingID }) else { return }
        var candidate = RecordingFirstWorkflow.makeCandidate(
            segment: segment,
            recording: recording,
            clipNumber: sessions[sessionIndex].nextClipNumber(for: recordingID),
            sourceOrder: sessions[sessionIndex].candidates.count
        )
        let durationUS = recording.mediaSignature.durationMicroseconds ?? segment.end.microseconds
        candidate.refinedBoundaries = RefinedBoundaries(
            visibleStart: segment.start,
            visibleEnd: segment.end,
            safeLeadingStart: .microseconds(max(0, segment.start.microseconds - 2_000_000)),
            safeTrailingEnd: .microseconds(min(durationUS, segment.end.microseconds + 2_000_000)),
            confidence: 0.4,
            reasons: ["Captured from explicit In/Out markers; refine before approval."],
            algorithmIdentifier: "recording-first-raw-markers",
            algorithmVersion: "1.0",
            manualOverride: false
        )
        sessions[sessionIndex].candidates.append(candidate)
        sessions[sessionIndex].revision += 1
        recordingFirstSelectedCandidateID = candidate.id
        flushToDocument()
    }

    func recordingFirstPlaySelectedCandidate(withBuffers: Bool) {
        guard let candidate = recordingFirstSelectedCandidate else { return }
        let segments = RecordingFirstWorkflow.previewSegments(for: candidate, withBuffers: withBuffers)
        guard let first = segments.first, first.isValid else {
            errorMessage = "This clip does not have a valid preview range yet."
            return
        }
        if segments.count == 1 {
            playRange(startUS: first.start.microseconds, endUS: first.end.microseconds)
            return
        }
        guard let recording = recordingFirstSession?.recordings.first(where: { $0.id == candidate.sourceRecordingID }),
              let sourceURL = document?.recordingURL(for: recording) else {
            errorMessage = "The source recording is not available for preview."
            return
        }
        let candidateID = candidate.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: sourceURL)
                guard let video = try await asset.loadTracks(withMediaType: .video).first,
                      let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw RecordingFirstWorkflowError.candidateNotFound
                }
                let composition = AVMutableComposition()
                guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                      let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw RecordingFirstWorkflowError.invalidSegment
                }
                var cursor = CMTime.zero
                for segment in segments {
                    let start = CMTime(value: segment.start.value, timescale: segment.start.timescale)
                    let end = CMTime(value: segment.end.value, timescale: segment.end.timescale)
                    let range = CMTimeRange(start: start, duration: CMTimeSubtract(end, start))
                    try videoTrack.insertTimeRange(range, of: video, at: cursor)
                    try audioTrack.insertTimeRange(range, of: audio, at: cursor)
                    cursor = CMTimeAdd(cursor, range.duration)
                }
                guard self.recordingFirstSelectedCandidateID == candidateID else { return }
                self.playComposition(composition)
                self.progressMessage = withBuffers ? "Previewing with safe buffers." : "Previewing the answer with internal cuts removed."
            } catch {
                self.errorMessage = "Preview could not be prepared: \(error.localizedDescription)"
            }
        }
    }

    private func updateRecordingFirstState(recordingID: UUID, state: RecordingProgressState, provisionalInPointUS: Int64? = nil) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let recordingIndex = sessions[sessionIndex].recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        sessions[sessionIndex].recordings[recordingIndex].recordingState = state
        sessions[sessionIndex].recordings[recordingIndex].provisionalInPointUS = provisionalInPointUS
        sessions[sessionIndex].revision += 1
        flushToDocument()
    }

    func setRecordingFirstPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.defaultRate = rate
        if player?.timeControlStatus == .playing {
            player?.rate = rate
        }
    }

    func recordingFirstApproveSelectedCandidate() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let candidateID = recordingFirstSelectedCandidateID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        var candidate = sessions[sessionIndex].candidates[candidateIndex]
        guard let visible = candidate.visibleRange, visible.isValid,
              candidate.retainedSegments.allSatisfy({ $0.isValid && $0.start >= visible.start && $0.end <= visible.end }) else {
            errorMessage = "The answer boundaries are invalid. Set a positive range before approving."
            return
        }
        if candidate.retainedSegments.isEmpty {
            candidate.retainedSegments = [visible]
        }
        candidate.reviewState = .approved
        candidate.updatedAt = Date()
        sessions[sessionIndex].candidates[candidateIndex] = candidate
        sessions[sessionIndex].revision += 1
        progressMessage = "\(candidate.label) approved."
        flushToDocument()
    }

    func recordingFirstSkipSelectedCandidate() {
        updateRecordingFirstCandidateState(.skipped, message: "Clip skipped for now.")
    }

    func recordingFirstDiscardSelectedCandidate() {
        guard recordingFirstAssignedQuestionKey == nil else {
            errorMessage = "Unassign this answer before discarding its clip."
            return
        }
        updateRecordingFirstCandidateState(.discarded, message: "Clip moved to Recently Discarded.")
    }

    func recordingFirstRestoreCandidate(_ candidateID: UUID) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        sessions[sessionIndex].candidates[candidateIndex].reviewState = .needsReview
        sessions[sessionIndex].candidates[candidateIndex].updatedAt = Date()
        sessions[sessionIndex].revision += 1
        recordingFirstSelectedCandidateID = candidateID
        selectedRecordingID = sessions[sessionIndex].candidates[candidateIndex].sourceRecordingID
        progressMessage = "Clip restored and marked Needs Review."
        flushToDocument()
    }

    private func updateRecordingFirstCandidateState(_ state: CandidateReviewState, message: String) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let candidateID = recordingFirstSelectedCandidateID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        sessions[sessionIndex].candidates[candidateIndex].reviewState = state
        sessions[sessionIndex].candidates[candidateIndex].updatedAt = Date()
        sessions[sessionIndex].revision += 1
        progressMessage = message
        flushToDocument()
    }

    func recordingFirstSetBoundary(startUS: Int64? = nil, endUS: Int64? = nil) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let candidateID = recordingFirstSelectedCandidateID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }),
              let candidate = sessions[sessionIndex].candidates[safe: candidateIndex],
              let oldVisible = candidate.visibleRange else { return }
        let start = max(0, startUS ?? oldVisible.start.microseconds)
        let end = max(start, endUS ?? oldVisible.end.microseconds)
        guard end > start else {
            errorMessage = "The answer end must be later than its start."
            return
        }
        var updated = candidate
        let duration = recordingFirstRecording?.mediaSignature.durationMicroseconds ?? end
        let safeStart = max(0, start - 2_000_000)
        let safeEnd = min(duration, end + 2_000_000)
        updated.refinedBoundaries = RefinedBoundaries(
            visibleStart: .microseconds(start),
            visibleEnd: .microseconds(end),
            safeLeadingStart: .microseconds(safeStart),
            safeTrailingEnd: .microseconds(safeEnd),
            confidence: 1,
            reasons: ["Manually adjusted in Refine."],
            algorithmIdentifier: "manual-boundary",
            algorithmVersion: "1.0",
            manualOverride: true
        )
        let existingCuts = internalCuts(for: candidate, outer: oldVisible)
        updated.retainedSegments = (try? RecordingFirstWorkflow.retainedSegments(for: CandidateSegment(start: .microseconds(start), end: .microseconds(end)), removing: existingCuts)) ?? [CandidateSegment(start: .microseconds(start), end: .microseconds(end))]
        if updated.reviewState == .approved { updated.reviewState = .needsReview }
        updated.updatedAt = Date()
        sessions[sessionIndex].candidates[candidateIndex] = updated
        sessions[sessionIndex].revision += 1
        flushToDocument()
    }

    func recordingFirstSetCutIn() {
        guard requireRecordingFirstEditingSession() else { return }
        recordingFirstCutStartUS = recordingFirstPlayerTimestamp()
    }

    func recordingFirstSetCutOut() {
        guard requireRecordingFirstEditingSession() else { return }
        recordingFirstCutEndUS = recordingFirstPlayerTimestamp()
    }

    func recordingFirstRemoveSelection() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let candidateID = recordingFirstSelectedCandidateID,
              let start = recordingFirstCutStartUS,
              let end = recordingFirstCutEndUS,
              end > start,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }),
              let outer = sessions[sessionIndex].candidates[candidateIndex].visibleRange else {
            errorMessage = "Set a valid Cut In and Cut Out inside the answer first."
            return
        }
        let cut = CandidateSegment(start: .microseconds(start), end: .microseconds(end))
        guard cut.start >= outer.start, cut.end <= outer.end else {
            errorMessage = "Internal cuts must remain inside the answer boundaries."
            return
        }
        let currentCuts = internalCuts(for: sessions[sessionIndex].candidates[candidateIndex], outer: outer)
        guard let retained = try? RecordingFirstWorkflow.retainedSegments(for: outer, removing: currentCuts + [cut]) else {
            errorMessage = "That selection overlaps an existing internal cut."
            return
        }
        sessions[sessionIndex].candidates[candidateIndex].retainedSegments = retained
        if sessions[sessionIndex].candidates[candidateIndex].reviewState == .approved {
            sessions[sessionIndex].candidates[candidateIndex].reviewState = .needsReview
        }
        sessions[sessionIndex].candidates[candidateIndex].updatedAt = Date()
        sessions[sessionIndex].revision += 1
        recordingFirstCutStartUS = nil
        recordingFirstCutEndUS = nil
        progressMessage = "Selection removed. Preview Answer will skip it."
        flushToDocument()
    }

    private func internalCuts(for candidate: AnswerCandidate, outer: CandidateSegment) -> [CandidateSegment] {
        let retained = candidate.retainedSegments.filter(\.isValid).sorted { $0.start < $1.start }
        guard !retained.isEmpty else { return [] }
        var cuts: [CandidateSegment] = []
        var cursor = outer.start
        for segment in retained {
            if segment.start > cursor { cuts.append(CandidateSegment(start: cursor, end: segment.start)) }
            cursor = max(cursor, segment.end)
        }
        if cursor < outer.end { cuts.append(CandidateSegment(start: cursor, end: outer.end)) }
        return cuts
    }

    func recordingFirstAssignCandidate(_ candidateID: UUID, to questionKey: String) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        var session = sessions[sessionIndex]
        do {
            if let existingID = session.answers[questionKey]?.assignedCandidateID,
               existingID != candidateID,
               let current = session.candidates.first(where: { $0.id == existingID }),
               let proposed = session.candidates.first(where: { $0.id == candidateID }) {
                recordingFirstComparison = RecordingFirstWorkflow.compare(current: current, proposed: proposed)
                recordingFirstComparisonQuestionKey = questionKey
                return
            }
            try RecordingFirstWorkflow.assign(candidateID: candidateID, to: questionKey, in: &session)
            sessions[sessionIndex] = session
            recordingFirstSelectedCandidateID = candidateID
            let candidateLabel = session.candidates.first(where: { $0.id == candidateID })?.label ?? "clip"
            let questionLabel = project.activeQuestions.first(where: { $0.questionKey == questionKey })?.displayText ?? questionKey
            progressMessage = "Assigned \(candidateLabel) to \(questionLabel)."
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstReplaceComparedCandidate() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let comparison = recordingFirstComparison,
              let questionKey = recordingFirstComparisonQuestionKey,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        var session = sessions[sessionIndex]
        do {
            try RecordingFirstWorkflow.assign(candidateID: comparison.proposed.id, to: questionKey, in: &session, replacing: true)
            sessions[sessionIndex] = session
            recordingFirstComparison = nil
            recordingFirstComparisonQuestionKey = nil
            recordingFirstSelectedCandidateID = comparison.proposed.id
            progressMessage = "The new clip replaced the current answer."
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstUnassign(questionKey: String) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              var answer = sessions[sessionIndex].answers[questionKey] else { return }
        answer.assignedCandidateID = nil
        answer.state = .notStarted
        sessions[sessionIndex].answers[questionKey] = answer
        sessions[sessionIndex].revision += 1
        flushToDocument()
    }

    func recordingFirstEditAssignedCandidate(_ candidateID: UUID) {
        guard requireRecordingFirstEditingSession() else { return }
        recordingFirstSelectedCandidateID = candidateID
        selectedRecordingID = recordingFirstSession?.candidates.first(where: { $0.id == candidateID })?.sourceRecordingID
        recordingFirstStage = .refine
        progressMessage = "Refine Assigned Answer. Approving changes will keep the assignment and clear its review warning."
    }

    func recordingFirstLock() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        do {
            let report = recordingFirstReadiness
            guard report.blockers.isEmpty else {
                errorMessage = report.blockers.joined(separator: "\n")
                return
            }
            let warnings = try sessions[sessionIndex].lockWithWarnings()
            progressMessage = warnings.isEmpty ? "Age entry locked for publication." : "Age entry locked with \(warnings.count) warning(s)."
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstUnlock() {
        guard let session = recordingFirstSession, session.isActive, session.compatibility.isWritable else {
            errorMessage = "This age entry is read-only. Restore it or open a compatible project before editing."
            return
        }
        guard session.lifecycle == .locked else { return }
        unlockSelectedYear()
        recordingFirstStage = .finish
    }

    func recordingFirstArchiveSelectedAge() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        do {
            try sessions[sessionIndex].archive()
            selectedSessionID = sessions.first(where: { $0.isActive })?.id
            selectedRecordingID = selectedSession?.recordings.first?.id
            recordingFirstStage = .capture
            progressMessage = "Age entry archived. Its contents and package media remain intact."
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstRestoreAge(_ sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sessions[sessionIndex].compatibility.isWritable else {
            errorMessage = "This age entry is read-only because its workflow or package format is unsupported."
            return
        }
        let normalized = sessions[sessionIndex].normalizedAge()
        guard !sessions.contains(where: { $0.id != sessionID && $0.isActive && RecordingFirstWorkflow.sameAge($0, normalized: normalized) }) else {
            errorMessage = "An active age entry already uses that age."
            return
        }
        do {
            try sessions[sessionIndex].restore()
            selectedSessionID = sessionID
            selectedRecordingID = sessions[sessionIndex].recordings.first?.id
            isShowingArchivedAges = false
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstChangeAge(to value: Double) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let normalized = RecordingFirstWorkflow.normalizedAge(value: value),
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        guard !sessions.contains(where: { $0.id != selectedSessionID && $0.isActive && RecordingFirstWorkflow.sameAge($0, normalized: normalized) }) else {
            errorMessage = "An active age entry already uses that age."
            return
        }
        do {
            try sessions[sessionIndex].changeAge(key: normalized.key, label: normalized.label, sortValue: normalized.sortValue)
            sessions.sort { ($0.ageSortValue ?? .greatestFiniteMagnitude) < ($1.ageSortValue ?? .greatestFiniteMagnitude) }
        progressMessage = "Age changed to \(normalized.label). Existing work was preserved."
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordingFirstRequestAgeChange(to value: Double) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let session = recordingFirstSession else { return }
        let hasWork = !session.recordings.isEmpty || !session.candidates.isEmpty || !session.answers.isEmpty
        if hasWork {
            recordingFirstPendingAgeChange = value
        } else {
            recordingFirstChangeAge(to: value)
        }
    }

    func importFinderRecordings(urls: [URL]) {
        guard !urls.isEmpty, !isBusy else { return }
        guard requireRecordingFirstEditingSession() else { return }
        guard document?.packageStore != nil else {
            errorMessage = "Save the project before importing source recordings."
            return
        }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            errorMessage = "Add or select an age entry first."
            return
        }
        let session = sessions[sessionIndex]
        guard let store = document?.packageStore else {
            errorMessage = "Save the project before importing source recordings."
            return
        }
        var totalBytes: Int64 = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                errorMessage = "Only readable local video files can be imported."
                return
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(size.int64Value)
            guard !overflow else {
                errorMessage = "The selected recordings are too large to import safely."
                return
            }
            totalBytes = sum
        }
        let (copyBytes, copyOverflow) = totalBytes.multipliedReportingOverflow(by: 2)
        let headroom = max(Int64(512 * 1024 * 1024), totalBytes / 10)
        let (requiredBytes, requiredOverflow) = copyBytes.addingReportingOverflow(headroom)
        let capacity: Int64?
        do {
            let volumeValues = try store.rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            capacity = volumeValues.volumeAvailableCapacityForImportantUsage ?? volumeValues.volumeAvailableCapacity.map(Int64.init)
        } catch {
            capacity = nil
        }
        if copyOverflow || requiredOverflow || capacity == nil || capacity! < requiredBytes {
            let availableLabel = capacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown available space"
            errorMessage = "Not enough free storage to stage these recordings safely. At least \(ByteCountFormatter.string(fromByteCount: max(requiredBytes, 0), countStyle: .file)) is needed; \(availableLabel) is available."
            return
        }
        isBusy = true
        progressMessage = "Staging \(urls.count) recording(s)…"
        let stagingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YearlyInterviewStudio/ImportStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importTask = Task.detached(priority: .userInitiated) {
            var updated = session
            var stagedImports: [StagedRecordingImport] = []
            var knownHashes = Set(updated.recordings.map { $0.mediaSignature.sha256 })
            for (index, url) in urls.enumerated() {
                let sourceHash = sha256(fileURL: url)
                if !sourceHash.isEmpty && knownHashes.contains(sourceHash) { continue }
                let staged = try await store.stageRecordingImport(
                    from: url,
                    ageKey: session.ageKey,
                    ageLabel: session.ageLabel,
                    source: .finder,
                    stagingRoot: stagingRoot,
                    order: updated.recordings.count + index,
                    recordingNumber: updated.nextRecordingNumber + index
                )
                if staged.imported.duplicateOf == nil {
                    updated.recordings.append(staged.imported.recording)
                    stagedImports.append(staged)
                    knownHashes.insert(staged.imported.recording.mediaSignature.sha256)
                }
            }
            return (updated, stagedImports)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await importTask.value
                guard let currentIndex = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                self.sessions[currentIndex] = result.0
                if self.selectedRecordingID == nil || !result.0.recordings.contains(where: { $0.id == self.selectedRecordingID }) {
                    self.selectedRecordingID = result.0.recordings.first?.id
                }
                self.document?.stage(recordingImports: result.1)
                self.progressMessage = result.1.isEmpty ? "Those recordings are already in this project." : "Recording(s) ready. Save the project to finish importing them."
                self.isBusy = false
                self.flushToDocument()
            } catch {
                self.errorMessage = error.localizedDescription
                self.progressMessage = nil
                self.isBusy = false
                try? FileManager.default.removeItem(at: stagingRoot)
            }
        }
    }

    func recordingFirstAddQuestion(_ text: String) {
        guard requireRecordingFirstEditingSession() else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = project.insertQuestion(displayText: text)
        selectedQuestionKey = project.activeQuestions.last?.questionKey
        flushToDocument()
    }

    func recordingFirstUpdateQuestion(_ key: String, text: String) {
        guard requireRecordingFirstEditingSession() else { return }
        guard let index = project.questions.firstIndex(where: { $0.questionKey == key }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        project.questions[index].displayText = text
        project.updatedAt = Date()
        flushToDocument()
    }

    func recordingFirstMoveQuestion(_ key: String, by offset: Int) {
        guard requireRecordingFirstEditingSession() else { return }
        selectedQuestionKey = key
        moveSelectedQuestion(by: offset)
    }

    private func formatMicroseconds(_ value: Int64) -> String {
        String(format: "%.2fs", Double(value) / 1_000_000)
    }
}

private extension SourceRecording {
    static func placeholder(for candidate: AnswerCandidate) -> SourceRecording {
        SourceRecording(ageKey: "unknown", ageLabel: "Unknown", packageRelativePath: "missing", originalFilename: "missing", importSource: .finder, order: candidate.sourceOrder, recordingNumber: candidate.recordingNumber, mediaSignature: MediaSignature(byteCount: 0, sha256: ""))
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct RecordingFirstWorkspaceView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    @State private var showLockWarningAlert = false
    @State private var showArchiveAlert = false
    @State private var showChangeAgeAlert = false
    @State private var ageDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            ageHeader
            if let recoveryMessage = model.document?.consolidationRecoveryMessage {
                Label(recoveryMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            stageBar
            Divider()
            HStack(spacing: 0) {
                sourcesSidebar
                Divider()
                stageContent
            }
        }
        .frame(minWidth: 1_100, minHeight: 680)
        .alert("Project issue", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Finish this recording?", isPresented: $model.recordingFirstNeedsFinishConfirmation) {
            Button("Finish Without It", role: .destructive) {
                _ = model.recordingFirstFinishRecording(discardUnmatched: true)
            }
            Button("Keep Capturing", role: .cancel) {}
        } message: {
            Text("An In mark has no matching Out mark. The unfinished mark will remain if you keep capturing, or be explicitly discarded if you finish now.")
        }
        .alert("Lock with unresolved items?", isPresented: $showLockWarningAlert) {
            Button("Lock Age Entry") { model.recordingFirstLock() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(lockWarningMessage)
        }
        .alert("Archive age entry?", isPresented: $showArchiveAlert) {
            Button("Archive", role: .destructive) { model.recordingFirstArchiveSelectedAge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the age entry from the active project and future renders. Its recordings and edits remain in the package and can be restored.")
        }
        .alert("Change the age for this entry?", isPresented: Binding(get: { model.recordingFirstPendingAgeChange != nil }, set: { if !$0 { model.recordingFirstPendingAgeChange = nil } })) {
            Button("Change Age") {
                if let value = model.recordingFirstPendingAgeChange {
                    model.recordingFirstPendingAgeChange = nil
                    model.recordingFirstChangeAge(to: value)
                }
            }
            Button("Keep Current Age", role: .cancel) { model.recordingFirstPendingAgeChange = nil }
        } message: {
            Text("This keeps the same age entry, recordings, candidates, assignments, and stable IDs, but changes its publication identity and order.")
        }
        .sheet(isPresented: $model.isShowingManageQuestions) {
            ManageQuestionsView(model: model)
        }
        .sheet(isPresented: $model.isAddingYear) {
            NewInterviewYearSheet(draft: model.newInterviewYearDraft) { age, calendarYear in
                if model.addYear(age: age, calendarYear: calendarYear) {
                    model.isAddingYear = false
                }
            }
        }
        .sheet(isPresented: $model.isShowingArchivedAges) {
            ArchivedAgesView(model: model)
        }
        .sheet(item: $model.recordingFirstComparison) { comparison in
            CandidateComparisonView(model: model, comparison: comparison)
        }
        .sheet(isPresented: $showChangeAgeAlert) {
            ChangeAgeView(initialValue: model.recordingFirstSession?.ageSortValue ?? 0) { value in
                model.recordingFirstRequestAgeChange(to: value)
            }
        }
    }

    private var lockWarningMessage: String {
        let report = model.recordingFirstReadiness
        if report.warnings.isEmpty { return "The age entry has no unresolved warnings." }
        return report.warnings.prefix(8).joined(separator: "\n")
    }

    private var currentSession: InterviewSession? { model.selectedSession }

    private var ageHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentSession?.ageLabel ?? "Age Entry")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(model.project.person.displayName)
                    if let year = currentSession?.calendarYear {
                        Text("· \(String(year))")
                    }
                    Text(currentSession?.lifecycle == .locked ? "Locked for publication" : "Open")
                        .foregroundStyle(currentSession?.lifecycle == .locked ? .orange : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(model.sessions.filter(\.isActive)) { session in
                    Button {
                        model.recordingFirstSelectAge(session.id)
                    } label: {
                        Label(session.ageLabel, systemImage: session.id == model.selectedSessionID ? "checkmark" : "circle")
                    }
                }
                Divider()
                Button("New Age Entry…", systemImage: "plus") {
                    model.isAddingYear = true
                }
            } label: {
                Label("Age Entries", systemImage: "rectangle.stack")
            }
            .menuStyle(.borderlessButton)
            Menu {
                Button("Manage Questions…", systemImage: "list.bullet.rectangle") { model.isShowingManageQuestions = true }
                Button("Change Age…", systemImage: "pencil") { showChangeAgeAlert = true }
                Divider()
                Button("Archive Age Entry…", systemImage: "archivebox") { showArchiveAlert = true }
                Button("Restore Archived Age…", systemImage: "arrow.uturn.backward") { model.isShowingArchivedAges = true }
            } label: {
                Label("Age Entry", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var stageBar: some View {
        HStack(spacing: 6) {
            ForEach(RecordingFirstStage.allCases) { stage in
                Button {
                    model.recordingFirstStage = stage
                } label: {
                    Label(stage.title, systemImage: stage.systemImage)
                        .frame(minWidth: 112)
                }
                .buttonStyle(.bordered)
                .tint(model.recordingFirstStage == stage ? .accentColor : nil)
                .keyboardShortcut(shortcut(for: stage), modifiers: [.command])
            }
            Spacer()
            if let message = model.progressMessage {
                Label(message, systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shortcut(for stage: RecordingFirstStage) -> KeyEquivalent {
        switch stage {
        case .capture: return "1"
        case .refine: return "2"
        case .assign: return "3"
        case .finish: return "4"
        }
    }

    private var sourcesSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
                Button("Add Recordings…", systemImage: "plus") { model.importFinderRecordings() }
                    .labelStyle(.iconOnly)
                    .help("Add recordings from Finder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            List(selection: $model.selectedRecordingID) {
                ForEach(model.recordingFirstSession?.recordings ?? []) { recording in
                    RecordingFirstSourceRow(recording: recording, candidateCount: model.recordingFirstSession?.candidates.filter { $0.sourceRecordingID == recording.id && $0.reviewState != .discarded }.count ?? 0)
                        .tag(recording.id)
                        .contextMenu {
                            if recording.recordingState != .finished {
                                Button("Mark Recording Finished") {
                                    model.selectedRecordingID = recording.id
                                    _ = model.recordingFirstFinishRecording()
                                }
                            } else {
                                Button("Reopen in Capture") {
                                    model.selectedRecordingID = recording.id
                                    model.recordingFirstStage = .capture
                                }
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: model.selectedRecordingID) { _, newID in
                if let newID { model.recordingFirstSelectRecording(newID) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                model.importFinderRecordings(urls: urls)
                return true
            }
            if model.recordingFirstSession?.recordings.isEmpty == true {
                ContentUnavailableView("No recordings yet", systemImage: "video.badge.plus", description: Text("Add recordings here or drop movie files into this list."))
                    .padding(12)
            }
        }
        .frame(minWidth: 235, idealWidth: 270, maxWidth: 320)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch model.recordingFirstStage {
        case .capture:
            RecordingFirstCaptureView(model: model)
        case .refine:
            RecordingFirstRefineView(model: model)
        case .assign:
            RecordingFirstAssignView(model: model)
        case .finish:
            RecordingFirstFinishView(model: model, showLockWarningAlert: $showLockWarningAlert)
        }
    }
}

private struct RecordingFirstSourceRow: View {
    let recording: SourceRecording
    let candidateCount: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording \(recording.recordingNumber)")
                    .lineLimit(1)
                Text("\(recording.originalFilename) · \(stateLabel) · \(candidateCount) clips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: recording.recordingState == .finished ? "checkmark.circle.fill" : "video.circle")
                .foregroundStyle(recording.recordingState == .finished ? .green : .secondary)
        }
    }

    private var stateLabel: String {
        switch recording.recordingState {
        case .notStarted: return "Not Started"
        case .inProgress: return "In Progress"
        case .finished: return "Finished"
        }
    }
}

private struct RecordingFirstCaptureView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture answers from the recording")
                        .font(.title3.weight(.semibold))
                    Text("Mark each answer while playback continues. I/O marks are saved as candidates; review happens next.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in
                        Button(rateLabel(rate)) { model.setRecordingFirstPlaybackRate(rate) }
                    }
                } label: {
                    Label(rateLabel(model.playbackRate), systemImage: "speedometer")
                }
                .help("Playback speed affects listening only; saved timestamps remain source-accurate.")
            }
            if let recording = model.recordingFirstRecording,
               let url = model.document?.recordingURL(for: recording) {
                RecordingFirstPlayerContainer(player: model.player)
                    .frame(minHeight: 330)
                    .onAppear {
                        model.recordingFirstRestoreProvisionalIfNeeded()
                        model.replacePlayer(with: url)
                    }
                    .onChange(of: url) { _, newURL in model.replacePlayer(with: newURL) }
                captureControls
                if model.recordingFirstCaptureState.inPoint != nil {
                    Label(
                        model.recordingFirstCaptureState.hasValidPair ? "Provisional clip ready to commit" : "Provisional In mark — press O to finish it",
                        systemImage: model.recordingFirstCaptureState.hasValidPair ? "circle.dotted.circle" : "record.circle"
                    )
                    .foregroundStyle(.orange)
                }
                RecordingFirstCandidateStrip(model: model)
            } else {
                ContentUnavailableView("Add a recording to begin", systemImage: "video.badge.plus", description: Text("Use Add Recordings… in the Sources sidebar. Nothing starts playing automatically."))
                    .frame(maxWidth: .infinity, minHeight: 420)
            }
            Spacer()
        }
        .padding(20)
        .task(id: model.recordingFirstRecording?.id) { await model.prepareMediaAnalysis() }
    }

    private var captureControls: some View {
        HStack(spacing: 8) {
            Button("Mark In", systemImage: "bracket") { model.recordingFirstMarkIn() }
                .keyboardShortcut("i", modifiers: [])
                .buttonStyle(.borderedProminent)
            Button("Mark Out", systemImage: "bracket.right") { model.recordingFirstMarkOut() }
                .keyboardShortcut("o", modifiers: [])
            Button("Undo Last Mark", systemImage: "arrow.uturn.backward") { model.recordingFirstUndoCapture() }
            Spacer()
            Button("Mark Recording Finished", systemImage: "checkmark.circle") {
                _ = model.recordingFirstFinishRecording()
            }
            .buttonStyle(.bordered)
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == floor(rate) ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(2))))×"
    }
}

private struct RecordingFirstCandidateStrip: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel

    var body: some View {
        GroupBox("Captured clips") {
            if model.recordingFirstActiveCandidates.isEmpty {
                Text("No clips yet. Press I and O while the recording plays.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.recordingFirstActiveCandidates) { candidate in
                            Button {
                                model.recordingFirstSelectCandidate(candidate.id)
                                model.recordingFirstStage = .refine
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.label).font(.headline)
                                    Text(candidate.visibleRange.map { durationLabel($0.duration) } ?? "Needs boundaries")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(candidate.reviewState.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption2)
                                        .foregroundStyle(candidate.reviewState == .approved ? .green : .secondary)
                                }
                                .frame(width: 135, alignment: .leading)
                                .padding(10)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func durationLabel(_ duration: MediaTime) -> String {
        String(format: "%.1f seconds", Double(duration.microseconds) / 1_000_000)
    }
}

private struct RecordingFirstRefineView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    @State private var showDiscarded = false

    var body: some View {
        HStack(spacing: 0) {
            refineQueue
                .frame(minWidth: 225, idealWidth: 260, maxWidth: 300)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let candidate = model.recordingFirstSelectedCandidate {
                        Text(candidate.label)
                            .font(.title3.weight(.semibold))
                        if let questionKey = model.recordingFirstAssignedQuestionKey,
                           let question = model.project.activeQuestions.first(where: { $0.questionKey == questionKey }) {
                            Label("Assigned to \(question.displayText)", systemImage: "arrow.right.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        Text("Adjust the answer range, optionally remove an internal pause, then approve it.")
                            .foregroundStyle(.secondary)
                        candidatePlayer
                        boundaryControls(candidate: candidate)
                        internalCutControls
                        HStack {
                            if model.recordingFirstPreviewIsComposed {
                                Button("Return to Source", systemImage: "arrow.uturn.backward") {
                                    model.recordingFirstSelectCandidate(candidate.id)
                                }
                            }
                            Button("Preview Answer", systemImage: "play.fill") { model.recordingFirstPlaySelectedCandidate(withBuffers: false) }
                                .buttonStyle(.borderedProminent)
                            Button("Preview With Buffers", systemImage: "play.circle") { model.recordingFirstPlaySelectedCandidate(withBuffers: true) }
                            Button("Approve & Next", systemImage: "checkmark") {
                                model.recordingFirstApproveSelectedCandidate()
                                selectNextCandidate()
                            }
                            .disabled(model.recordingFirstSelectedCandidate?.reviewState == .discarded)
                            Button("Skip for Now") {
                                model.recordingFirstSkipSelectedCandidate()
                                selectNextCandidate()
                            }
                            Button("Discard", role: .destructive) { model.recordingFirstDiscardSelectedCandidate() }
                        }
                        if let message = model.boundaryRefinementMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        ContentUnavailableView("Select a clip to refine", systemImage: "slider.horizontal.3", description: Text("Choose a candidate from the queue or return to Capture."))
                            .frame(maxWidth: .infinity, minHeight: 500)
                    }
                }
                .padding(20)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Process Next Recording", systemImage: "forward.end") {
                    selectNextRecording()
                }
            }
            ToolbarItem {
                Button("Assign Answers", systemImage: "arrow.right.circle") { model.recordingFirstStage = .assign }
                    .disabled(model.recordingFirstActiveCandidates.isEmpty)
            }
        }
    }

    private var refineQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clips to review")
                .font(.headline)
                .padding(12)
            List(selection: $model.recordingFirstSelectedCandidateID) {
                ForEach(model.recordingFirstActiveCandidates) { candidate in
                    Button {
                        model.recordingFirstSelectCandidate(candidate.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.label)
                            Text(candidate.reviewState.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .foregroundStyle(candidate.reviewState == .approved ? .green : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(candidate.id)
                }
                if !model.recordingFirstDiscardedCandidates.isEmpty {
                    DisclosureGroup("Recently Discarded (\(model.recordingFirstDiscardedCandidates.count))", isExpanded: $showDiscarded) {
                        ForEach(model.recordingFirstDiscardedCandidates) { candidate in
                            HStack {
                                Text(candidate.label).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") { model.recordingFirstRestoreCandidate(candidate.id) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var candidatePlayer: some View {
        if let recording = model.recordingFirstRecording,
           let url = model.document?.recordingURL(for: recording) {
            RecordingFirstPlayerContainer(player: model.player)
                .frame(minHeight: 300)
                .onAppear { model.replacePlayer(with: url) }
                .onChange(of: url) { _, newURL in model.replacePlayer(with: newURL) }
            if let waveform = model.waveform {
                WaveformView(waveform: waveform, timeline: model.recordingFirstTimelineRange, currentTimeUS: model.currentTimeUS) { timeUS in
                    model.seek(to: timeUS)
                }
                .frame(height: 92)
            }
        } else {
            ContentUnavailableView("Source unavailable", systemImage: "exclamationmark.triangle", description: Text("The recording needed by this candidate is missing from the package."))
        }
    }

    private func boundaryControls(candidate: AnswerCandidate) -> some View {
        let visible = candidate.visibleRange
        let duration = max(1, model.recordingFirstRecording?.mediaSignature.durationMicroseconds ?? visible?.end.microseconds ?? 1)
        return GroupBox("Answer boundaries") {
            VStack(alignment: .leading, spacing: 8) {
                Slider(value: Binding(get: { Double(candidate.visibleRange?.start.microseconds ?? 0) }, set: { model.recordingFirstSetBoundary(startUS: Int64($0.rounded())) }), in: 0...Double(duration)) {
                    Text("Start")
                }
                .disabled(model.recordingFirstPreviewIsComposed)
                Slider(value: Binding(get: { Double(candidate.visibleRange?.end.microseconds ?? duration) }, set: { model.recordingFirstSetBoundary(endUS: Int64($0.rounded())) }), in: 0...Double(duration)) {
                    Text("End")
                }
                .disabled(model.recordingFirstPreviewIsComposed)
                Text(boundarySummary(candidate))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var internalCutControls: some View {
        GroupBox("Optional internal cut") {
            HStack {
                Button("Set Cut In") { model.recordingFirstSetCutIn() }
                    .disabled(model.recordingFirstPreviewIsComposed)
                Button("Set Cut Out") { model.recordingFirstSetCutOut() }
                    .disabled(model.recordingFirstPreviewIsComposed)
                Button("Remove Selection", systemImage: "scissors") { model.recordingFirstRemoveSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.recordingFirstPreviewIsComposed)
                Text(cutSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Internal cuts use the exact selected points and a tiny automatic join; no safe buffers are added.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cutSummary: String {
        let start = model.recordingFirstCutStartUS.map { String(format: "%.2f", Double($0) / 1_000_000) } ?? "—"
        let end = model.recordingFirstCutEndUS.map { String(format: "%.2f", Double($0) / 1_000_000) } ?? "—"
        return "Cut \(start)–\(end)s"
    }

    private func boundarySummary(_ candidate: AnswerCandidate) -> String {
        guard let visible = candidate.visibleRange, let safe = candidate.safeRange else { return "Boundaries unavailable" }
        return String(format: "Visible %.2f–%.2fs · safe %.2f–%.2fs · %@", Double(visible.start.microseconds) / 1_000_000, Double(visible.end.microseconds) / 1_000_000, Double(safe.start.microseconds) / 1_000_000, Double(safe.end.microseconds) / 1_000_000, candidate.reviewState.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private func selectNextCandidate() {
        guard let current = model.recordingFirstSelectedCandidateID,
              let index = model.recordingFirstActiveCandidates.firstIndex(where: { $0.id == current }),
              index + 1 < model.recordingFirstActiveCandidates.count else { return }
        model.recordingFirstSelectCandidate(model.recordingFirstActiveCandidates[index + 1].id)
    }

    private func selectNextRecording() {
        guard let current = model.recordingFirstRecording,
              let recordings = model.recordingFirstSession?.recordings,
              let index = recordings.firstIndex(where: { $0.id == current.id }), index + 1 < recordings.count else { return }
        model.recordingFirstSelectRecording(recordings[index + 1].id)
        model.recordingFirstStage = .capture
    }
}

private struct RecordingFirstAssignView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Approved clips")
                    .font(.headline)
                Text("Drag a clip onto a question. A question can have one answer at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(model.recordingFirstActiveCandidates.filter { $0.reviewState == .approved }) { candidate in
                        CandidateAssignRow(candidate: candidate, isAssigned: model.recordingFirstSession?.answers.values.contains(where: { $0.assignedCandidateID == candidate.id }) == true)
                            .onTapGesture { model.recordingFirstSelectCandidate(candidate.id) }
                            .draggable(candidate.id.uuidString)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 285, idealWidth: 335, maxWidth: 390)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Questions")
                    .font(.headline)
                Text("Use the current project question order. Existing answers remain drop targets for Compare and Replace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(model.project.activeQuestions, id: \.id) { question in
                        QuestionAssignmentRow(model: model, question: question)
                    }
                }
            }
            .padding(18)
        }
        .toolbar {
            ToolbarItem {
                Button("Refine Unreviewed", systemImage: "slider.horizontal.3") {
                    model.recordingFirstStage = .refine
                    if let candidate = model.recordingFirstActiveCandidates.first(where: { $0.reviewState != .approved }) {
                        model.recordingFirstSelectCandidate(candidate.id)
                    }
                }
            }
            ToolbarItem {
                Button("Finish", systemImage: "checkmark.seal") { model.recordingFirstStage = .finish }
            }
        }
    }
}

private struct CandidateAssignRow: View {
    let candidate: AnswerCandidate
    let isAssigned: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.label)
                Text(candidate.visibleRange.map { String(format: "%.1f seconds", Double($0.duration.microseconds) / 1_000_000) } ?? "Needs boundaries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isAssigned {
                    Text("Assigned")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        } icon: {
            Image(systemName: isAssigned ? "checkmark.circle.fill" : "circle.dashed")
        }
    }
}

private struct QuestionAssignmentRow: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    let question: InterviewQuestion

    private var assigned: AnswerCandidate? {
        guard let candidateID = model.recordingFirstSession?.answers[question.questionKey]?.assignedCandidateID else { return nil }
        return model.recordingFirstSession?.candidates.first(where: { $0.id == candidateID })
    }

    var body: some View {
        HStack {
            Image(systemName: assigned == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(assigned == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(question.displayText).lineLimit(2)
                Text(assigned?.label ?? "Unanswered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let assigned {
                Button("Edit") { model.recordingFirstEditAssignedCandidate(assigned.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Unassign") { model.recordingFirstUnassign(questionKey: question.questionKey) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
        .dropDestination(for: String.self) { ids, _ in
            guard let idString = ids.first, let id = UUID(uuidString: idString) else { return false }
            model.recordingFirstAssignCandidate(id, to: question.questionKey)
            return true
        }
    }
}

private struct RecordingFirstFinishView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    @Binding var showLockWarningAlert: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Finish \(model.selectedSession?.ageLabel ?? "Age Entry")")
                        .font(.title.weight(.semibold))
                    Text("Review readiness, then lock this age entry for publication. Locking does not render the final movie.")
                        .foregroundStyle(.secondary)
                }
                readinessCard
                questionCoverage
                sourceCoverage
                HStack {
                    if model.selectedSession?.lifecycle == .locked {
                        Button("Unlock Age Entry", systemImage: "lock.open") { model.recordingFirstUnlock() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Lock Age Entry", systemImage: "lock") {
                            if model.recordingFirstReadiness.warnings.isEmpty {
                                model.recordingFirstLock()
                            } else {
                                showLockWarningAlert = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.recordingFirstReadiness.blockers.isEmpty)
                    }
                    Button("Render Final Movie…", systemImage: "film") { model.renderFinalMovie() }
                        .disabled(model.sessions.filter(\.isActive).contains(where: { $0.lifecycle != .locked }) || model.isRenderingFinalMovie)
                }
                if model.selectedSession?.lifecycle == .locked {
                    Label("Locked for publication. The final movie still uses the protected renderer when you choose Render Final Movie.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(24)
        }
    }

    private var readinessCard: some View {
        let report = model.recordingFirstReadiness
        return GroupBox("Readiness") {
            VStack(alignment: .leading, spacing: 8) {
                if report.blockers.isEmpty {
                    Label("No hard blockers", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Cannot lock yet", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    ForEach(report.blockers, id: \.self) { Text($0).font(.caption) }
                }
                if !report.warnings.isEmpty {
                    Divider()
                    Label("Can lock with warnings", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ForEach(report.warnings.prefix(8), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if report.warnings.count > 8 { Text("…and \(report.warnings.count - 8) more.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var questionCoverage: some View {
        GroupBox("Question coverage") {
            let answered = model.selectedSession?.answers.values.filter { $0.assignedCandidateID != nil }.count ?? 0
            let total = model.project.activeQuestions.count
            Text("\(answered) of \(total) questions have assigned answers. Unanswered questions remain omitted from the final movie.")
                .foregroundStyle(.secondary)
        }
    }

    private var sourceCoverage: some View {
        GroupBox("Recording progress") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.selectedSession?.recordings ?? []) { recording in
                    HStack {
                        Text("Recording \(recording.recordingNumber)")
                        Text(recording.originalFilename).foregroundStyle(.secondary)
                        Spacer()
                        Text(recording.recordingState == .finished ? "Finished" : "In Progress")
                            .foregroundStyle(recording.recordingState == .finished ? .green : .orange)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct RecordingFirstPlayerContainer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct CandidateComparisonView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    let comparison: CandidateComparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("This question already has an answer")
                .font(.title2.weight(.semibold))
            Text("Compare the two clips, then keep the current answer or explicitly replace it. Nothing starts playing automatically.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                comparisonCard(title: "Current", candidate: comparison.current)
                comparisonCard(title: "New Candidate", candidate: comparison.proposed)
            }
            HStack {
                Spacer()
                Button("Keep Current", role: .cancel) { dismiss() }
                Button("Replace Current", action: {
                    model.recordingFirstReplaceComparedCandidate()
                    dismiss()
                })
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 720)
    }

    private func comparisonCard(title: String, candidate: AnswerCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(candidate.label)
            Text(candidate.visibleRange.map { String(format: "%.2f seconds", Double($0.duration.microseconds) / 1_000_000) } ?? "Unknown duration")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Play") {
                model.recordingFirstSelectCandidate(candidate.id)
                model.recordingFirstPlaySelectedCandidate(withBuffers: false)
            }
            .buttonStyle(.bordered)
            if let transcript = candidate.transcript?.text, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .lineLimit(5)
                    .textSelection(.enabled)
            } else {
                Text("No transcript available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ManageQuestionsView: View {
    private struct PendingUpdate: Identifiable {
        let id = UUID()
        let questionKey: String
        let text: String
    }

    @ObservedObject var model: InterviewStudioWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var newQuestion = ""
    @State private var drafts: [String: String] = [:]
    @State private var pendingUpdate: PendingUpdate?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage Questions")
                        .font(.title2.weight(.semibold))
                    Text("This canonical list controls every age entry and the final movie order.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            List {
                ForEach(Array(model.project.activeQuestions.enumerated()), id: \.element.id) { index, question in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        TextField("Question", text: Binding(get: { drafts[question.questionKey] ?? question.displayText }, set: { drafts[question.questionKey] = $0 }))
                            .onSubmit {
                                if let text = drafts[question.questionKey], text.trimmingCharacters(in: .whitespacesAndNewlines) != question.displayText {
                                    pendingUpdate = PendingUpdate(questionKey: question.questionKey, text: text)
                                }
                            }
                        Button("Up", systemImage: "arrow.up") { model.recordingFirstMoveQuestion(question.questionKey, by: -1) }
                            .labelStyle(.iconOnly)
                            .disabled(index == 0)
                        Button("Down", systemImage: "arrow.down") { model.recordingFirstMoveQuestion(question.questionKey, by: 1) }
                            .labelStyle(.iconOnly)
                            .disabled(index == model.project.activeQuestions.count - 1)
                    }
                }
            }
            HStack {
                TextField("Add a new canonical question", text: $newQuestion)
                    .onSubmit(addQuestion)
                Button("Add Question", systemImage: "plus") { addQuestion() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 760, height: 560)
        .alert("Update this question everywhere?", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } })) {
            Button("Update Everywhere") {
                if let pendingUpdate {
                    model.recordingFirstUpdateQuestion(pendingUpdate.questionKey, text: pendingUpdate.text)
                }
                pendingUpdate = nil
            }
            Button("Keep Editing", role: .cancel) { pendingUpdate = nil }
        } message: {
            Text("The canonical wording is shared by every age entry and the final movie. Existing assignments keep their stable question key.")
        }
    }

    private func addQuestion() {
        model.recordingFirstAddQuestion(newQuestion)
        newQuestion = ""
    }
}

private struct ArchivedAgesView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Archived Ages")
                .font(.title2.weight(.semibold))
            if model.sessions.filter({ $0.isArchived }).isEmpty {
                ContentUnavailableView("No archived ages", systemImage: "archivebox", description: Text("Archived entries will appear here if you ever use that optional cleanup action."))
            } else {
                List(model.sessions.filter(\.isArchived)) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.ageLabel)
                            Text("\(session.recordings.count) recordings · \(session.candidates.count) clips")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { model.recordingFirstRestoreAge(session.id) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }
}

private struct ChangeAgeView: View {
    let initialValue: Double
    let onChange: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ageText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Age")
                .font(.title2.weight(.semibold))
            Text("The age controls publication order. All recordings, clips, and assignments remain attached to this entry.")
                .foregroundStyle(.secondary)
            TextField("Age", text: $ageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Change Age", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(Double(ageText) == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .task { ageText = initialValue.formatted(.number.precision(.fractionLength(0...2))) }
    }

    private func commit() {
        guard let value = Double(ageText), value.isFinite, value >= 0 else { return }
        onChange(value)
        dismiss()
    }
}
