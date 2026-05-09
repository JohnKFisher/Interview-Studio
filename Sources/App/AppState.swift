import AppKit
import Core
import Foundation

@MainActor
final class AppState: ObservableObject {
    private enum AppPreferenceKey {
        static let lastPlexShow = "lastPlexShow"
        static let lastPlexSeason = "lastPlexSeason"
    }

    @Published var selectedProjectFolder: URL?
    @Published var loadedProject: LoadedManifestProject?
    @Published var projectDocument: ProjectDocument?
    @Published var renderPlan: RenderPlan?
    @Published var errorMessage = ""
    @Published var isRendering = false
    @Published var renderProgress = ""
    @Published var lastRenderURL: URL?
    @Published var lastPlexOutputURL: URL?
    @Published var lastDiagnosticsURL: URL?
    @Published var keepSuccessfulDiagnostics = false
    @Published var previewFrames: [PreviewFrameModel] = []

    private let builder = QuestionGroupBuilder()
    private let planBuilder = RenderPlanBuilder()
    private let renderer = Renderer()
    private let previewRenderer = AppPreviewRenderer()
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project Folder"
        panel.message = "Choose the export folder that contains final_manifest.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(at: url)
    }

    func loadProject(at folderURL: URL) {
        do {
            let manifestURL = try resolveManifestURL(in: folderURL)
            let loaded = try builder.loadProject(manifestURL: manifestURL, projectFolder: folderURL)
            let sidecarURL = ProjectDocument.sidecarURL(for: manifestURL)
            let document: ProjectDocument
            if let existing = try? JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: sidecarURL)) {
                document = hydratedDocumentDefaults(existing.merged(with: loaded), loadedProject: loaded)
            } else {
                document = hydratedDocumentDefaults(ProjectDocument.makeDefault(for: loaded), loadedProject: loaded)
            }

            selectedProjectFolder = folderURL
            loadedProject = loaded
            projectDocument = document
            rebuildPlanAndPersist()
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateOpeningTitle(_ value: String) {
        projectDocument?.openingTitle = value
        rebuildPlanAndPersist()
    }

    func updateClosingTitle(_ value: String) {
        projectDocument?.closingTitle = value
        rebuildPlanAndPersist()
    }

    func setTitleCaseQuestions(_ enabled: Bool) {
        projectDocument?.titleCaseQuestions = enabled
        rebuildPlanAndPersist()
    }

    func updateQuestionText(for key: String, value: String) {
        projectDocument?.questionDisplayTexts[key] = value
        rebuildPlanAndPersist()
    }

    func moveQuestionUp(_ key: String) {
        guard var order = projectDocument?.questionOrder, let index = order.firstIndex(of: key), index > 0 else { return }
        order.swapAt(index, index - 1)
        projectDocument?.questionOrder = order
        rebuildPlanAndPersist()
    }

    func moveQuestionDown(_ key: String) {
        guard var order = projectDocument?.questionOrder, let index = order.firstIndex(of: key), index < order.count - 1 else { return }
        order.swapAt(index, index + 1)
        projectDocument?.questionOrder = order
        rebuildPlanAndPersist()
    }

    func setCardSet(id: String) {
        projectDocument?.renderSettings.selectedCardSetID = id
        rebuildPlanAndPersist()
    }

    func setOverlayStyle(id: String) {
        projectDocument?.renderSettings.selectedOverlayStyleID = id
        rebuildPlanAndPersist()
    }

    func setShowQuestionOverlay(_ enabled: Bool) {
        projectDocument?.renderSettings.overlays.showQuestionOverlay = enabled
        rebuildPlanAndPersist()
    }

    func setGentleLoudnessMatch(_ enabled: Bool) {
        projectDocument?.renderSettings.audio.gentleLoudnessMatch = enabled
        rebuildPlanAndPersist()
    }

    func setPlexCompanionEnabled(_ enabled: Bool) {
        projectDocument?.plexMetadata.isEnabled = enabled
        rebuildPlanAndPersist()
    }

    func updatePlexShow(_ value: String) {
        projectDocument?.plexMetadata.show = value
        persistPlexDefaults(show: value, season: projectDocument?.plexMetadata.season ?? "")
        rebuildPlanAndPersist()
    }

    func updatePlexSeason(_ value: String) {
        projectDocument?.plexMetadata.season = value
        persistPlexDefaults(show: projectDocument?.plexMetadata.show ?? "", season: value)
        rebuildPlanAndPersist()
    }

    func updatePlexEpisode(_ value: String) {
        projectDocument?.plexMetadata.episode = value
        rebuildPlanAndPersist()
    }

    func updatePlexEpisodeTitle(_ value: String) {
        projectDocument?.plexMetadata.episodeTitle = value
        rebuildPlanAndPersist()
    }

    func updatePlexSummary(_ value: String) {
        projectDocument?.plexMetadata.summary = value
        rebuildPlanAndPersist()
    }

    func setTransitionFrames(_ frames: Int) {
        projectDocument?.renderSettings.answerTransition.durationFrames = min(max(frames, 0), 24)
        rebuildPlanAndPersist()
    }

    func revealLastRender() {
        guard let lastRenderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRenderURL])
    }

    func revealLastPlexRender() {
        guard let lastPlexOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastPlexOutputURL])
    }

    func revealDiagnostics() {
        guard let lastDiagnosticsURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastDiagnosticsURL])
    }

    func renderMovie() {
        guard let renderPlan else { return }
        isRendering = true
        renderProgress = "Starting render…"
        errorMessage = ""

        Task {
            do {
                let result = try await renderer.render(plan: renderPlan, keepSuccessfulDiagnostics: keepSuccessfulDiagnostics) { [weak self] state in
                    Task { @MainActor in
                        self?.renderProgress = "\(state.phase.capitalized): \(state.detail)"
                    }
                }
                await MainActor.run {
                    self.lastRenderURL = result.outputURL
                    self.lastPlexOutputURL = result.plexOutputURL
                    self.lastDiagnosticsURL = result.diagnosticsURL
                    if let plexOutputURL = result.plexOutputURL {
                        self.renderProgress = "Finished: \(result.outputURL.lastPathComponent) and \(plexOutputURL.lastPathComponent)"
                    } else {
                        self.renderProgress = "Finished: \(result.outputURL.lastPathComponent)"
                    }
                    self.isRendering = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.renderProgress = "Render cancelled."
                    self.isRendering = false
                }
            } catch {
                await MainActor.run {
                    if let rendererError = error as? RendererError,
                       case .renderFailed(_, let diagnosticsURL) = rendererError {
                        self.lastDiagnosticsURL = diagnosticsURL
                    }
                    self.errorMessage = error.localizedDescription
                    self.renderProgress = "Render failed."
                    self.isRendering = false
                }
            }
        }
    }

    private func rebuildPlanAndPersist() {
        guard let loadedProject, let projectDocument else { return }
        renderPlan = planBuilder.build(project: loadedProject, document: projectDocument)
        persistSidecar()
        refreshPreviews()
    }

    private func persistSidecar() {
        guard let loadedProject, let projectDocument else { return }
        let sidecarURL = ProjectDocument.sidecarURL(for: loadedProject.manifestURL)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(projectDocument).write(to: sidecarURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveManifestURL(in folderURL: URL) throws -> URL {
        let direct = folderURL.appendingPathComponent("final_manifest.json")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        let jsonFiles = ((try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "json" }) ?? []
        if jsonFiles.count == 1, let only = jsonFiles.first {
            return only
        }

        throw ManifestParserError.invalidJSON("Could not auto-detect final_manifest.json inside \(folderURL.lastPathComponent).")
    }

    private func refreshPreviews() {
        guard let renderPlan else {
            previewTask?.cancel()
            previewFrames = []
            return
        }

        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        previewFrames = previewRenderer.seededFrames(for: renderPlan, existing: previewFrames)
        let frameIDs = previewFrames.map(\.id)

        previewTask = Task { [previewRenderer] in
            for frameID in frameIDs {
                if Task.isCancelled { return }
                do {
                    let renderedFrame = try await previewRenderer.renderFrame(id: frameID, plan: renderPlan)
                    await MainActor.run {
                        guard generation == self.previewGeneration else { return }
                        self.replacePreviewFrame(renderedFrame)
                    }
                } catch {
                    await MainActor.run {
                        guard generation == self.previewGeneration else { return }
                        self.markPreviewFrameFailed(id: frameID, message: error.localizedDescription)
                    }
                }
                await Task.yield()
            }
        }
    }

    private func replacePreviewFrame(_ frame: PreviewFrameModel) {
        guard let index = previewFrames.firstIndex(where: { $0.id == frame.id }) else { return }
        previewFrames[index] = frame
    }

    private func markPreviewFrameFailed(id: String, message: String) {
        guard let index = previewFrames.firstIndex(where: { $0.id == id }) else { return }
        let frame = previewFrames[index]
        previewFrames[index] = PreviewFrameModel(
            id: frame.id,
            title: frame.title,
            subtitle: frame.subtitle,
            image: frame.image,
            status: .failed(message)
        )
    }

    private func hydratedDocumentDefaults(_ document: ProjectDocument, loadedProject: LoadedManifestProject) -> ProjectDocument {
        var copy = document
        if copy.plexMetadata.show.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.plexMetadata.show = UserDefaults.standard.string(forKey: AppPreferenceKey.lastPlexShow) ?? ""
        }
        if copy.plexMetadata.season.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.plexMetadata.season = UserDefaults.standard.string(forKey: AppPreferenceKey.lastPlexSeason) ?? ""
        }
        if copy.plexMetadata.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.plexMetadata.episodeTitle = defaultPlexEpisodeTitle(for: copy)
        }
        if copy.plexMetadata.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.plexMetadata.summary = defaultPlexSummary(for: copy, loadedProject: loadedProject)
        }
        if copy.plexMetadata.show.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.plexMetadata.show = loadedProject.personName
        }
        return copy
    }

    private func defaultPlexEpisodeTitle(for document: ProjectDocument) -> String {
        let openingTitle = document.openingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openingTitle.isEmpty {
            return openingTitle
        }
        return document.projectName
    }

    private func defaultPlexSummary(for document: ProjectDocument, loadedProject: LoadedManifestProject) -> String {
        "\(document.projectName) is a yearly interview compilation for \(loadedProject.personName), assembled in Yearly Interview Studio."
    }

    private func persistPlexDefaults(show: String, season: String) {
        let trimmedShow = show.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSeason = season.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedShow.isEmpty {
            UserDefaults.standard.set(trimmedShow, forKey: AppPreferenceKey.lastPlexShow)
        }
        if !trimmedSeason.isEmpty {
            UserDefaults.standard.set(trimmedSeason, forKey: AppPreferenceKey.lastPlexSeason)
        }
    }
}
