import AppKit
import Core
import Darwin
import SwiftUI

final class InterviewStudioDocument: NSDocument {
    var project: InterviewStudioProject
    var sessions: [InterviewSession]
    private var pendingPublicationRecords: [PublicationRecord]
    private var pendingRecordingImports: [StagedRecordingImport]
    private var cachedPackageStore: InterviewStudioPackageStore?
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
        super.init()
        hasUndoManager = true
    }

    required init?(coder: NSCoder) {
        project = InterviewStudioProject(person: InterviewPerson(readableKey: "person", displayName: "Person"))
        sessions = []
        pendingPublicationRecords = []
        pendingRecordingImports = []
        cachedPackageStore = nil
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
        MainActor.assumeIsolated {
            self.packageStore = store
            self.project = project
            self.sessions = sessions
            self.pendingPublicationRecords = []
            self.pendingRecordingImports = []
            self.isPackageReadOnly = !project.compatibility.isWritable
            self.needsSaveAfterOpen = didNormalizeQuestionOrder && project.compatibility.isWritable
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
        var changedInventoryPaths = Set<String>()
        var trustedInventoryEntries: [PackageInventoryEntry] = []
        for stagedImport in snapshot.4 {
            guard let stagedURL = stagedImport.stagedURL else { continue }
            let destinationURL = try store.resolve(relativePath: stagedImport.imported.recording.packageRelativePath)
            changedInventoryPaths.insert(stagedImport.imported.recording.packageRelativePath)
            trustedInventoryEntries.append(PackageInventoryEntry(
                relativePath: stagedImport.imported.recording.packageRelativePath,
                byteCount: stagedImport.imported.recording.mediaSignature.byteCount,
                sha256: stagedImport.imported.recording.mediaSignature.sha256,
                kind: .authoritative
            ))
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                guard sha256(fileURL: destinationURL) == stagedImport.imported.recording.mediaSignature.sha256 else {
                    throw InterviewStudioPackageError.checksumMismatch(destinationURL)
                }
            } else {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: stagedURL, to: destinationURL)
            }
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
        for stagedImport in snapshot.4 {
            if let stagedURL = stagedImport.stagedURL {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }
        MainActor.assumeIsolated {
            self.pendingRecordingImports.removeAll()
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
