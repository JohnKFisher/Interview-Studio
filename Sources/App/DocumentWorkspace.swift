import AVFoundation
import AVKit
import AppKit
import Core
import SwiftUI

private final class PlayerObservationLifetime {
    var player: AVPlayer?
    var periodic: Any?
    var boundary: Any?

    func invalidate() {
        if let periodic, let player { player.removeTimeObserver(periodic) }
        if let boundary, let player { player.removeTimeObserver(boundary) }
        periodic = nil
        boundary = nil
        player = nil
    }

    deinit { invalidate() }
}

@MainActor
final class InterviewStudioWorkspaceModel: ObservableObject {
    @Published var project: InterviewStudioProject
    @Published var sessions: [InterviewSession]
    @Published var selectedSessionID: UUID?
    @Published var selectedQuestionKey: String?
    @Published var selectedRecordingID: UUID?
    @Published var currentTimeUS: Int64 = 0
    @Published var player: AVPlayer?
    @Published var errorMessage: String?
    @Published var progressMessage: String?
    @Published var isBusy = false
    @Published var renderPlan: RenderPlan?
    @Published var waveform: WaveformData?
    @Published var isLoadingWaveform = false
    @Published var waveformMessage: String?
    @Published var isTranscribing = false
    @Published var isBulkTranscribing = false
    @Published var transcriptionMessage: String?
    @Published var isAddingYear = false

    weak var document: InterviewStudioDocument?
    private var transcriptionTask: Task<Void, Never>?
    private var bulkTranscriptionTask: Task<Void, Never>?
    private let speechTranscriber = SpeechTranscriptionService()
    let newInterviewYearDraft = NewInterviewYearDraft()
    private let playerObservation = PlayerObservationLifetime()

    init(document: InterviewStudioDocument) {
        self.document = document
        self.project = document.project
        self.sessions = document.sessions
        self.selectedSessionID = document.sessions.first?.id
        self.selectedQuestionKey = document.project.activeQuestions.first?.questionKey
        self.selectedRecordingID = document.sessions.first?.recordings.first?.id
    }

    var selectedSession: InterviewSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selectedQuestion: InterviewQuestion? {
        project.activeQuestions.first { $0.questionKey == selectedQuestionKey }
    }

    var selectedAnswer: InterviewAnswer? {
        guard let selectedSession, let selectedQuestionKey else { return nil }
        return selectedSession.answers[selectedQuestionKey]
    }

    var selectedAnswerPart: AnswerPart? {
        selectedAnswer?.selectedTake?.parts.first { $0.sourceRecordingID == selectedRecording?.id }
            ?? selectedAnswer?.selectedTake?.parts.first
    }

    var selectedTimelineRange: SelectedTimelineRange? {
        guard let recording = selectedRecording else { return nil }
        let duration = waveform?.durationUS ?? recording.mediaSignature.durationMicroseconds ?? 0
        guard duration > 0 else { return nil }
        let part = selectedAnswerPart
        let boundaries = part?.refinedBoundaries
        let rawStart = part?.rawMarkers.answerStart?.microseconds
        let rawEnd = part?.rawMarkers.answerEnd?.microseconds
        let visibleStart = boundaries?.visibleStart.microseconds ?? rawStart ?? 0
        let visibleEnd = boundaries?.visibleEnd.microseconds ?? rawEnd ?? duration
        return SelectedTimelineRange(
            durationUS: duration,
            visibleStartUS: min(max(visibleStart, 0), duration),
            visibleEndUS: min(max(visibleEnd, visibleStart), duration),
            safeLeadingStartUS: boundaries?.safeLeadingStart.microseconds,
            safeTrailingEndUS: boundaries?.safeTrailingEnd.microseconds
        )
    }

    var selectedRecording: SourceRecording? {
        guard let selectedSession else { return nil }
        if let answerRecordingID = selectedAnswer?.selectedTake?.parts.first?.sourceRecordingID,
           let answerRecording = selectedSession.recordings.first(where: { $0.id == answerRecordingID }) {
            return answerRecording
        }
        return selectedSession.recordings.first { $0.id == selectedRecordingID } ?? selectedSession.recordings.first
    }

