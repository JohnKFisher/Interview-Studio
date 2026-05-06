import AppKit
import Core
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var selectedProjectFolder: URL?
    @Published var loadedProject: LoadedManifestProject?
    @Published var projectDocument: ProjectDocument?
    @Published var renderPlan: RenderPlan?
    @Published var errorMessage = ""
    @Published var isRendering = false
    @Published var renderProgress = ""
    @Published var lastRenderURL: URL?
    @Published var lastDiagnosticsURL: URL?
    @Published var previewFrames: [PreviewFrameModel] = []

    private let builder = QuestionGroupBuilder()
    private let planBuilder = RenderPlanBuilder()
    private let renderer = Renderer()
    private let previewRenderer = AppPreviewRenderer()

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
                document = existing.merged(with: loaded)
            } else {
                document = ProjectDocument.makeDefault(for: loaded)
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

    func setTransitionFrames(_ frames: Int) {
        projectDocument?.renderSettings.answerTransition.durationFrames = min(max(frames, 0), 24)
        rebuildPlanAndPersist()
    }

    func revealLastRender() {
        guard let lastRenderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRenderURL])
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
                let result = try await renderer.render(plan: renderPlan) { [weak self] state in
                    Task { @MainActor in
                        self?.renderProgress = "\(state.phase.capitalized): \(state.detail)"
                    }
                }
                await MainActor.run {
                    self.lastRenderURL = result.outputURL
                    self.lastDiagnosticsURL = result.diagnosticsURL
                    self.renderProgress = "Finished: \(result.outputURL.lastPathComponent)"
                    self.isRendering = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.renderProgress = "Render cancelled."
                    self.isRendering = false
                }
            } catch {
                await MainActor.run {
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
            previewFrames = []
            return
        }
        previewFrames = previewRenderer.buildFrames(plan: renderPlan)
    }
}
