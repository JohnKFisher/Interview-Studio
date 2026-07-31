import Core
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button("Choose Project Folder") {
                    appState.chooseProjectFolder()
                }
                .buttonStyle(.borderedProminent)

                if let folder = appState.selectedProjectFolder {
                    Text("Project Folder: \(folder.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !appState.errorMessage.isEmpty {
                    Text(appState.errorMessage)
                        .foregroundStyle(.red)
                }

                if let project = appState.loadedProject {
                    projectHeader(project)
                }

                if let renderPlan = appState.renderPlan,
                   let projectDocument = appState.projectDocument {
                    assemblyControls(projectDocument: projectDocument)
                    plexMetadataSection(projectDocument: projectDocument)
                    previewSection()
                    questionOrder(projectDocument: projectDocument)
                    renderStatus(renderPlan: renderPlan)
                    renderActions(renderPlan: renderPlan)
                } else {
                    ContentUnavailableView("No Project Loaded", systemImage: "film.stack", description: Text("Choose a project folder to build a render plan."))
                }
            }
            .padding(20)
        }
        .frame(minWidth: 1360, minHeight: 940)
        .alert(
            "Interview Studio Warning",
            isPresented: Binding(
                get: { !appState.errorMessage.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        appState.errorMessage = ""
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage)
        }
    }

    private func projectHeader(_ project: LoadedManifestProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.projectName)
                .font(.title.bold())
            Text("Person: \(project.personName)")
            Text("Manifest: \(project.manifestURL.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func assemblyControls(projectDocument: ProjectDocument) -> some View {
        GroupBox("Assembly Controls") {
            VStack(alignment: .leading, spacing: 12) {
                TextField(
                    "Opening Title",
                    text: Binding(
                        get: { projectDocument.openingTitle },
                        set: { appState.updateOpeningTitle($0) }
                    )
                )
                TextField(
                    "Closing Title",
                    text: Binding(
                        get: { projectDocument.closingTitle },
                        set: { appState.updateClosingTitle($0) }
                    )
                )

                HStack(spacing: 16) {
                    Picker(
                        "Card Set",
                        selection: Binding(
                            get: { projectDocument.renderSettings.selectedCardSetID },
                            set: { appState.setCardSet(id: $0) }
                        )
                    ) {
                        ForEach(BuiltInTemplates.cardSets) { cardSet in
                            Text(cardSet.name).tag(cardSet.id)
                        }
                    }

                    Picker(
                        "Overlay Style",
                        selection: Binding(
                            get: { projectDocument.renderSettings.selectedOverlayStyleID },
                            set: { appState.setOverlayStyle(id: $0) }
                        )
                    ) {
                        ForEach(BuiltInTemplates.overlayStyles) { overlayStyle in
                            Text(overlayStyle.name).tag(overlayStyle.id)
                        }
                    }
                }

                HStack(spacing: 20) {
                    Toggle(
                        "Show Question Overlay",
                        isOn: Binding(
                            get: { projectDocument.renderSettings.overlays.showQuestionOverlay },
                            set: { appState.setShowQuestionOverlay($0) }
                        )
                    )
                    Toggle(
                        "Gentle Loudness Match",
                        isOn: Binding(
                            get: { projectDocument.renderSettings.audio.gentleLoudnessMatch },
                            set: { appState.setGentleLoudnessMatch($0) }
                        )
                    )
                }

                HStack(spacing: 20) {
                    Toggle(
                        "Title Case Questions",
                        isOn: Binding(
                            get: { projectDocument.titleCaseQuestions },
                            set: { appState.setTitleCaseQuestions($0) }
                        )
                    )
                    Toggle(
                        "Generate Plex Companion",
                        isOn: Binding(
                            get: { projectDocument.plexMetadata.isEnabled },
                            set: { appState.setPlexCompanionEnabled($0) }
                        )
                    )
                }

                Stepper(
                    "Answer Transition: \(projectDocument.renderSettings.answerTransition.durationFrames) frames",
                    value: Binding(
                        get: { projectDocument.renderSettings.answerTransition.durationFrames },
                        set: { appState.setTransitionFrames($0) }
                    ),
                    in: 0 ... 24
                )
            }
        }
    }

    private func plexMetadataSection(projectDocument: ProjectDocument) -> some View {
        GroupBox("Plex Metadata") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The export still produces the HDR MOV master first. When enabled, it also packages a TV-style Plex MP4 companion with chapters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    TextField(
                        "Show",
                        text: Binding(
                            get: { projectDocument.plexMetadata.show },
                            set: { appState.updatePlexShow($0) }
                        )
                    )

                    TextField(
                        "Season",
                        text: Binding(
                            get: { projectDocument.plexMetadata.season },
                            set: { appState.updatePlexSeason($0) }
                        )
                    )
                    .frame(width: 120)

                    TextField(
                        "Episode",
                        text: Binding(
                            get: { projectDocument.plexMetadata.episode },
                            set: { appState.updatePlexEpisode($0) }
                        )
                    )
                    .frame(width: 120)
                }

                TextField(
                    "Episode Title",
                    text: Binding(
                        get: { projectDocument.plexMetadata.episodeTitle },
                        set: { appState.updatePlexEpisodeTitle($0) }
                    )
                )

                TextField(
                    "Summary",
                    text: Binding(
                        get: { projectDocument.plexMetadata.summary },
                        set: { appState.updatePlexSummary($0) }
                    ),
                    axis: .vertical
                )
                .lineLimit(3 ... 5)
            }
            .disabled(!projectDocument.plexMetadata.isEnabled)
        }
    }

    private func previewSection() -> some View {
        GroupBox("Live Preview") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current project data drives these frames, so long questions and overlay choices show their real layout risk before a full render.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if appState.previewFrames.isEmpty {
                    Text("Preview frames will appear here once the render plan is ready.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(appState.previewFrames) { frame in
                                PreviewFrameCard(frame: frame)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func questionOrder(projectDocument: ProjectDocument) -> some View {
        GroupBox("Question Order") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(projectDocument.questionOrder, id: \.self) { key in
                    HStack(spacing: 10) {
                        TextField(
                            key,
                            text: Binding(
                                get: { projectDocument.questionDisplayTexts[key] ?? key },
                                set: { appState.updateQuestionText(for: key, value: $0) }
                            )
                        )
                        Button("Up") {
                            appState.moveQuestionUp(key)
                        }
                        .buttonStyle(.bordered)
                        Button("Down") {
                            appState.moveQuestionDown(key)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func renderStatus(renderPlan: RenderPlan) -> some View {
        GroupBox("Render Status") {
            VStack(alignment: .leading, spacing: 8) {
                Text(renderPlan.summary.exportAllowed ? "Ready to Export" : "Blocked")
                    .font(.headline)
                    .foregroundStyle(renderPlan.summary.exportAllowed ? .green : .orange)
                Text("Questions: \(renderPlan.summary.questionCount)")
                Text("Answer Clips: \(renderPlan.summary.answerClipCount)")
                Text("Warnings: \(renderPlan.summary.warningCount)")
                Text("Blockers: \(renderPlan.summary.blockerCount)")
                Text(String(format: "Estimated Runtime: %.1fs", renderPlan.summary.estimatedRuntimeSeconds))
                Text("Transitions: \(renderPlan.summary.transitionCounts.realHandleCrossfade) real, \(renderPlan.summary.transitionCounts.syntheticCrossfade) synthetic, \(renderPlan.summary.transitionCounts.cleanCutFallback) cut fallback")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Open Sequence") {
                        openWindow(id: StudioWindowID.sequence)
                    }
                    .buttonStyle(.bordered)

                    Button("Open Issues") {
                        openWindow(id: StudioWindowID.issues)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func renderActions(renderPlan: RenderPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Render Final Movie") {
                    appState.renderMovie()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!renderPlan.summary.exportAllowed || appState.isRendering)

                Button("Reveal Last Render") {
                    appState.revealLastRender()
                }
                .disabled(appState.lastRenderURL == nil)

                Button("Reveal Plex Companion") {
                    appState.revealLastPlexRender()
                }
                .disabled(appState.lastPlexOutputURL == nil)

                Button("Reveal Diagnostics") {
                    appState.revealDiagnostics()
                }
                .disabled(appState.lastDiagnosticsURL == nil)
            }

            Toggle("Keep diagnostics for this render", isOn: $appState.keepSuccessfulDiagnostics)

            if appState.isRendering {
                ProgressView()
            }
            if !appState.renderProgress.isEmpty {
                Text(appState.renderProgress)
                    .font(.subheadline)
            }
        }
    }
}

private struct PreviewFrameCard: View {
    let frame: PreviewFrameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 320, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                statusChip
                    .padding(10)
            }

            Text(frame.title)
                .font(.headline)
            Text(frame.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private var statusChip: some View {
        switch frame.status {
        case .loading:
            Label("Refreshing", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        case .ready:
            EmptyView()
        case .failed:
            Label("Preview failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.red.opacity(0.85), in: Capsule())
        }
    }
}
