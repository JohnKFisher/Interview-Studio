import AppKit
import Core
import Darwin
import SwiftUI

private struct StagedRecordingCommit {
    let imported: StagedRecordingImport
    let stagedURL: URL
    let stagedRelativePath: String
}

private func stagedFileByteCount(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value) ?? 0
}

final class InterviewStudioDocument: NSDocument {
    var project: InterviewStudioProject
    var sessions: [InterviewSession]
    private var pendingPublicationRecords: [PublicationRecord]
    private var pendingRecordingImports: [StagedRecordingImport]
    private var cachedPackageStore: InterviewStudioPackageStore?
    private(set) var consolidationRecoveryMessage: String?
    var packageStore: InterviewStudioPackageStore? {
        get {
            guard let fileURL else { return cachedPackageStore }
            let canonicalURL = fileURL.standardizedFileURL
            if let cachedPackageStore, cachedPackageStore.rootURL == canonicalURL {
                return cachedPackageStore
            }
            return try? InterviewStudioPackageStore(rootURL: canonicalURL)
        }
        set {
            cachedPackageStore = newValue
        }
    }
    var workspaceModel: InterviewStudioWorkspaceModel?
    private(set) var isPackageReadOnly = false
    private(set) var needsSaveAfterOpen = false

    override class var autosavesInPlace: Bool { true }

    override init() {
        project = InterviewStudioProject(person: InterviewPerson(readableKey: "person", displayName: "Person"))
        sessions = []
        pendingPublicationRecords = []
        pendingRecordingImports = []
        cachedPackageStore = nil
        consolidationRecoveryMessage = nil
        super.init()
        hasUndoManager = true
    }

