import AVFoundation
import AVKit
import AppKit
import Core
import SwiftUI

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

    weak var document: InterviewStudioDocument?

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

    var selectedRecording: SourceRecording? {
        guard let selectedSession else { return nil }
        if let answerRecordingID = selectedAnswer?.selectedTake?.parts.first?.sourceRecordingID,
           let answerRecording = selectedSession.recordings.first(where: { $0.id == answerRecordingID }) {
            return answerRecording
        }
        return selectedSession.recordings.first { $0.id == selectedRecordingID } ?? selectedSession.recordings.first
    }

    var isLegacyImport: Bool {
        sessions.contains { session in
            session.auditEvents.contains { $0.action == "legacy_import_locked" }
        }
    }

    func flushToDocument() {
        document?.apply(project: project, sessions: sessions)
    }

    func save() {
        flushToDocument()
        document?.save(nil)
    }

    func addYear() {
        let ageLabel = "New Interview Year"
        let ageKey = InterviewStudioKey.readableKey(from: ageLabel)
        let session = InterviewSession(id: UUID(), ageKey: ageKey, ageLabel: ageLabel)
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
        isBusy = true
        progressMessage = "Staging \(panel.urls.count) recording(s)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var updated = session
                for (index, url) in panel.urls.enumerated() {
                    let imported = try store.importRecording(from: url, ageKey: session.ageKey, ageLabel: session.ageLabel, source: .finder, order: updated.recordings.count + index)
                    if imported.duplicateOf == nil {
                        updated.recordings.append(imported.recording)
                    }
                }
                self.sessions[sessionIndex] = updated
                self.selectedRecordingID = updated.recordings.first?.id
                self.progressMessage = "Recording import complete."
                self.isBusy = false
                self.flushToDocument()
                try store.writeSession(updated)
                try store.rebuildInventory()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await FinishAndLockService().finishAndLock(project: project, session: selectedSession, store: store, buildRoot: buildRoot)
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
        do {
            try sessions[index].unlock()
            try store.writeSession(sessions[index])
            try store.rebuildInventory()
            flushToDocument()
        } catch {
            errorMessage = error.localizedDescription
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
                Button("New Year", systemImage: "plus") { model.addYear() }
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
                        model.player = AVPlayer(url: url)
                    }
                    .onChange(of: url) { _, newValue in
                        model.player = AVPlayer(url: newValue)
                    }
                HStack {
                    Button("Play / Pause") {
                        guard let player = model.player else { return }
                        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
                    }
                    Button("-1 s") { seek(by: -1) }
                    Button("+1 s") { seek(by: 1) }
                    TextField("Source seconds", value: Binding(get: { Double(model.currentTimeUS) / 1_000_000 }, set: { model.currentTimeUS = Int64(($0 * 1_000_000).rounded()) }), format: .number)
                        .frame(width: 120)
                }
            } else if model.selectedRecording?.importSource == .legacy {
                ContentUnavailableView("Legacy clip unavailable", systemImage: "exclamationmark.triangle", description: Text("The imported manifest row could not be resolved to a playable clip."))
            } else {
                ContentUnavailableView("Import a recording", systemImage: "video.badge.plus", description: Text("Finder import is available from the Questions toolbar."))
            }
        }
    }

    private var recordingURL: URL? {
        guard let store = model.document?.packageStore, let recording = model.selectedRecording else { return nil }
        return try? store.resolve(relativePath: recording.packageRelativePath)
    }

    private func seek(by seconds: Double) {
        guard let player = model.player else { return }
        let time = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
        model.currentTimeUS = Int64(max(0, time) * 1_000_000)
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
