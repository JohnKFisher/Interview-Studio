import AppKit
import Core
import SwiftUI

final class InterviewStudioDocument: NSDocument {
    var project: InterviewStudioProject
    var sessions: [InterviewSession]
    var packageStore: InterviewStudioPackageStore?
    var workspaceModel: InterviewStudioWorkspaceModel?
    private(set) var isPackageReadOnly = false

    override class var autosavesInPlace: Bool { true }

    override init() {
        project = InterviewStudioProject(person: InterviewPerson(readableKey: "person", displayName: "Person"))
        sessions = []
        packageStore = nil
        super.init()
        hasUndoManager = true
    }

    required init?(coder: NSCoder) {
        project = InterviewStudioProject(person: InterviewPerson(readableKey: "person", displayName: "Person"))
        sessions = []
        packageStore = nil
        super.init()
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let store = try InterviewStudioPackageStore(rootURL: url)
        let project = try store.readProjectAllowingReadOnly()
        self.packageStore = store
        self.project = project
        self.sessions = try store.listSessions()
        isPackageReadOnly = !project.compatibility.isWritable
    }

    override func write(to url: URL, ofType typeName: String) throws {
        guard !isPackageReadOnly else {
            throw InterviewStudioPackageError.incompatible(project.compatibility)
        }
        let destination = url.standardizedFileURL
        let store: InterviewStudioPackageStore
        if let existingStore = packageStore, existingStore.rootURL == destination {
            store = existingStore
        } else if let existingStore = packageStore {
            var isDirectory: ObjCBool = false
            guard !FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
                throw InterviewStudioPackageError.fileExists(destination)
            }
            try FileManager.default.copyItem(at: existingStore.rootURL, to: destination)
            store = try InterviewStudioPackageStore(rootURL: destination)
        } else {
            store = try InterviewStudioPackageStore.create(project: project, at: destination)
        }
        try store.writeProject(project)
        for session in sessions {
            try store.writeSession(session)
        }
        try store.rebuildInventory()
        packageStore = store
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
}