    required init?(coder: NSCoder) {
        project = InterviewStudioProject(person: InterviewPerson(readableKey: "person", displayName: "Person"))
        sessions = []
        pendingPublicationRecords = []
        pendingRecordingImports = []
        cachedPackageStore = nil
        consolidationRecoveryMessage = nil
        super.init()
    }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let store = try InterviewStudioPackageStore(rootURL: url)
        var project = try store.readProjectAllowingReadOnly()
        let productionQuestions = InterviewProductionQuestionOrder.ordered(project.questions)
        let didNormalizeQuestionOrder = productionQuestions != project.questions
        if didNormalizeQuestionOrder {
            project.questions = productionQuestions
            project.updatedAt = Date()
        }
        var sessions = try store.listSessions()
        let legacyRowsURL = url.appendingPathComponent("Legacy Import/Original/legacy_rows.json")
        if let data = try? Data(contentsOf: legacyRowsURL),
           let rows = try? JSONDecoder.interviewStudio.decode([ManifestRow].self, from: data) {
            let restorer = LegacyRangeRestorer()
            sessions = sessions.map { restorer.repair(session: $0, rows: rows) }
        }
        let recoveryJournal: RecordingConsolidationJournal?
        do {
            recoveryJournal = try store.readConsolidationJournal()
        } catch {
            throw InterviewStudioPackageError.invalidPackage("The recording-import recovery journal could not be read: \(error.localizedDescription)")
        }
        var recoveredImports: [StagedRecordingImport] = []
        if let recoveryJournal {
            for entry in recoveryJournal.entries {
                if let recording = entry.recording,
                   let sessionID = entry.sessionID,
                   let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
                   !sessions[sessionIndex].recordings.contains(where: { $0.id == recording.id }) {
                    sessions[sessionIndex].recordings.append(recording)
                }
                if let stagedRelativePath = entry.stagedRelativePath,
                   let stagedURL = try? store.resolve(relativePath: stagedRelativePath),
                   FileManager.default.isReadableFile(atPath: stagedURL.path),
                   let recording = entry.recording {
                    recoveredImports.append(StagedRecordingImport(imported: ImportedRecording(recording: recording), stagedURL: stagedURL))
                }
            }
        }
        MainActor.assumeIsolated {
            self.packageStore = store
            self.project = project
            self.sessions = sessions
            self.pendingPublicationRecords = []
            self.pendingRecordingImports = recoveredImports
            self.isPackageReadOnly = !project.compatibility.isWritable || sessions.contains { !$0.compatibility.isWritable }
            self.needsSaveAfterOpen = (didNormalizeQuestionOrder || !recoveredImports.isEmpty || recoveryJournal != nil) && project.compatibility.isWritable
            self.consolidationRecoveryMessage = recoveryJournal.map {
                "The previous recording import did not finish committing. \($0.entries.count) recording(s) remain in recovery and will not be discarded automatically."
            }
        }
    }

    nonisolated override func write(to url: URL, ofType typeName: String) throws {
        let snapshot = MainActor.assumeIsolated {
            (isPackageReadOnly, project, sessions, pendingPublicationRecords, pendingRecordingImports, packageStore)
        }
        guard !snapshot.0 else {
            throw InterviewStudioPackageError.incompatible(snapshot.1.compatibility)
        }
        let destination = url.standardizedFileURL
        let store: InterviewStudioPackageStore
        if let existingStore = snapshot.5, existingStore.rootURL == destination {
            store = existingStore
        } else if let existingStore = snapshot.5 {
            var isDirectory: ObjCBool = false
            guard !FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
                throw InterviewStudioPackageError.fileExists(destination)
            }
            try cloneOrCopyPackage(from: existingStore.rootURL, to: destination)
            store = try InterviewStudioPackageStore(rootURL: destination)
        } else {
            store = try InterviewStudioPackageStore.create(project: snapshot.1, at: destination)
        }
        let stagedImports = snapshot.4.filter { $0.stagedURL != nil }
        if stagedImports.isEmpty, let journal = try store.readConsolidationJournal(), journal.phase == .inventoryCommitted {
            let fullyCommitted = journal.entries.allSatisfy { entry in
                guard let recording = entry.recording,
                      let sessionID = entry.sessionID,
                      snapshot.2.first(where: { $0.id == sessionID })?.recordings.contains(where: { $0.id == recording.id }) == true,
                      let finalURL = try? store.resolve(relativePath: recording.packageRelativePath),
                      FileManager.default.isReadableFile(atPath: finalURL.path) else { return false }
                return stagedFileByteCount(finalURL) == recording.mediaSignature.byteCount && sha256(fileURL: finalURL) == recording.mediaSignature.sha256
            }
            if fullyCommitted {
                try store.removeConsolidationJournal()
            }
        }
        var stagedCommits: [StagedRecordingCommit] = []
        var consolidationJournal: RecordingConsolidationJournal?
        var copiedExternalStagingRoot: URL?
        if !stagedImports.isEmpty {
            var journalEntries: [RecordingConsolidationJournal.Entry] = []
            for stagedImport in stagedImports {
                let recording = stagedImport.imported.recording
                let sessionID = snapshot.2.first(where: { session in
                    session.recordings.contains(where: { candidate in candidate.id == recording.id })
                })?.id
                guard let sourceStagedURL = stagedImport.stagedURL else {
                    throw InterviewStudioPackageError.invalidPackage("A staged recording is missing its staging URL and cannot be recovered safely.")
                }

                let stagedURL: URL
                if let sourceStore = snapshot.5,
                   sourceStore.rootURL != store.rootURL,
                   let sourceRelativePath = sourceStore.packageRelativePath(for: sourceStagedURL) {
                    let sourceURL = try sourceStore.resolve(relativePath: sourceRelativePath)
                    let destinationURL = try store.resolve(relativePath: sourceRelativePath)
                    if !FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }
                    guard FileManager.default.isReadableFile(atPath: destinationURL.path),
                          stagedFileByteCount(destinationURL) == recording.mediaSignature.byteCount,
                          sha256(fileURL: destinationURL) == recording.mediaSignature.sha256 else {
                        throw InterviewStudioPackageError.checksumMismatch(destinationURL)
                    }
                    stagedURL = destinationURL
                } else if store.packageRelativePath(for: sourceStagedURL) != nil {
                    stagedURL = sourceStagedURL
                } else {
                    let stagingRoot = copiedExternalStagingRoot ?? store.rootURL
                        .appendingPathComponent(".recording-staging", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    copiedExternalStagingRoot = stagingRoot
                    let destinationURL = stagingRoot.appendingPathComponent(recording.packageRelativePath)
                    try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: sourceStagedURL, to: destinationURL)
                    guard FileManager.default.isReadableFile(atPath: destinationURL.path),
                          stagedFileByteCount(destinationURL) == recording.mediaSignature.byteCount,
                          sha256(fileURL: destinationURL) == recording.mediaSignature.sha256 else {
                        throw InterviewStudioPackageError.checksumMismatch(destinationURL)
                    }
                    stagedURL = destinationURL
                }
                guard let stagedRelativePath = store.packageRelativePath(for: stagedURL) else {
                    throw InterviewStudioPackageError.invalidPackage("A staged recording is outside the project package and cannot be recovered safely.")
                }
                stagedCommits.append(StagedRecordingCommit(imported: stagedImport, stagedURL: stagedURL, stagedRelativePath: stagedRelativePath))
                journalEntries.append(RecordingConsolidationJournal.Entry(
                    id: recording.id,
                    relativePath: recording.packageRelativePath,
                    byteCount: recording.mediaSignature.byteCount,
                    sha256: recording.mediaSignature.sha256,
                    sessionID: sessionID,
                    recording: recording,
                    stagedRelativePath: stagedRelativePath
                ))
            }
            let journal = RecordingConsolidationJournal(entries: journalEntries)
            try store.writeConsolidationJournal(journal)
            consolidationJournal = journal
        }

        var changedInventoryPaths = Set<String>()
        var trustedInventoryEntries: [PackageInventoryEntry] = []
        for stagedCommit in stagedCommits {
            try store.consolidateStagedRecording(from: stagedCommit.stagedURL, recording: stagedCommit.imported.imported.recording)
            if var journal = consolidationJournal {
                journal.phase = .mediaPromoted
                try store.writeConsolidationJournal(journal)
                consolidationJournal = journal
            }
            changedInventoryPaths.insert(stagedCommit.imported.imported.recording.packageRelativePath)
            trustedInventoryEntries.append(PackageInventoryEntry(
                relativePath: stagedCommit.imported.imported.recording.packageRelativePath,
                byteCount: stagedCommit.imported.imported.recording.mediaSignature.byteCount,
                sha256: stagedCommit.imported.imported.recording.mediaSignature.sha256,
                kind: .authoritative
            ))
        }
        try store.writeProject(snapshot.1)
        changedInventoryPaths.insert(InterviewStudioPackageStore.projectFilename)
        for session in snapshot.2 {
            try store.writeSession(session)
            changedInventoryPaths.insert("Sessions/\(session.id.uuidString)/session.json")
        }
        for publication in snapshot.3 {
            try store.writePublication(publication)
            changedInventoryPaths.insert("Publication History/\(publication.id.uuidString).json")
        }
        try store.rebuildInventory(
            changedPaths: changedInventoryPaths,
            trustedEntries: trustedInventoryEntries
        )

        if !stagedCommits.isEmpty {
            var journal = consolidationJournal ?? RecordingConsolidationJournal(entries: stagedCommits.map { stagedCommit in
                let recording = stagedCommit.imported.imported.recording
                return RecordingConsolidationJournal.Entry(
                    id: recording.id,
                    relativePath: recording.packageRelativePath,
                    byteCount: recording.mediaSignature.byteCount,
                    sha256: recording.mediaSignature.sha256,
                    recording: recording,
                    stagedRelativePath: stagedCommit.stagedRelativePath
                )
            })
            journal.phase = .metadataCommitted
            try store.writeConsolidationJournal(journal)
            journal.phase = .inventoryCommitted
            try store.writeConsolidationJournal(journal)
            try store.removeConsolidationJournal()
        }
        for stagedCommit in stagedCommits {
            if FileManager.default.fileExists(atPath: stagedCommit.stagedURL.path) {
                try FileManager.default.removeItem(at: stagedCommit.stagedURL)
            }
        }
        if let copiedExternalStagingRoot,
           FileManager.default.fileExists(atPath: copiedExternalStagingRoot.path) {
            try? FileManager.default.removeItem(at: copiedExternalStagingRoot)
        }
        let importedIDs = Set(stagedImports.map { $0.imported.recording.id })
        MainActor.assumeIsolated {
            self.pendingRecordingImports.removeAll { importedIDs.contains($0.imported.recording.id) }
            self.consolidationRecoveryMessage = nil
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try JSONEncoder.interviewStudio.encode(project)
    }

    override func makeWindowControllers() {
        let model = workspaceModel ?? InterviewStudioWorkspaceModel(document: self)
        workspaceModel = model
        let view = DocumentWorkspaceView(model: model)
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_480, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = project.person.displayName.isEmpty ? "Yearly Interview Studio" : "\(project.person.displayName) Interview"
        window.contentView = hostingView
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    override func close() {
        workspaceModel?.flushToDocument()
        super.close()
    }

    func apply(project: InterviewStudioProject, sessions: [InterviewSession]) {
        self.project = project
        self.sessions = sessions
        updateChangeCount(.changeDone)
    }

    func stage(publication: PublicationRecord) {
        if let index = pendingPublicationRecords.firstIndex(where: { $0.id == publication.id }) {
            pendingPublicationRecords[index] = publication
        } else {
            pendingPublicationRecords.append(publication)
        }
        updateChangeCount(.changeDone)
    }

    func stage(recordingImports: [StagedRecordingImport]) {
        pendingRecordingImports.append(contentsOf: recordingImports.filter { $0.stagedURL != nil })
        updateChangeCount(.changeDone)
    }

    var hasPendingRecordingImports: Bool {
        !pendingRecordingImports.isEmpty
    }

    /// Returns the playable URL for a recording in the current document.
    ///
    /// Newly imported recordings are staged until the document's next save. Keep
    /// those recordings usable in the open document instead of making the UI
    /// resolve a package-relative path that has not been materialized yet.
    func recordingURL(for recording: SourceRecording) -> URL? {
        if let store = packageStore,
           let packageURL = try? store.resolve(relativePath: recording.packageRelativePath),
           FileManager.default.isReadableFile(atPath: packageURL.path) {
            return packageURL
        }

        guard let stagedImport = pendingRecordingImports.reversed().first(where: {
            $0.imported.recording.id == recording.id
        }),
        let stagedURL = stagedImport.stagedURL,
        FileManager.default.isReadableFile(atPath: stagedURL.path) else {
            return nil
        }
        return stagedURL
    }

    func finishOpening() {
        guard needsSaveAfterOpen else { return }
        needsSaveAfterOpen = false
        updateChangeCount(.changeDone)
    }

    nonisolated private func cloneOrCopyPackage(from source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        if copyfile(source.path, destination.path, nil, flags) == 0 {
            return
        }
        let copyError = POSIXErrorCode(rawValue: errno) ?? .EIO
        try? FileManager.default.removeItem(at: destination)
        throw POSIXError(copyError)
    }

    func renderFinalMovie() {
        workspaceModel?.renderFinalMovie()
    }
}
