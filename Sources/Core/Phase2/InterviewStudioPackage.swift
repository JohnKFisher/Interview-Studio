import CryptoKit
import Foundation

public enum InterviewStudioPackageError: LocalizedError, Sendable {
    case invalidPackage(String)
    case unsafeRelativePath(String)
    case fileExists(URL)
    case checksumMismatch(URL)
    case inventoryMismatch(String)
    case incompatible(SchemaCompatibility)

    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): return message
        case .unsafeRelativePath(let path): return "Unsafe package-relative path: \(path)"
        case .fileExists(let url): return "The destination already exists: \(url.path)"
        case .checksumMismatch(let url): return "The imported bytes changed while staging \(url.lastPathComponent)."
        case .inventoryMismatch(let message): return "Package integrity verification failed: \(message)"
        case .incompatible(let compatibility): return compatibility.message ?? "The package is not compatible with this reader."
        }
    }
}

public enum PackageEntryKind: String, Codable, Hashable, Sendable {
    case authoritative
    case derived
    case documentation
}

public struct PackageInventoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String
    public var kind: PackageEntryKind

    public init(relativePath: String, byteCount: Int64, sha256: String, kind: PackageEntryKind) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.kind = kind
    }
}

public struct PackageInventory: Codable, Hashable, Sendable {
    public var schema: SchemaDescriptor
    public var packageID: UUID
    public var generatedAt: Date
    public var entries: [PackageInventoryEntry]
    public var extensions: [String: JSONValue]

    public init(packageID: UUID, entries: [PackageInventoryEntry], generatedAt: Date = Date(), extensions: [String: JSONValue] = [:]) {
        self.schema = SchemaDescriptor(name: InterviewStudioSchema.inventory)
        self.packageID = packageID
        self.generatedAt = generatedAt
        self.entries = entries.sorted { $0.relativePath < $1.relativePath }
        self.extensions = extensions
    }
}

public struct ImportedRecording: Sendable {
    public var recording: SourceRecording
    public var duplicateOf: SourceRecording?

    public init(recording: SourceRecording, duplicateOf: SourceRecording? = nil) {
        self.recording = recording
        self.duplicateOf = duplicateOf
    }
}

public struct InterviewStudioPackageStore: Sendable {
    public static let projectFilename = "interview_studio_project.json"
    public static let inventoryFilename = "package_inventory.json"
    public static let inventoryDigestFilename = "package_inventory.sha256"

    public let rootURL: URL

    private init(uncheckedRootURL: URL) {
        self.rootURL = uncheckedRootURL.standardizedFileURL
    }