    var selectedRecordingURL: URL? {
        guard let store = document?.packageStore, let recording = selectedRecording else { return nil }
        return try? store.resolve(relativePath: recording.packageRelativePath)
    }

    var mediaAnalysisID: String {
        "\(selectedSessionID?.uuidString ?? "none"):\(selectedQuestionKey ?? "none"):\(selectedRecording?.id.uuidString ?? "none")"
    }

    var selectedTranscript: AnswerTranscript? {
        guard let transcript = selectedAnswer?.transcript else { return nil }
        guard transcript.sourceRecordingID == nil || transcript.sourceRecordingID == selectedRecording?.id else { return nil }
        return transcript
    }

    var canTranscribeSelectedRecording: Bool {
        selectedRecordingURL != nil && selectedAnswer?.state != .skipped && !isBulkTranscribing
    }

    var isLegacyImport: Bool {
        sessions.contains { session in
            session.auditEvents.contains { $0.action == "legacy_import_locked" }
        }
    }

    func flushToDocument() {
        document?.apply(project: project, sessions: sessions)
    }

    func prepareMediaAnalysis() async {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        isLoadingWaveform = false
        waveform = nil
        waveformMessage = nil
        transcriptionMessage = nil

        guard let url = selectedRecordingURL else { return }
        let analysisID = mediaAnalysisID
        isLoadingWaveform = true
        do {
            let waveform = try await Task.detached(priority: .userInitiated) {
                try await AudioWaveformAnalyzer().analyze(url: url)
            }.value
            guard analysisID == mediaAnalysisID else { return }
            self.waveform = waveform
        } catch is CancellationError {
            return
        } catch {
            guard analysisID == mediaAnalysisID else { return }
            waveformMessage = error.localizedDescription
        }
        if analysisID == mediaAnalysisID {
            isLoadingWaveform = false
        }
    }

    func transcribeSelectedRecording() {
        guard !isBulkTranscribing else {
            transcriptionMessage = "Project-wide transcription is already running."
            return
        }
        guard let url = selectedRecordingURL, let recording = selectedRecording, let questionKey = selectedQuestionKey else {
            transcriptionMessage = "Select a recording before transcribing."
            return
        }
        guard canTranscribeSelectedRecording else {
            transcriptionMessage = "Skipped answers do not have a recording to transcribe."
            return
        }

        transcriptionTask?.cancel()
        let analysisID = mediaAnalysisID
        isTranscribing = true
        transcriptionMessage = nil
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.mediaAnalysisID == analysisID {
                    self.isTranscribing = false
                    self.transcriptionTask = nil
                }
            }

