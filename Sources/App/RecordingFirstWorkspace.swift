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
        guard document?.isPackageReadOnly != true else {
            errorMessage = "This project is read-only. Open a writable copy before editing assignments."
            return false
        }
        guard session.lifecycle == .open else {
            errorMessage = "Unlock the age entry before editing it."
            return false
        }
        return true
    }

    var recordingFirstCanEdit: Bool {
        guard let session = recordingFirstSession else { return false }
        return session.isActive && session.compatibility.isWritable && session.lifecycle == .open && document?.isPackageReadOnly != true
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
            safeLeadingStartUS: candidate.refinedBoundaries == nil ? nil : safe?.start.microseconds,
            safeTrailingEndUS: candidate.refinedBoundaries == nil ? nil : safe?.end.microseconds
        )
    }

    var recordingFirstInternalCutRanges: [ClosedRange<Int64>] {
        guard let candidate = recordingFirstSelectedCandidate,
              let outer = candidate.visibleRange else { return [] }
        return internalCuts(for: candidate, outer: outer).map { $0.start.microseconds ... $0.end.microseconds }
    }

    var recordingFirstCutSelectionRange: ClosedRange<Int64>? {
        guard let start = recordingFirstCutStartUS,
              let end = recordingFirstCutEndUS,
              end >= start else { return nil }
        return start ... end
    }

    func recordingFirstSelectRecording(_ recordingID: UUID) {
        selectedRecordingID = recordingID
        recordingFirstSelectedCandidateID = nil
        recordingFirstPreviewSourceRecordingID = nil
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
        recordingFirstPreviewSourceRecordingID = nil
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
        recordingFirstPreviewSourceRecordingID = nil
        player?.pause()
        recordingFirstCutStartUS = nil
        recordingFirstCutEndUS = nil
        if let url = document?.recordingURL(for: recordingFirstSession?.recordings.first(where: { $0.id == candidate.sourceRecordingID }) ?? SourceRecording.placeholder(for: candidate)) {
            replacePlayer(with: url)
            recordingFirstPreviewSourceRecordingID = candidate.sourceRecordingID
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
        candidate.refinedBoundaries = RecordingFirstWorkflow.reviewBoundaries(visible: segment, sourceDurationUS: durationUS)
        sessions[sessionIndex].candidates.append(candidate)
        sessions[sessionIndex].revision += 1
        recordingFirstSelectedCandidateID = candidate.id
        recordingFirstPreviewSourceRecordingID = recordingID
        flushToDocument()
    }

    func recordingFirstPlaySelectedCandidate(withBuffers: Bool) {
        guard let candidate = recordingFirstSelectedCandidate else { return }
        guard recordingFirstPreviewSourceRecordingID == candidate.sourceRecordingID, player != nil else {
            errorMessage = "This clip's source is not available for preview. Select it again or recover the recording."
            return
        }
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
        let duration = recordingFirstRecording?.mediaSignature.durationMicroseconds ?? max(oldVisible.end.microseconds, endUS ?? oldVisible.end.microseconds)
        let start = min(duration, max(0, startUS ?? oldVisible.start.microseconds))
        let end = min(duration, max(start, endUS ?? oldVisible.end.microseconds))
        guard end > start else {
            errorMessage = "The answer end must be later than its start."
            return
        }
        var updated = candidate
        let visible = CandidateSegment(start: .microseconds(start), end: .microseconds(end))
        let boundaries = RecordingFirstWorkflow.reviewBoundaries(
            visible: visible,
            sourceDurationUS: duration,
            leadingStartUS: startUS == nil ? candidate.refinedBoundaries?.safeLeadingStart.microseconds : nil,
            trailingEndUS: endUS == nil ? candidate.refinedBoundaries?.safeTrailingEnd.microseconds : nil,
            manualOverride: true
        )
        guard let boundaries else { return }
        updated.refinedBoundaries = boundaries
        let existingCuts = internalCuts(for: candidate, outer: oldVisible)
        updated.retainedSegments = (try? RecordingFirstWorkflow.retainedSegments(for: CandidateSegment(start: .microseconds(start), end: .microseconds(end)), removing: existingCuts)) ?? [CandidateSegment(start: .microseconds(start), end: .microseconds(end))]
        if updated.reviewState == .approved { updated.reviewState = .needsReview }
        updated.updatedAt = Date()
        sessions[sessionIndex].candidates[candidateIndex] = updated
        sessions[sessionIndex].revision += 1
        flushToDocument()
    }

    func recordingFirstSetLeadingHandle(_ valueUS: Int64) {
        updateRecordingFirstHandle(leadingStartUS: valueUS, trailingEndUS: nil)
    }

    func recordingFirstSetTrailingHandle(_ valueUS: Int64) {
        updateRecordingFirstHandle(leadingStartUS: nil, trailingEndUS: valueUS)
    }

    func recordingFirstResetHandlesToDefaults() {
        updateRecordingFirstHandle(leadingStartUS: nil, trailingEndUS: nil, resetToDefaults: true)
    }

    func recordingFirstResetToInitialRefinement() {
        guard requireRecordingFirstEditingSession(),
              let candidateID = recordingFirstSelectedCandidateID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }),
              let candidate = sessions[sessionIndex].candidates[safe: candidateIndex],
              let recording = sessions[sessionIndex].recordings.first(where: { $0.id == candidate.sourceRecordingID }) else { return }

        let initialStartUS = candidate.rawMarkers.answerStart?.microseconds ?? candidate.visibleRange?.start.microseconds
        let initialEndUS = candidate.rawMarkers.answerEnd?.microseconds ?? candidate.visibleRange?.end.microseconds
        guard let initialStartUS, let initialEndUS, initialEndUS > initialStartUS else {
            errorMessage = "The original In/Out marks are not available for this clip."
            return
        }
        let duration = recording.mediaSignature.durationMicroseconds ?? initialEndUS
        let start = min(duration, max(0, initialStartUS))
        let end = min(duration, max(start, initialEndUS))
        guard end > start,
              let boundaries = RecordingFirstWorkflow.reviewBoundaries(
                visible: CandidateSegment(start: .microseconds(start), end: .microseconds(end)),
                sourceDurationUS: duration
              ) else {
            errorMessage = "The original In/Out marks are outside the recording."
            return
        }

        var updated = candidate
        updated.refinedBoundaries = boundaries
        updated.retainedSegments = [CandidateSegment(start: .microseconds(start), end: .microseconds(end))]
        if updated.reviewState == .approved { updated.reviewState = .needsReview }
        updated.updatedAt = Date()
        sessions[sessionIndex].candidates[candidateIndex] = updated
        sessions[sessionIndex].revision += 1
        progressMessage = "Restored the original In/Out marks and 2-second transition handles."
        flushToDocument()
    }

    private func updateRecordingFirstHandle(leadingStartUS: Int64?, trailingEndUS: Int64?, resetToDefaults: Bool = false) {
        guard requireRecordingFirstEditingSession(),
              let candidateID = recordingFirstSelectedCandidateID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }),
              let candidateIndex = sessions[sessionIndex].candidates.firstIndex(where: { $0.id == candidateID }),
              let candidate = sessions[sessionIndex].candidates[safe: candidateIndex],
              let visible = candidate.visibleRange,
              let recording = sessions[sessionIndex].recordings.first(where: { $0.id == candidate.sourceRecordingID }) else { return }
        let duration = recording.mediaSignature.durationMicroseconds ?? visible.end.microseconds
        let boundaries = RecordingFirstWorkflow.reviewBoundaries(
            visible: visible,
            sourceDurationUS: duration,
            leadingStartUS: resetToDefaults ? nil : (leadingStartUS ?? candidate.refinedBoundaries?.safeLeadingStart.microseconds),
            trailingEndUS: resetToDefaults ? nil : (trailingEndUS ?? candidate.refinedBoundaries?.safeTrailingEnd.microseconds),
            manualOverride: !resetToDefaults
        )
        guard let boundaries else { return }
        var updated = candidate
        updated.refinedBoundaries = boundaries
        if updated.reviewState == .approved { updated.reviewState = .needsReview }
        updated.updatedAt = Date()
        sessions[sessionIndex].candidates[candidateIndex] = updated
        sessions[sessionIndex].revision += 1
        progressMessage = resetToDefaults ? "Transition handles reset to 2 seconds before and after the In/Out marks." : "Transition handle adjusted."
        flushToDocument()
    }

    func recordingFirstSetCutIn() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let timeUS = recordingFirstRefinementTimestamp() else { return }
        recordingFirstCutStartUS = timeUS
        if let endUS = recordingFirstCutEndUS, endUS <= timeUS {
            recordingFirstCutEndUS = nil
        }
        progressMessage = "Cut In set at " + formatMicroseconds(timeUS) + ". Set Cut Out later in the answer."
    }

    func recordingFirstSetCutOut() {
        guard requireRecordingFirstEditingSession() else { return }
        guard let timeUS = recordingFirstRefinementTimestamp() else { return }
        guard let startUS = recordingFirstCutStartUS else {
            errorMessage = "Set Cut In first, then move the playhead and set Cut Out."
            return
        }
        guard timeUS > startUS else {
            errorMessage = "Cut Out must be later than Cut In."
            return
        }
        recordingFirstCutEndUS = timeUS
        progressMessage = "Cut Out set at " + formatMicroseconds(timeUS) + ". Review the highlighted range, then remove it."
    }

    func recordingFirstClearCutSelection() {
        guard requireRecordingFirstEditingSession() else { return }
        recordingFirstCutStartUS = nil
        recordingFirstCutEndUS = nil
        progressMessage = "Pending cut selection cleared."
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
        guard cut.start > outer.start || cut.end < outer.end else {
            errorMessage = "An internal cut must leave some answer content."
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
        let cutLabel = String(format: "%.3f–%.3fs", Double(start) / 1_000_000, Double(end) / 1_000_000)
        progressMessage = "Removed " + cutLabel + ". Preview Answer will skip it; red on the waveform marks the removed range."
        flushToDocument()
    }

    private func recordingFirstRefinementTimestamp() -> Int64? {
        guard recordingFirstRecording != nil else {
            errorMessage = "Choose a recording before marking an internal cut."
            return nil
        }
        let durationUS = recordingFirstRecording?.mediaSignature.durationMicroseconds
        let timeUS = max(0, currentTimeUS)
        return durationUS.map { min(timeUS, $0) } ?? timeUS
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
            recordingFirstSelectCandidate(candidateID)
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
            recordingFirstSelectCandidate(comparison.proposed.id)
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

private struct PreciseSecondsControl: View {
    let label: String
    @Binding var seconds: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 3) {
            TextField("0.000", value: $seconds, format: .number.precision(.fractionLength(3)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 74)
                .accessibilityLabel("\(label) seconds")
                .accessibilityHint("Type a value to the millisecond.")
            Text("s")
                .foregroundStyle(.secondary)
            Stepper("Adjust \(label)", value: $seconds, in: range, step: 0.01)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Adjust \(label) in ten-millisecond steps")
        }
        .fixedSize()
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
                        Text("Adjust the In/Out answer range and transition handles, optionally remove an internal pause, then approve it.")
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
                            .disabled(!model.recordingFirstCanEdit || model.recordingFirstSelectedCandidate?.reviewState == .discarded)
                            Button("Skip for Now") {
                                model.recordingFirstSkipSelectedCandidate()
                                selectNextCandidate()
                            }
                            .disabled(!model.recordingFirstCanEdit)
                            Button("Discard", role: .destructive) { model.recordingFirstDiscardSelectedCandidate() }
                                .disabled(!model.recordingFirstCanEdit)
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
        .task(id: model.recordingFirstRecording?.id) {
            await model.prepareMediaAnalysis()
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
            if model.isLoadingWaveform {
                ProgressView("Building waveform…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 126)
            } else if let waveform = model.waveform {
                let timeline = model.recordingFirstTimelineRange
                WaveformView(
                    waveform: waveform,
                    timeline: timeline,
                    currentTimeUS: model.currentTimeUS,
                    displayRangeUS: timeline?.reviewViewportUS,
                    selectionRangeUS: model.recordingFirstCutSelectionRange,
                    cutRangesUS: model.recordingFirstInternalCutRanges,
                    onHandleChange: { handle, timeUS in
                        switch handle {
                        case .visibleLeading: model.recordingFirstSetBoundary(startUS: timeUS)
                        case .visibleTrailing: model.recordingFirstSetBoundary(endUS: timeUS)
                        case .leading: model.recordingFirstSetLeadingHandle(timeUS)
                        case .trailing: model.recordingFirstSetTrailingHandle(timeUS)
                        }
                    },
                    onSeek: { timeUS in model.seek(to: timeUS) }
                )
                .disabled(!model.recordingFirstCanEdit || model.recordingFirstPreviewIsComposed)
                .frame(height: 126)
                if let timeline {
                    HStack {
                        Text(formatSeconds(timeline.reviewViewportUS.lowerBound))
                        Spacer()
                        Text("Review window · up to 3s context")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatSeconds(timeline.reviewViewportUS.upperBound))
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
            } else if let waveformMessage = model.waveformMessage {
                Label(waveformMessage, systemImage: "waveform.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 126)
            } else {
                Label("Waveform unavailable", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 126)
            }
        } else {
            ContentUnavailableView("Source unavailable", systemImage: "exclamationmark.triangle", description: Text("The recording needed by this candidate is missing from the package."))
        }
    }

    private func boundaryControls(candidate: AnswerCandidate) -> some View {
        let visible = candidate.visibleRange
        let durationUS = max(1, model.recordingFirstRecording?.mediaSignature.durationMicroseconds ?? visible?.end.microseconds ?? 1)
        let durationSeconds = max(0.001, Double(durationUS) / 1_000_000)
        let safe = candidate.refinedBoundaries
        let visibleStartUS = visible?.start.microseconds ?? 0
        let visibleEndUS = visible?.end.microseconds ?? durationUS
        let defaultLeadingUS = max(0, visibleStartUS - RecordingFirstWorkflow.defaultHandleDurationUS)
        let defaultTrailingUS = min(durationUS, visibleEndUS + RecordingFirstWorkflow.defaultHandleDurationUS)
        let leadingStartUS = safe?.safeLeadingStart.microseconds ?? defaultLeadingUS
        let trailingEndUS = safe?.safeTrailingEnd.microseconds ?? defaultTrailingUS
        let leadingMaximumSeconds = max(0.001, min(Double(RecordingFirstWorkflow.maximumReviewHandleDurationUS) / 1_000_000, Double(visibleStartUS) / 1_000_000))
        let trailingMaximumSeconds = max(0.001, min(Double(RecordingFirstWorkflow.maximumReviewHandleDurationUS) / 1_000_000, Double(max(0, durationUS - visibleEndUS)) / 1_000_000))
        let startSeconds = Binding<Double>(
            get: { Double(visibleStartUS) / 1_000_000 },
            set: { model.recordingFirstSetBoundary(startUS: microseconds(from: $0)) }
        )
        let endSeconds = Binding<Double>(
            get: { Double(visibleEndUS) / 1_000_000 },
            set: { model.recordingFirstSetBoundary(endUS: microseconds(from: $0)) }
        )
        let leadingSeconds = Binding<Double>(
            get: { Double(max(0, visibleStartUS - leadingStartUS)) / 1_000_000 },
            set: { model.recordingFirstSetLeadingHandle(visibleStartUS - microseconds(from: $0)) }
        )
        let trailingSeconds = Binding<Double>(
            get: { Double(max(0, trailingEndUS - visibleEndUS)) / 1_000_000 },
            set: { model.recordingFirstSetTrailingHandle(visibleEndUS + microseconds(from: $0)) }
        )
        let controlsDisabled = !model.recordingFirstCanEdit || model.recordingFirstPreviewIsComposed
        return GroupBox("Answer boundaries and transition handles") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Slider(value: startSeconds, in: 0 ... durationSeconds) {
                        Text("Start")
                    }
                    PreciseSecondsControl(label: "Start", seconds: startSeconds, range: 0 ... durationSeconds)
                }
                .disabled(controlsDisabled)
                HStack(spacing: 8) {
                    Slider(value: endSeconds, in: 0 ... durationSeconds) {
                        Text("End")
                    }
                    PreciseSecondsControl(label: "End", seconds: endSeconds, range: 0 ... durationSeconds)
                }
                .disabled(controlsDisabled)
                Divider()
                Text("Transition handles")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Slider(value: leadingSeconds, in: 0 ... leadingMaximumSeconds) {
                        Text("Before I/O")
                    }
                    PreciseSecondsControl(label: "Before I/O", seconds: leadingSeconds, range: 0 ... leadingMaximumSeconds)
                }
                .disabled(controlsDisabled)
                HStack(spacing: 8) {
                    Slider(value: trailingSeconds, in: 0 ... trailingMaximumSeconds) {
                        Text("After I/O")
                    }
                    PreciseSecondsControl(label: "After I/O", seconds: trailingSeconds, range: 0 ... trailingMaximumSeconds)
                }
                .disabled(controlsDisabled)
                HStack {
                    Text("Type to the millisecond; steppers change by 0.010s. Defaults are 2.000s, capped at 3.000s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Handles") { model.recordingFirstResetHandlesToDefaults() }
                        .controlSize(.small)
                        .disabled(controlsDisabled)
                    Button("Reset to Initial", systemImage: "arrow.counterclockwise") {
                        model.recordingFirstResetToInitialRefinement()
                    }
                    .controlSize(.small)
                    .help("Restore the original In/Out marks, remove internal cuts, and reset handles to 2 seconds.")
                    .disabled(controlsDisabled)
                }
                Text(boundarySummary(candidate))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func microseconds(from seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000_000).rounded())
    }

    private var internalCutControls: some View {
        let durationUS = max(1, model.recordingFirstRecording?.mediaSignature.durationMicroseconds ?? model.recordingFirstSelectedCandidate?.visibleRange?.end.microseconds ?? 1)
        let durationSeconds = Double(durationUS) / 1_000_000
        let controlsDisabled = !model.recordingFirstCanEdit || model.recordingFirstPreviewIsComposed
        let hasPendingMarks = model.recordingFirstCutStartUS != nil || model.recordingFirstCutEndUS != nil
        let canRemoveSelection = model.recordingFirstCutStartUS.map { start in
            model.recordingFirstCutEndUS.map { $0 > start } ?? false
        } ?? false
        let playheadSeconds = Binding<Double>(
            get: { Double(min(max(model.currentTimeUS, 0), durationUS)) / 1_000_000 },
            set: { model.seek(to: min(max(microseconds(from: $0), 0), durationUS)) }
        )

        return GroupBox("Remove an internal section") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Remove a pause or unwanted moment inside this answer. Move the playhead, set both marks, review the purple selection, then remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Label("Playhead", systemImage: "location.fill")
                    PreciseSecondsControl(label: "Playhead", seconds: playheadSeconds, range: 0 ... durationSeconds)
                    Spacer()
                    Button("Set Cut In Here", systemImage: "arrow.down.to.line") { model.recordingFirstSetCutIn() }
                    Button("Set Cut Out Here", systemImage: "arrow.up.to.line") { model.recordingFirstSetCutOut() }
                }
                .disabled(controlsDisabled)

                HStack(spacing: 14) {
                    if model.recordingFirstCutStartUS != nil {
                        Text("Cut In")
                            .font(.caption.weight(.semibold))
                        PreciseSecondsControl(
                            label: "Cut In",
                            seconds: cutPointBinding(isStart: true, durationUS: durationUS),
                            range: 0 ... durationSeconds
                        )
                    } else {
                        Text("Cut In —")
                            .foregroundStyle(.secondary)
                    }
                    if model.recordingFirstCutEndUS != nil {
                        Text("Cut Out")
                            .font(.caption.weight(.semibold))
                        PreciseSecondsControl(
                            label: "Cut Out",
                            seconds: cutPointBinding(isStart: false, durationUS: durationUS),
                            range: 0 ... durationSeconds
                        )
                    } else {
                        Text("Cut Out —")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .disabled(controlsDisabled)

                HStack(spacing: 8) {
                    if let selection = model.recordingFirstCutSelectionRange {
                        Label(
                            "Pending removal " + formatSeconds(selection.lowerBound) + "–" + formatSeconds(selection.upperBound),
                            systemImage: "scissors"
                        )
                        .foregroundStyle(.purple)
                    } else {
                        Label("Set Cut In, then Set Cut Out to create a removable range.", systemImage: "scissors")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasPendingMarks {
                        Button("Clear Selection") { model.recordingFirstClearCutSelection() }
                            .controlSize(.small)
                    }
                    Button("Remove Selected Range", systemImage: "scissors") { model.recordingFirstRemoveSelection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controlsDisabled || !canRemoveSelection)
                }

                Divider()

                if model.recordingFirstInternalCutRanges.isEmpty {
                    Label("No internal cuts saved for this answer.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    let cutCount = model.recordingFirstInternalCutRanges.count
                    Label(
                        String(cutCount) + " internal cut" + (cutCount == 1 ? "" : "s") + " saved; red ranges on the waveform are excluded.",
                        systemImage: "minus.circle.fill"
                    )
                    .foregroundStyle(.red)
                }
                Text("Preview Answer skips red ranges. Preview With Buffers adds only the outer transition handles; internal cuts receive no extra buffer. Reset to Initial clears all internal cuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cutPointBinding(isStart: Bool, durationUS: Int64) -> Binding<Double> {
        Binding(
            get: {
                let value = isStart ? model.recordingFirstCutStartUS : model.recordingFirstCutEndUS
                return Double(value ?? model.currentTimeUS) / 1_000_000
            },
            set: { seconds in
                let value = min(max(microseconds(from: seconds), 0), durationUS)
                if isStart {
                    model.recordingFirstCutStartUS = value
                } else {
                    model.recordingFirstCutEndUS = value
                }
            }
        )
    }

    private func boundarySummary(_ candidate: AnswerCandidate) -> String {
        guard let visible = candidate.visibleRange, let safe = candidate.safeRange else { return "Boundaries unavailable" }
        return String(format: "I/O %.3f–%.3fs · handles −%.3f/+%.3fs · %@", Double(visible.start.microseconds) / 1_000_000, Double(visible.end.microseconds) / 1_000_000, Double(visible.start.microseconds - safe.start.microseconds) / 1_000_000, Double(safe.end.microseconds - visible.end.microseconds) / 1_000_000, candidate.reviewState.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
    }

    private func formatSeconds(_ microseconds: Int64) -> String {
        String(format: "%.3fs", Double(microseconds) / 1_000_000)
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
                List(selection: $model.recordingFirstSelectedCandidateID) {
                    ForEach(model.recordingFirstActiveCandidates.filter { $0.reviewState == .approved }) { candidate in
                        if model.recordingFirstCanEdit {
                            CandidateAssignRow(candidate: candidate, isAssigned: model.recordingFirstSession?.answers.values.contains(where: { $0.assignedCandidateID == candidate.id }) == true)
                                .tag(candidate.id)
                                .draggable(candidate.id.uuidString)
                        } else {
                            CandidateAssignRow(candidate: candidate, isAssigned: model.recordingFirstSession?.answers.values.contains(where: { $0.assignedCandidateID == candidate.id }) == true)
                                .tag(candidate.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.recordingFirstSelectedCandidateID) { _, candidateID in
                    guard let candidateID else { return }
                    model.recordingFirstSelectCandidate(candidateID)
                }
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
            Divider()
            RecordingFirstAssignPreview(model: model)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)
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

private struct RecordingFirstAssignPreview: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip preview")
                .font(.headline)

            if let candidate = model.recordingFirstSelectedCandidate {
                Text(candidate.label)
                    .font(.title3.weight(.semibold))
                Text("Play the selected answer to hear its audio before assigning it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let player = model.player,
                   model.recordingFirstPreviewSourceRecordingID == candidate.sourceRecordingID {
                    RecordingFirstPlayerContainer(player: player)
                        .frame(minHeight: 180, idealHeight: 220, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ContentUnavailableView(
                        "Clip is loading",
                        systemImage: "waveform",
                        description: Text("Select the clip again when its source is ready.")
                    )
                    .frame(minHeight: 180)
                }

                HStack {
                    Button("Play Selected Clip", systemImage: "play.fill") {
                        model.recordingFirstPlaySelectedCandidate(withBuffers: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.player == nil || model.recordingFirstPreviewSourceRecordingID != candidate.sourceRecordingID)

                    Button("Pause", systemImage: "pause.fill") {
                        model.player?.pause()
                    }
                    .disabled(model.player == nil || model.recordingFirstPreviewSourceRecordingID != candidate.sourceRecordingID)
                }

                Text("Playback uses the reviewed clip range and skips any saved internal cuts. It does not change the package or source recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Select an approved clip",
                    systemImage: "play.rectangle",
                    description: Text("Choose a clip on the left to inspect and hear it before assigning it to a question.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            }

            Spacer(minLength: 0)
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
                    .disabled(!model.recordingFirstCanEdit)
                Button("Unassign") { model.recordingFirstUnassign(questionKey: question.questionKey) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.recordingFirstCanEdit)
            }
        }
        .padding(.vertical, 5)
        .dropDestination(for: String.self) { ids, _ in
            guard model.recordingFirstCanEdit else { return false }
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