    public init(rootURL: URL) throws {
        self.init(uncheckedRootURL: rootURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: self.rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InterviewStudioPackageError.invalidPackage("No project package exists at \(self.rootURL.path).")
        }
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw InterviewStudioPackageError.invalidPackage("The package is missing \(Self.projectFilename).")
        }
    }

    public var projectURL: URL { rootURL.appendingPathComponent(Self.projectFilename) }
    public var inventoryURL: URL { rootURL.appendingPathComponent(Self.inventoryFilename) }
    public var inventoryDigestURL: URL { rootURL.appendingPathComponent(Self.inventoryDigestFilename) }

    public func sessionURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func sessionJSONURL(for id: UUID) -> URL {
        sessionURL(for: id).appendingPathComponent("session.json")
    }

    public func publicationHistoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("Publication History", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    public static func create(project: InterviewStudioProject, at rootURL: URL) throws -> InterviewStudioPackageStore {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InterviewStudioPackageError.invalidPackage("The new project destination is not a directory: \(root.path)")
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.projectFilename).path) {
                throw InterviewStudioPackageError.fileExists(root)
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let store = InterviewStudioPackageStore(uncheckedRootURL: root)
        try store.prepareDirectories()
        try store.writeProject(project)
        try store.writeDocumentation()
        try store.rebuildInventory()
        return store
    }

    public func prepareDirectories() throws {
        let directories = [
            "Source Recordings",
            "Sessions",
            "Legacy Import/Original",
            "Legacy Published Media",
            "Publication History",
            "Migration History",
            "Documentation/schemas"
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    public func readProject() throws -> InterviewStudioProject {
        let project = try readJSON(InterviewStudioProject.self, from: projectURL)
        guard project.compatibility.isWritable else {
            throw InterviewStudioPackageError.incompatible(project.compatibility)
        }
        return project
    }

    public func readProjectAllowingReadOnly() throws -> InterviewStudioProject {
        try readJSON(InterviewStudioProject.self, from: projectURL)
    }

    public func writeProject(_ project: InterviewStudioProject) throws {
        guard project.compatibility.isWritable else {
            throw InterviewStudioPackageError.incompatible(project.compatibility)
        }
        try writeJSON(project, to: projectURL)
    }

    public func readSession(id: UUID) throws -> InterviewSession {
        try readJSON(InterviewSession.self, from: sessionJSONURL(for: id))
    }

    public func writeSession(_ session: InterviewSession) throws {
        guard session.compatibility.isWritable else {
            throw InterviewStudioPackageError.incompatible(session.compatibility)
        }
        try FileManager.default.createDirectory(at: sessionURL(for: session.id), withIntermediateDirectories: true)
        try writeJSON(session, to: sessionJSONURL(for: session.id))
    }

    public func listSessions() throws -> [InterviewSession] {
        let sessionsRoot = rootURL.appendingPathComponent("Sessions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return urls.filter { $0.hasDirectoryPath }.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try? readSession(id: id)
        }.sorted { ($0.ageSortValue ?? .greatestFiniteMagnitude) < ($1.ageSortValue ?? .greatestFiniteMagnitude) }
    }

    public func writePublication(_ publication: PublicationRecord) throws {
        try writeJSON(publication, to: publicationHistoryURL(for: publication.id))
    }

    public func readPublication(id: UUID) throws -> PublicationRecord {
        try readJSON(PublicationRecord.self, from: publicationHistoryURL(for: id))
    }

    public func rebuildInventory() throws {
        let entries = try inventoryEntries()
        let inventory = PackageInventory(packageID: try readProjectAllowingReadOnly().projectID, entries: entries)
        let data = try encoded(inventory)
        try writeDataAtomically(data, to: inventoryURL)
        let digest = sha256(data: data)
        try writeDataAtomically(Data((digest + "\n").utf8), to: inventoryDigestURL)
    }

    public func verifyInventory() throws {
        let inventoryData = try Data(contentsOf: inventoryURL)
        let expected = String(data: try Data(contentsOf: inventoryDigestURL), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expected == sha256(data: inventoryData) else {
            throw InterviewStudioPackageError.inventoryMismatch("The detached inventory digest does not match the inventory bytes.")
        }
        let inventory = try JSONDecoder.interviewStudio.decode(PackageInventory.self, from: inventoryData)
        let actualEntries = try inventoryEntries()
        guard actualEntries == inventory.entries.sorted(by: { $0.relativePath < $1.relativePath }) else {
            throw InterviewStudioPackageError.inventoryMismatch("The recorded entry set does not match the current package contents.")
        }
        for entry in inventory.entries {
            let url = try resolve(relativePath: entry.relativePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard byteCount == entry.byteCount else {
                throw InterviewStudioPackageError.inventoryMismatch("\(entry.relativePath) has size \(byteCount), expected \(entry.byteCount).")
            }
            guard sha256(fileURL: url) == entry.sha256 else {
                throw InterviewStudioPackageError.inventoryMismatch("\(entry.relativePath) has changed bytes.")
            }
        }
    }

    public func importRecording(
        from sourceURL: URL,
        ageKey: String,
        ageLabel: String,
        source: RecordingImportSource,
        photosLocalIdentifier: String? = nil,
        captureDate: Date? = nil,
        order: Int = 0,
        firstQuestionHint: String? = nil
    ) throws -> ImportedRecording {
        let sourceURL = sourceURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw InterviewStudioPackageError.invalidPackage("Only a readable local video file can be imported: \(sourceURL.path)")
        }

        let sourceHash = sha256(fileURL: sourceURL)
        if let duplicate = try existingRecording(withSHA256: sourceHash) {
            return ImportedRecording(recording: duplicate, duplicateOf: duplicate)
        }

        let recordingID = UUID()
        let safeAge = InterviewStudioKey.safeFilenameComponent(ageKey, fallback: "age")
        let safeFilename = InterviewStudioKey.safeFilenameComponent(sourceURL.lastPathComponent, fallback: "recording.mov")
        let relativePath = "Source Recordings/\(safeAge)/\(recordingID.uuidString)--\(safeFilename)"
        let destination = try resolve(relativePath: relativePath)
        let stagingDirectory = rootURL.appendingPathComponent("Source Recordings/.staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staged = stagingDirectory.appendingPathComponent("\(recordingID.uuidString)--\(safeFilename)")
        try FileManager.default.copyItem(at: sourceURL, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard sha256(fileURL: staged) == sourceHash else { throw InterviewStudioPackageError.checksumMismatch(sourceURL) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged, to: destination)

        var signature = MediaSignature(byteCount: fileByteCount(destination), sha256: sourceHash)
        if let inspection = try? NativeMediaInspector().inspect(url: destination) {
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
            id: recordingID,
            ageKey: ageKey,
            ageLabel: ageLabel,
            packageRelativePath: relativePath,
            originalFilename: sourceURL.lastPathComponent,
            importSource: source,
            photosLocalIdentifier: photosLocalIdentifier,
            captureDate: captureDate,
            order: order,
            firstQuestionHint: firstQuestionHint,
            mediaSignature: signature
        )
        try rebuildInventory()
        return ImportedRecording(recording: recording)
    }

    public func resolve(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw InterviewStudioPackageError.unsafeRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw InterviewStudioPackageError.unsafeRelativePath(relativePath)
        }
        let url = components.reduce(rootURL) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else {
            throw InterviewStudioPackageError.unsafeRelativePath(relativePath)
        }
        return url
    }

    private func existingRecording(withSHA256 hash: String) throws -> SourceRecording? {
        for session in try listSessions() {
            if let recording = session.recordings.first(where: { $0.mediaSignature.sha256 == hash }) {
                return recording
            }
        }
        return nil
    }

    private func inventoryEntries() throws -> [PackageInventoryEntry] {
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var entries: [PackageInventoryEntry] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { continue }
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard item.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(item.path.dropFirst(rootPrefix.count))
            guard relative != Self.inventoryFilename && relative != Self.inventoryDigestFilename else { continue }
            entries.append(PackageInventoryEntry(relativePath: relative, byteCount: fileByteCount(item), sha256: sha256(fileURL: item), kind: entryKind(for: relative)))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private func entryKind(for relativePath: String) -> PackageEntryKind {
        if relativePath.hasPrefix("Documentation/") { return .documentation }
        if relativePath.hasPrefix("Sessions/") && relativePath.hasSuffix("/session.json") { return .authoritative }
        if relativePath.hasPrefix("Source Recordings/") || relativePath == Self.projectFilename || relativePath.hasPrefix("Migration History/") { return .authoritative }
        return .derived
    }

    private func writeDocumentation() throws {
        let documentation: [(String, String)] = [
            ("Documentation/README.md", "# Yearly Interview Studio project\n\nThis package contains authoritative interview sources and document data. Generated clips and manifests are derived and may be rebuilt.\n"),
            ("Documentation/FORMAT_SPECIFICATION.md", "# Package format\n\nAuthoritative JSON uses schema version 1.0. Paths are package-relative. The inventory excludes only its own JSON and detached digest as documented self-reference exceptions.\n"),
            ("Documentation/MANIFEST_MAPPING.md", "# Manifest mapping\n\nEach completed answer maps to one Phase 1 manifest row keyed by person, question, and age. Skipped answers are omitted.\n"),
            ("Documentation/REBUILD_GUIDE.md", "# Rebuild guide\n\nUse the standalone CLI `validate-package`, then `generate-manifest` to rebuild derived Phase 1 inputs without editing JSON by hand.\n"),
            ("Documentation/CHANGELOG.md", "# Changelog\n\n- Package created with schema 1.0.\n")
        ]
        for (relative, text) in documentation {
            try writeDataAtomically(Data(text.utf8), to: try resolve(relativePath: relative))
        }
        let schemas: [(String, [String: JSONValue])] = [
            ("interview_studio_project.schema.json", ["$schema": .string("https://json-schema.org/draft/2020-12/schema"), "title": .string("Interview Studio Project"), "type": .string("object")]),
            ("interview_studio_session.schema.json", ["title": .string("Interview Studio Session"), "type": .string("object")]),
            ("publication_record.schema.json", ["title": .string("Publication Record"), "type": .string("object")]),
            ("package_inventory.schema.json", ["title": .string("Package Inventory"), "type": .string("object")]),
            ("final_manifest.schema.json", ["title": .string("Phase 1 Manifest"), "type": .string("array")])
        ]
        for (filename, object) in schemas {
            try writeJSON(object, to: try resolve(relativePath: "Documentation/schemas/\(filename)"))
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder.interviewStudio.decode(T.self, from: Data(contentsOf: url))
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try writeDataAtomically(encoded(value), to: url)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.interviewStudio.encode(value)
    }

    private func writeDataAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func fileByteCount(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value) ?? 0
    }
}

public extension JSONEncoder {
    static var interviewStudio: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var interviewStudio: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public func sha256(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func sha256(fileURL: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
    defer { try? handle.close() }
    var digest = SHA256()
    while autoreleasepool(invoking: {
        guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
        digest.update(data: chunk)
        return true
    }) {}
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