            do {
                let transcript = try await self.speechTranscriber.transcribe(
                    url: url,
                    sourceRecordingID: recording.id,
                    localeIdentifier: self.project.person.localeIdentifier
                )
                guard self.mediaAnalysisID == analysisID,
                      let sessionIndex = self.sessions.firstIndex(where: { $0.id == self.selectedSessionID }) else { return }
                var answer = self.sessions[sessionIndex].answers[questionKey] ?? InterviewAnswer(questionKey: questionKey)
                answer.transcript = transcript
                self.sessions[sessionIndex].answers[questionKey] = answer
                self.flushToDocument()

                if self.document?.packageStore != nil {
                    try await self.persist(session: self.sessions[sessionIndex])
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.mediaAnalysisID == analysisID else { return }
                self.transcriptionMessage = error.localizedDescription
            }
        }
    }

    var missingTranscriptionSummary: TranscriptionBatchSummary {
        let plan = makeMissingTranscriptionPlan()
        return TranscriptionBatchSummary(candidateCount: plan.candidates.count, skippedCount: plan.skippedCount)
    }

    func transcribeMissingAnswers() {
        guard !isTranscribing, !isBulkTranscribing else {
            transcriptionMessage = "A transcription is already running."
            return
        }

        let plan = makeMissingTranscriptionPlan()
        guard !plan.candidates.isEmpty else {
            progressMessage = "No missing transcripts with usable selected recordings were found."
            return
        }

        isBulkTranscribing = true
        transcriptionMessage = nil
        progressMessage = "Transcribing 0 of \(plan.candidates.count) missing answers…"
        bulkTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completedCount = 0
            var failures: [String] = []
            var stoppedByAuthorization = false
            var cancelled = false

            defer {
                self.isBulkTranscribing = false
                self.bulkTranscriptionTask = nil

                if cancelled {
                    self.progressMessage = "Transcription cancelled after \(completedCount) of \(plan.candidates.count) answers."
                } else {
                    self.progressMessage = "Transcription finished: \(completedCount) of \(plan.candidates.count) answers."
                }

                if plan.skippedCount > 0 {
                    self.progressMessage? += " \(plan.skippedCount) answer(s) were skipped because no usable selected recording was available."
                }
                if stoppedByAuthorization {
                    self.transcriptionMessage = "Transcription stopped: \(failures.first ?? "Speech recognition is not available.")"
                } else if !failures.isEmpty {
                    let visibleFailures = failures.prefix(3).joined(separator: "\n")
                    let remaining = failures.count > 3 ? "\n…and \(failures.count - 3) more." : ""
                    self.transcriptionMessage = "Some answers could not be transcribed:\n\(visibleFailures)\(remaining)"
                }
            }

            for candidate in plan.candidates {
                do {
                    try Task.checkCancellation()
                    let transcript = try await self.speechTranscriber.transcribe(
                        url: candidate.url,
                        sourceRecordingID: candidate.recording.id,
                        localeIdentifier: self.project.person.localeIdentifier
                    )
                    guard let sessionIndex = self.sessions.firstIndex(where: { $0.id == candidate.sessionID }) else { continue }
                    var answer = self.sessions[sessionIndex].answers[candidate.questionKey]
                        ?? InterviewAnswer(questionKey: candidate.questionKey)
                    guard answer.transcript == nil else { continue }
                    answer.transcript = transcript
                    self.sessions[sessionIndex].answers[candidate.questionKey] = answer
                    self.flushToDocument()
                    try await self.persist(session: self.sessions[sessionIndex])
                    completedCount += 1
                    self.progressMessage = "Transcribing \(completedCount) of \(plan.candidates.count) missing answers…"
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch let error as SpeechTranscriptionError {
                    failures.append("\(candidate.label): \(error.localizedDescription)")
                    if error.stopsBatch {
                        stoppedByAuthorization = true
                        break
                    }
                } catch {
                    failures.append("\(candidate.label): \(error.localizedDescription)")
                }
            }
        }
    }

    private func makeMissingTranscriptionPlan() -> MissingTranscriptionPlan {
        guard let store = document?.packageStore else {
            return MissingTranscriptionPlan(candidates: [], skippedCount: 0)
        }

        let questionOrder = Dictionary(uniqueKeysWithValues: project.questions.enumerated().map { ($0.element.questionKey, $0.offset) })
        let questionText = Dictionary(uniqueKeysWithValues: project.questions.map { ($0.questionKey, $0.displayText) })
        var candidates: [TranscriptionCandidate] = []
        var skippedCount = 0

        for session in sessions {
            let answers = session.answers.values.sorted { left, right in
                let leftOrder = questionOrder[left.questionKey] ?? Int.max
                let rightOrder = questionOrder[right.questionKey] ?? Int.max
                return leftOrder == rightOrder ? left.questionKey < right.questionKey : leftOrder < rightOrder
            }

            for answer in answers {
                guard answer.transcript == nil, answer.state != .skipped else { continue }
                guard let part = answer.selectedTake?.parts.first,
                      let recording = session.recordings.first(where: { $0.id == part.sourceRecordingID }),
                      let url = try? store.resolve(relativePath: recording.packageRelativePath),
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    skippedCount += 1
                    continue
                }

                let questionLabel = questionText[answer.questionKey] ?? answer.questionKey
                candidates.append(TranscriptionCandidate(
                    sessionID: session.id,
                    questionKey: answer.questionKey,
                    recording: recording,
                    url: url,
                    label: "\(session.ageLabel) · \(questionLabel)"
                ))
            }
        }

        return MissingTranscriptionPlan(candidates: candidates, skippedCount: skippedCount)
    }

    private func persist(session: InterviewSession) async throws {
        guard let store = document?.packageStore else { return }
        try await Task.detached(priority: .utility) {
            try store.writeSession(session)
            try store.rebuildInventory()
        }.value
    }

    func seek(to timeUS: Int64) {
        guard let player else { return }
        let clamped = max(0, timeUS)
        player.seek(to: CMTime(value: clamped, timescale: 1_000_000))
        currentTimeUS = clamped
    }

    func replacePlayer(with url: URL) {
        removePlaybackObservers()
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        playerObservation.player = newPlayer
        playerObservation.periodic = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 50_000, timescale: 1_000_000), queue: .main) { [weak self] time in
            guard time.isNumeric else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTimeUS = max(0, Int64((time.seconds * 1_000_000).rounded()))
            }
        }
    }

    func playFullRecording() {
        removeRangeBoundaryObserver()
        player?.play()
    }

    func playVisibleAnswer() {
        guard let range = selectedTimelineRange else { return }
        playRange(startUS: range.visibleStartUS, endUS: range.visibleEndUS)
    }

    func playBufferedSelection() {
        guard let range = selectedTimelineRange,
              let start = range.safeLeadingStartUS,
              let end = range.safeTrailingEndUS else { return }
        playRange(startUS: start, endUS: end)
    }

    private func playRange(startUS: Int64, endUS: Int64) {
        guard let player, endUS > startUS else { return }
        removeRangeBoundaryObserver()
        let capturedPlayer = player
        let start = CMTime(value: startUS, timescale: 1_000_000)
        let end = CMTime(value: endUS, timescale: 1_000_000)
        capturedPlayer.pause()
        capturedPlayer.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, capturedPlayer] _ in
            Task { @MainActor [weak self, capturedPlayer] in
                guard let self, self.player === capturedPlayer else { return }
                self.currentTimeUS = startUS
                self.playerObservation.boundary = capturedPlayer.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self, capturedPlayer] in
                    Task { @MainActor [weak self, capturedPlayer] in
                        guard let self, self.player === capturedPlayer else { return }
                        capturedPlayer.pause()
                        self.currentTimeUS = endUS
                        self.removeRangeBoundaryObserver()
                    }
                }
                capturedPlayer.play()
            }
        }
    }

    private func removeRangeBoundaryObserver() {
        if let token = playerObservation.boundary {
            playerObservation.player?.removeTimeObserver(token)
            playerObservation.boundary = nil
        }
    }

    private func removePlaybackObservers() {
        playerObservation.invalidate()
    }

    func save() {
        flushToDocument()
        document?.save(nil)
    }

    func addYear(age: Double) {
        let ageDisplay = age.formatted(.number.precision(.fractionLength(0...2)))
        let ageLabel = age == 1 ? "1 Year Old" : "\(ageDisplay) Years Old"
        let ageKey = InterviewStudioKey.readableKey(
            from: "age \(ageDisplay)",
            existing: Set(sessions.map(\.ageKey))
        )
        let session = InterviewSession(id: UUID(), ageKey: ageKey, ageLabel: ageLabel, ageSortValue: age)
        sessions.append(session)
        sessions.sort { ($0.ageSortValue ?? .greatestFiniteMagnitude) < ($1.ageSortValue ?? .greatestFiniteMagnitude) }
        selectedSessionID = session.id
        selectedRecordingID = nil
        selectedQuestionKey = project.activeQuestions.first?.questionKey
        flushToDocument()
    }

    func importFinderRecordings() {
        guard let store = document?.packageStore else {
            errorMessage = "Save the project before importing source recordings."
            return
        }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            errorMessage = "Add or select an interview year first."
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK else { return }
        let session = sessions[sessionIndex]
        let recordingURLs = panel.urls
        let storeForImport = store
        isBusy = true
        progressMessage = "Staging \(recordingURLs.count) recording(s)…"
        let importTask = Task.detached(priority: .userInitiated) {
            var updated = session
            for (index, url) in recordingURLs.enumerated() {
                let imported = try await storeForImport.importRecording(
                    from: url,
                    ageKey: session.ageKey,
                    ageLabel: session.ageLabel,
                    source: .finder,
                    order: updated.recordings.count + index
                )
                if imported.duplicateOf == nil {
                    updated.recordings.append(imported.recording)
                }
            }
            try storeForImport.writeSession(updated)
            try storeForImport.rebuildInventory()
            return updated
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated = try await importTask.value
                guard let currentIndex = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                self.sessions[currentIndex] = updated
                self.selectedRecordingID = updated.recordings.first?.id
                self.progressMessage = "Recording import complete."
                self.isBusy = false
                self.flushToDocument()
            } catch {
                self.errorMessage = error.localizedDescription
                self.progressMessage = nil
                self.isBusy = false
            }
        }
    }

    func markStart() { updateSelectedAnswer(marker: .start) }
    func markEnd() { updateSelectedAnswer(marker: .end) }
    func markResume() { updateSelectedAnswer(marker: .resume) }
    func markNoResume() { updateSelectedAnswer(marker: .noResume) }

    func completeSelectedAnswer() {
        guard let questionKey = selectedQuestionKey, let recordingID = selectedRecording?.id, let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }), var answer = sessions[sessionIndex].answers[questionKey], let takeIndex = answer.takes.firstIndex(where: { $0.id == answer.selectedTakeID }) else {
            errorMessage = "Mark an answer range before completing it."
            return
        }
        guard let partIndex = answer.takes[takeIndex].parts.firstIndex(where: { $0.sourceRecordingID == recordingID }) else {
            errorMessage = "Select a recording for this answer."
            return
        }
        let part = answer.takes[takeIndex].parts[partIndex]
        guard part.rawMarkers.answerStart != nil, part.rawMarkers.answerEnd != nil else {
            errorMessage = "Both answer start and answer end are required."
            return
        }
        answer.takes[takeIndex].reviewState = .reviewed
        answer.state = .complete
        answer.lastReviewedAt = Date()
        sessions[sessionIndex].answers[questionKey] = answer
        flushToDocument()
    }

    func markSkipped() {
        guard let questionKey = selectedQuestionKey, let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        var answer = sessions[sessionIndex].answers[questionKey] ?? InterviewAnswer(questionKey: questionKey)
        answer.state = .skipped
        sessions[sessionIndex].answers[questionKey] = answer
        flushToDocument()
    }

    func finishAndLock() {
        guard let store = document?.packageStore, let selectedSession else {
            errorMessage = "Save the project and select an interview year before locking."
            return
        }
        isBusy = true
        progressMessage = "Generating validated answer clips and manifest…"
        let project = self.project
        let buildRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("YearlyInterviewStudio/Generated", isDirectory: true)
        let finishTask = Task.detached(priority: .userInitiated) {
            try await FinishAndLockService().finishAndLock(project: project, session: selectedSession, store: store, buildRoot: buildRoot)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await finishTask.value
                self.sessions = try store.listSessions()
                self.renderPlan = result.renderPlan
                self.selectedSessionID = selectedSession.id
                self.isBusy = false
                self.progressMessage = "Year locked. Assembly is ready for inspection; rendering was not started."
                self.flushToDocument()
            } catch {
                self.errorMessage = error.localizedDescription
                self.progressMessage = "The year remains open; no lock was committed."
                self.isBusy = false
            }
        }
    }

    func unlockSelectedYear() {
        guard let store = document?.packageStore, let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        var unlockedSession = sessions[index]
        do {
            try unlockedSession.unlock()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isBusy = true
        progressMessage = "Unlocking year…"
        let unlockTask = Task.detached(priority: .utility) {
            try store.writeSession(unlockedSession)
            try store.rebuildInventory()
            return unlockedSession
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let persistedSession = try await unlockTask.value
                guard let currentIndex = self.sessions.firstIndex(where: { $0.id == persistedSession.id }) else { return }
                self.sessions[currentIndex] = persistedSession
                self.isBusy = false
                self.progressMessage = "Year unlocked."
                self.flushToDocument()
            } catch {
                self.isBusy = false
                self.progressMessage = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private enum Marker {
        case start
        case end
        case resume
        case noResume
    }

    private func updateSelectedAnswer(marker: Marker) {
        guard let questionKey = selectedQuestionKey, let recordingID = selectedRecording?.id, let sessionIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            errorMessage = "Select an interview year, question, and source recording first."
            return
        }
        if sessions[sessionIndex].lifecycle == .locked {
            errorMessage = "Unlock the year before changing answer markers."
            return
        }
        var answer = sessions[sessionIndex].answers[questionKey] ?? InterviewAnswer(questionKey: questionKey)
        if answer.takes.isEmpty {
            let take = AnswerTake(parts: [AnswerPart(sourceRecordingID: recordingID, rawMarkers: .init())])
            answer.takes = [take]
            answer.selectedTakeID = take.id
        }
        guard let takeIndex = answer.takes.firstIndex(where: { $0.id == answer.selectedTakeID }), let partIndex = answer.takes[takeIndex].parts.firstIndex(where: { $0.sourceRecordingID == recordingID }) else {
            errorMessage = "The selected recording is not attached to this answer."
            return
        }
        switch marker {
        case .start:
            answer.takes[takeIndex].parts[partIndex].rawMarkers.answerStart = .microseconds(currentTimeUS)
        case .end:
            answer.takes[takeIndex].parts[partIndex].rawMarkers.answerEnd = .microseconds(currentTimeUS)
        case .resume:
            answer.takes[takeIndex].parts[partIndex].rawMarkers.interviewerResumes = .microseconds(currentTimeUS)
        case .noResume:
            answer.takes[takeIndex].parts[partIndex].rawMarkers.noFollowingInterviewerSpeech = true
        }
        answer.state = .inProgress
        sessions[sessionIndex].answers[questionKey] = answer
        flushToDocument()
    }
}

struct TranscriptionBatchSummary: Sendable {
    let candidateCount: Int
    let skippedCount: Int

    var confirmationMessage: String {
        var message = "(candidateCount) answer(s) have a selected recording and no saved transcript."
        if skippedCount > 0 {
            message += "\n\n(skippedCount) other answer(s) will be left unchanged because they have no usable selected recording."
        }
        message += "\n\nExisting transcripts will not be overwritten."
        return message
    }
}

private struct MissingTranscriptionPlan {
    let candidates: [TranscriptionCandidate]
    let skippedCount: Int
}

private struct TranscriptionCandidate {
    let sessionID: UUID
    let questionKey: String
    let recording: SourceRecording
    let url: URL
    let label: String
}

@MainActor
final class NewInterviewYearDraft: ObservableObject {
    @Published var ageText = ""
    @Published var validationMessage: String?

    func reset() {
        ageText = ""
        validationMessage = nil
    }
}

struct DocumentWorkspaceView: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel

    var body: some View {
        NavigationSplitView {
            projectSidebar
        } content: {
            questionList
        } detail: {
            editor
        }
        .frame(minWidth: 1_100, minHeight: 680)
        .alert("Project issue", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.isAddingYear) {
            NewInterviewYearSheet(draft: model.newInterviewYearDraft) { age in
                model.addYear(age: age)
                model.isAddingYear = false
            }
        }
    }

    private var projectSidebar: some View {
        List(selection: $model.selectedSessionID) {
            Section("Project") {
                Label(model.project.person.displayName, systemImage: "person.crop.circle")
            }
            if model.isLegacyImport {
                Section("Legacy Import") {
                    Label {
                        Text("Previous years start locked by default. Unlock a year to edit its clips.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Section("Interview Years") {
                ForEach(model.sessions) { session in
                    Label {
                        VStack(alignment: .leading) {
                            Text(session.ageLabel)
                            Text(session.lifecycle == .locked ? "Locked" : "Open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: session.lifecycle == .locked ? "lock.fill" : "circle")
                    }
                    .tag(session.id)
                }
            }
        }
        .navigationTitle("Project")
        .toolbar {
            ToolbarItemGroup {
                Button("New Year", systemImage: "plus") { model.isAddingYear = true }
                Button("Save", systemImage: "square.and.arrow.down") { model.save() }
            }
        }
    }

    private var questionList: some View {
        List(selection: $model.selectedQuestionKey) {
            ForEach(model.project.activeQuestions) { question in
                let state = model.selectedSession?.answers[question.questionKey]?.state ?? .notStarted
                Label {
                    VStack(alignment: .leading) {
                        Text(question.displayText)
                            .lineLimit(2)
                        Text(state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption)
                            .foregroundStyle(state == .complete ? .green : .secondary)
                    }
                } icon: {
                    Image(systemName: state == .complete ? "checkmark.circle.fill" : state == .skipped ? "forward.end.circle" : "circle")
                }
                .tag(question.questionKey)
            }
        }
        .navigationTitle("Questions")
        .toolbar {
            ToolbarItemGroup {
                Button("Import Recordings", systemImage: "square.and.arrow.down") { model.importFinderRecordings() }
                Button("Lock Year", systemImage: "lock") { model.finishAndLock() }
                    .disabled(model.selectedSession?.lifecycle == .locked || model.isBusy)
                Button("Unlock", systemImage: "lock.open") { model.unlockSelectedYear() }
                    .disabled(model.selectedSession?.lifecycle != .locked || model.isBusy)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let question = model.selectedQuestion, let session = model.selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(question.displayText).font(.title2.weight(.semibold))
                            Text(session.ageLabel).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.lifecycle == .locked ? "Locked" : "Open")
                            .foregroundStyle(session.lifecycle == .locked ? .orange : .green)
                    }
                    RecordingPlayer(model: model)
                    markerControls
                    answerStatus
                    if let progressMessage = model.progressMessage {
                        Label(progressMessage, systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let renderPlan = model.renderPlan {
                        AssemblySummaryView(renderPlan: renderPlan)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Answer Editor")
        } else {
            ContentUnavailableView("Select an interview year and question", systemImage: "rectangle.split.3x1")
        }
    }

    private var markerControls: some View {
        GroupBox("Answer markers") {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: "Current source time %.3fs", Double(model.currentTimeUS) / 1_000_000))
                    .font(.caption.monospaced())
                HStack {
                    Button("Mark Start (I)") { model.markStart() }
                    Button("Mark End (O)") { model.markEnd() }
                    Button("Interviewer Resumes (;) ") { model.markResume() }
                    Button("No Following Speech") { model.markNoResume() }
                }
                HStack {
                    Button("Complete After Review") { model.completeSelectedAnswer() }
                    Button("Mark Skipped") { model.markSkipped() }
                }
            }
        }
    }

    private var answerStatus: some View {
        let answer = model.selectedAnswer
        return GroupBox("Answer state") {
            VStack(alignment: .leading, spacing: 6) {
                Text(answer?.state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not started")
                    .font(.headline)
                if let take = answer?.selectedTake, let part = take.parts.first {
                    Text("Raw start \(part.rawMarkers.answerStart?.microseconds.description ?? "—") µs · end \(part.rawMarkers.answerEnd?.microseconds.description ?? "—") µs")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Completing an answer requires review; skipped answers remain visible and are omitted at publication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NewInterviewYearSheet: View {
    @ObservedObject var draft: NewInterviewYearDraft
    let onCreate: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    private var parsedAge: Double? {
        let value = draft.ageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let age = Double(value), age.isFinite, age >= 0 else { return nil }
        return age
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Interview Year")
                .font(.title2.weight(.semibold))
            Text("Enter the person’s age for this interview. Half-years are supported, such as 2.5.")
                .foregroundStyle(.secondary)
            TextField("Age in years", text: $draft.ageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createYear)
            if let validationMessage = draft.validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Year", action: createYear)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedAge == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .task {
            draft.reset()
        }
    }

    private func createYear() {
        guard let age = parsedAge else {
            draft.validationMessage = "Enter a number such as 5 or 2.5."
            return
        }
        onCreate(age)
    }
}

    private struct RecordingPlayer: View {
    @ObservedObject var model: InterviewStudioWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedRecording?.importSource == .legacy {
                Label("Legacy clip loaded for this question", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = recordingURL {
                AVPlayerContainer(player: model.player)
                    .frame(minHeight: 360)
                    .onAppear {
                        model.replacePlayer(with: url)
                    }
                    .onChange(of: url) { _, newValue in
                        model.replacePlayer(with: newValue)
                        model.currentTimeUS = 0
                    }
                if model.isLoadingWaveform {
                    ProgressView("Building waveform…")
                        .controlSize(.small)
                } else if let waveform = model.waveform {
                    WaveformView(waveform: waveform, timeline: model.selectedTimelineRange, currentTimeUS: model.currentTimeUS) { timeUS in
                        model.seek(to: timeUS)
                    }
                    if let range = model.selectedTimelineRange {
                        Text(timelineSummary(range))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else if let waveformMessage = model.waveformMessage {
                    Label(waveformMessage, systemImage: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TranscriptPanel(
                    transcript: model.selectedTranscript,
                    isTranscribing: model.isTranscribing,
                    canTranscribe: model.canTranscribeSelectedRecording,
                    message: model.transcriptionMessage,
                    onTranscribe: model.transcribeSelectedRecording
                )
                HStack {
                    Button("Preview Answer") { model.playVisibleAnswer() }
                    Button("Preview With Buffers") { model.playBufferedSelection() }
                        .disabled(model.selectedTimelineRange?.hasPreciseBuffers != true)
                    Button("Play Full Recording") { model.playFullRecording() }
                    Button("Pause") { model.player?.pause() }
                    Button("-1 s") { seek(by: -1) }
                    Button("+1 s") { seek(by: 1) }
                    TextField("Source seconds", value: Binding(get: { Double(model.currentTimeUS) / 1_000_000 }, set: { model.currentTimeUS = Int64(($0 * 1_000_000).rounded()) }), format: .number)
                        .frame(width: 120)
                }
                .task(id: model.mediaAnalysisID) {
                    await model.prepareMediaAnalysis()
                }
            } else if model.selectedRecording?.importSource == .legacy {
                ContentUnavailableView("Legacy clip unavailable", systemImage: "exclamationmark.triangle", description: Text("The imported manifest row could not be resolved to a playable clip."))
            } else {
                ContentUnavailableView("Import a recording", systemImage: "video.badge.plus", description: Text("Finder import is available from the Questions toolbar."))
            }
        }
    }

    private var recordingURL: URL? {
        model.selectedRecordingURL
    }

    private func seek(by seconds: Double) {
        guard let player = model.player else { return }
        let time = player.currentTime().seconds + seconds
        model.seek(to: Int64(max(0, time) * 1_000_000))
    }

    private func timelineSummary(_ range: SelectedTimelineRange) -> String {
        let answer = String(format: "Answer %.2f–%.2fs", Double(range.visibleStartUS) / 1_000_000, Double(range.visibleEndUS) / 1_000_000)
        guard let start = range.safeLeadingStartUS, let end = range.safeTrailingEndUS else {
            return "\(answer) · leading/trailing buffers unavailable until refined"
        }
        return String(format: "Leading buffer %.2fs · %@ · trailing buffer %.2fs · export %.2f–%.2fs",
                      Double(range.visibleStartUS - start) / 1_000_000,
                      answer,
                      Double(end - range.visibleEndUS) / 1_000_000,
                      Double(start) / 1_000_000,
                      Double(end) / 1_000_000)
    }
}

private struct AVPlayerContainer: NSViewRepresentable {
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

private struct AssemblySummaryView: View {
    let renderPlan: RenderPlan

    var body: some View {
        GroupBox("Assembly") {
            VStack(alignment: .leading, spacing: 6) {
                Text(renderPlan.summary.exportAllowed ? "Ready for final render" : "Blocked")
                    .font(.headline)
                Text("Questions \(renderPlan.summary.questionCount) · Answers \(renderPlan.summary.answerClipCount) · Blockers \(renderPlan.summary.blockerCount) · Warnings \(renderPlan.summary.warningCount)")
                    .foregroundStyle(.secondary)
                Text("The final renderer remains manual: choose a Save-panel destination after reviewing the Sequence and Issues windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
