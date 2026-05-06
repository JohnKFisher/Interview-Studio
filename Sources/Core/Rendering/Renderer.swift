import Foundation

public struct RenderJobState: Sendable {
    public var phase: String
    public var detail: String
}

public struct RenderResult: Sendable {
    public var outputURL: URL
    public var diagnosticsURL: URL
}

public enum RendererError: LocalizedError {
    case exportBlocked([AssemblyIssue])
    case missingSequenceNode(String)
    case ffmpegPreflightFailed(String)
    case outputPathUnavailable

    public var errorDescription: String? {
        switch self {
        case .exportBlocked(let issues):
            return issues.map(\.humanMessage).joined(separator: "\n")
        case .missingSequenceNode(let id):
            return "The render plan is missing a required sequence node: \(id)"
        case .ffmpegPreflightFailed(let message):
            return message
        case .outputPathUnavailable:
            return "The renderer could not determine a final output path."
        }
    }
}

public final class Renderer: @unchecked Sendable {
    private let runner = ProcessRunner()
    private let locator = FFmpegLocator()
    private let preflight = FFmpegPreflight()
    private let inspector = MediaInspector()

    public init() {}

    public func render(
        plan: RenderPlan,
        diagnosticsRoot: URL? = nil,
        outputRoot: URL? = nil,
        progress: @escaping @Sendable (RenderJobState) -> Void
    ) async throws -> RenderResult {
        let blockingIssues = plan.issues.filter { $0.severity == .blocker }
        guard blockingIssues.isEmpty else {
            throw RendererError.exportBlocked(blockingIssues)
        }

        let diagnosticsURL = try makeDiagnosticsDirectory(baseURL: diagnosticsRoot)
        let commandLogURL = diagnosticsURL.appendingPathComponent("ffmpeg_commands.txt")
        let workURL = diagnosticsURL.appendingPathComponent("work", isDirectory: true)
        let assetsURL = workURL.appendingPathComponent("assets", isDirectory: true)
        let segmentsURL = workURL.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: segmentsURL, withIntermediateDirectories: true)

        let planData = try JSONEncoder.pretty.encode(plan)
        try planData.write(to: diagnosticsURL.appendingPathComponent("render_plan.json"))

        progress(.init(phase: "preflight", detail: "Locating ffmpeg and verifying required filters/codecs."))
        let binaries = try locator.locate()
        let preflightResult = try preflight.run(using: binaries)
        guard preflightResult.capabilities.isSufficientForPhaseOne else {
            throw RendererError.ffmpegPreflightFailed("The selected ffmpeg build is missing one or more required Phase 1 capabilities (zscale, xfade, acrossfade, overlay, libx265).")
        }

        let answerNodes = plan.sequence.filter { $0.type == .answerClip }
        var inspections: [String: MediaInspectionResult] = [:]
        progress(.init(phase: "inspect", detail: "Inspecting source media and validating HDR readiness."))
        for node in answerNodes {
            try Task.checkCancellation()
            guard let clipRef = node.clipRef else { continue }
            let inspection = try inspector.inspect(url: URL(fileURLWithPath: clipRef.resolvedPath), using: binaries)
            inspections[node.nodeID] = inspection
        }

        let cardSet = BuiltInTemplates.cardSet(id: plan.settings.selectedCardSetID)
        let overlayStyle = BuiltInTemplates.overlayStyle(id: plan.settings.selectedOverlayStyleID)
        let nodeLookup = Dictionary(uniqueKeysWithValues: plan.sequence.map { ($0.nodeID, $0) })

        progress(.init(phase: "templates", detail: "Rendering native card and overlay assets."))
        let cardAssetPaths = try renderCardAssets(plan: plan, cardSet: cardSet, overlayStyle: overlayStyle, assetsURL: assetsURL)

        progress(.init(phase: "segments", detail: "Preparing answer segments, cards, and transition clips."))
        var preparedNodeSegments: [String: URL] = [:]
        for (index, node) in plan.sequence.enumerated() {
            try Task.checkCancellation()
            let previousBoundary = plan.boundaries.first(where: { $0.toNodeID == node.nodeID })
            let nextBoundary = plan.boundaries.first(where: { $0.fromNodeID == node.nodeID })
            progress(.init(phase: "segments", detail: "Encoding segment \(index + 1) of \(plan.sequence.count): \(node.nodeID)"))

            switch node.type {
            case .openingCard, .questionCard, .closingCard:
                let assetURL = cardAssetPaths[node.nodeID]!
                let outputURL = segmentsURL.appendingPathComponent("\(node.nodeID).mov")
                try renderCardSegment(
                    imageURL: assetURL,
                    node: node,
                    previousBoundary: previousBoundary,
                    nextBoundary: nextBoundary,
                    profile: plan.exportProfile,
                    binaries: binaries,
                    outputURL: outputURL,
                    commandLogURL: commandLogURL
                )
                preparedNodeSegments[node.nodeID] = outputURL
            case .answerClip:
                let outputURL = segmentsURL.appendingPathComponent("\(node.nodeID)-core.mov")
                guard let inspection = inspections[node.nodeID] else {
                    throw RendererError.missingSequenceNode(node.nodeID)
                }
                try renderAnswerCoreSegment(
                    node: node,
                    inspection: inspection,
                    overlayAssetURL: cardAssetPaths["overlay-\(node.nodeID)"],
                    previousBoundary: previousBoundary,
                    nextBoundary: nextBoundary,
                    profile: plan.exportProfile,
                    binaries: binaries,
                    outputURL: outputURL,
                    commandLogURL: commandLogURL
                )
                preparedNodeSegments[node.nodeID] = outputURL
            }
        }

        var transitionSegmentPaths: [String: URL] = [:]
        let transitionBoundaries = plan.boundaries.filter { $0.boundaryType == "answer_to_answer" && $0.resolved.style == "soft_crossfade" }
        for (index, boundary) in transitionBoundaries.enumerated() {
            try Task.checkCancellation()
            guard let fromNode = nodeLookup[boundary.fromNodeID],
                  let toNode = nodeLookup[boundary.toNodeID],
                  let fromInspection = inspections[fromNode.nodeID],
                  let toInspection = inspections[toNode.nodeID] else {
                throw RendererError.missingSequenceNode(boundary.boundaryID)
            }

            progress(.init(phase: "segments", detail: "Encoding transition \(index + 1) of \(transitionBoundaries.count): \(boundary.boundaryID)"))
            let outputURL = segmentsURL.appendingPathComponent("\(boundary.boundaryID).mov")
            try renderAnswerTransitionSegment(
                boundary: boundary,
                fromNode: fromNode,
                toNode: toNode,
                fromInspection: fromInspection,
                toInspection: toInspection,
                fromOverlayURL: cardAssetPaths["overlay-\(fromNode.nodeID)"],
                toOverlayURL: cardAssetPaths["overlay-\(toNode.nodeID)"],
                profile: plan.exportProfile,
                binaries: binaries,
                outputURL: outputURL,
                commandLogURL: commandLogURL
            )
            transitionSegmentPaths[boundary.boundaryID] = outputURL
        }

        progress(.init(phase: "assemble", detail: "Concatenating prepared segments into the final movie file."))
        let finalSegments = orderedFinalSegments(sequence: plan.sequence, boundaries: plan.boundaries, nodeSegments: preparedNodeSegments, transitionSegments: transitionSegmentPaths)
        let concatFileURL = diagnosticsURL.appendingPathComponent("concat.txt")
        let concatBody = finalSegments.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try Data(concatBody.utf8).write(to: concatFileURL)

        let outputURL = try finalOutputURL(for: plan, outputRoot: outputRoot)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: finalAssemblyArguments(
                concatFileURL: concatFileURL,
                outputURL: outputURL,
                profile: plan.exportProfile
            ),
            commandLogURL: commandLogURL
        )

        progress(.init(phase: "done", detail: "Finished rendering \(outputURL.lastPathComponent)."))
        return RenderResult(outputURL: outputURL, diagnosticsURL: diagnosticsURL)
    }

    private func orderedFinalSegments(
        sequence: [RenderSequenceNode],
        boundaries: [BoundaryTransition],
        nodeSegments: [String: URL],
        transitionSegments: [String: URL]
    ) -> [URL] {
        let boundaryLookup = Dictionary(uniqueKeysWithValues: boundaries.map { ("\($0.fromNodeID)->\($0.toNodeID)", $0) })
        var segments: [URL] = []
        for index in sequence.indices {
            let node = sequence[index]
            if let url = nodeSegments[node.nodeID] {
                segments.append(url)
            }
            guard index < sequence.count - 1 else { continue }
            let next = sequence[index + 1]
            if let boundary = boundaryLookup["\(node.nodeID)->\(next.nodeID)"],
               let transitionURL = transitionSegments[boundary.boundaryID] {
                segments.append(transitionURL)
            }
        }
        return segments
    }

    private func renderCardAssets(
        plan: RenderPlan,
        cardSet: CardSet,
        overlayStyle: OverlayStyle,
        assetsURL: URL
    ) throws -> [String: URL] {
        var results: [String: URL] = [:]
        let renderer = TemplateRenderer()
        for node in plan.sequence {
            switch node.type {
            case .openingCard, .questionCard, .closingCard:
                let url = assetsURL.appendingPathComponent("\(node.nodeID).png")
                try renderer.renderCardImage(
                    title: node.text?.title ?? node.questionText ?? "",
                    subtitle: node.text?.subtitle ?? "",
                    cardSet: cardSet,
                    profile: plan.exportProfile,
                    destinationURL: url,
                    isQuestionCard: node.type == .questionCard
                )
                results[node.nodeID] = url
            case .answerClip:
                let overlays = node.overlays
                let ageText = overlays.first(where: { $0.type == "age_overlay" })?.text ?? ""
                let questionText = overlays.first(where: { $0.type == "question_overlay" })?.text
                let showQuestion = overlays.first(where: { $0.type == "question_overlay" })?.enabled ?? false
                let url = assetsURL.appendingPathComponent("overlay-\(node.nodeID).png")
                try renderer.renderOverlayImage(
                    ageText: ageText,
                    questionText: questionText,
                    showQuestionText: showQuestion,
                    style: overlayStyle,
                    profile: plan.exportProfile,
                    destinationURL: url
                )
                results["overlay-\(node.nodeID)"] = url
            }
        }
        return results
    }

    private func renderCardSegment(
        imageURL: URL,
        node: RenderSequenceNode,
        previousBoundary: BoundaryTransition?,
        nextBoundary: BoundaryTransition?,
        profile: ExportProfile,
        binaries: FFmpegBinarySet,
        outputURL: URL,
        commandLogURL: URL
    ) throws {
        let duration = node.template?.durationSeconds ?? 2.0
        let fadeIn = previousBoundary?.resolved.style == "fade_through_black" ? Double(previousBoundary?.resolved.durationFrames ?? 0) / profile.frameRate : 0
        let fadeOut = nextBoundary?.resolved.style == "fade_through_black" ? Double(nextBoundary?.resolved.durationFrames ?? 0) / profile.frameRate : 0

        var videoFilter = [
            "format=rgba",
            "fps=\(format(profile.frameRate))",
            sdrGraphicNormalizeFilter(profile: profile),
            "scale=\(profile.width):\(profile.height):flags=lanczos",
            "setsar=1"
        ]
        if fadeIn > 0 {
            videoFilter.append("fade=t=in:st=0:d=\(format(fadeIn)):color=black")
        }
        if fadeOut > 0 {
            videoFilter.append("fade=t=out:st=\(format(max(duration - fadeOut, 0))):d=\(format(fadeOut)):color=black")
        }

        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: segmentEncodeArguments(
                inputs: [
                    ["-loop", "1", "-framerate", format(profile.frameRate), "-i", imageURL.path],
                    ["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"]
                ],
                filterComplex: "[0:v]\(videoFilter.joined(separator: ","))[v];[1:a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[a]",
                mapVideo: "[v]",
                mapAudio: "[a]",
                outputURL: outputURL,
                profile: profile
            ),
            commandLogURL: commandLogURL
        )
    }

    private func renderAnswerCoreSegment(
        node: RenderSequenceNode,
        inspection: MediaInspectionResult,
        overlayAssetURL: URL?,
        previousBoundary: BoundaryTransition?,
        nextBoundary: BoundaryTransition?,
        profile: ExportProfile,
        binaries: FFmpegBinarySet,
        outputURL: URL,
        commandLogURL: URL
    ) throws {
        guard let clipRef = node.clipRef, let timing = node.timing else {
            throw RendererError.missingSequenceNode(node.nodeID)
        }

        let duration = max(Double(timing.durationUS) / 1_000_000, 0.05)
        let start = max(Double(timing.answerStartInOutputUS) / 1_000_000, 0)
        let audioFilter = baseAudioFilter(
            start: start,
            duration: duration,
            loudnessMatch: node.audio?.loudnessMatch ?? true,
            targetLUFS: node.audio?.targetLUFS ?? -16,
            truePeak: node.audio?.truePeakCeilingDBTP ?? -1
        )

        var videoChain = [
            "trim=start=\(format(start)):duration=\(format(duration))",
            "setpts=PTS-STARTPTS",
            "fps=\(format(profile.frameRate))",
            colorNormalizeFilter(for: inspection.colorInfo, profile: profile),
            scalePadFilter(profile: profile),
            "setsar=1"
        ]

        if let previousBoundary, previousBoundary.resolved.style == "fade_through_black" {
            let fadeIn = Double(previousBoundary.resolved.durationFrames) / profile.frameRate
            videoChain.append("fade=t=in:st=0:d=\(format(fadeIn)):color=black")
        }
        if let nextBoundary, nextBoundary.resolved.style == "fade_through_black" {
            let fadeOut = Double(nextBoundary.resolved.durationFrames) / profile.frameRate
            videoChain.append("fade=t=out:st=\(format(max(duration - fadeOut, 0))):d=\(format(fadeOut)):color=black")
        }

        var inputs: [[String]] = [["-i", clipRef.resolvedPath]]
        var filterComplex = "[0:v]\(videoChain.joined(separator: ","))[v0];"
        if inspection.hasAudio {
            filterComplex += "[0:a]\(audioFilter)[a0];"
        } else {
            inputs.append(["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"])
            filterComplex += "[1:a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[a0];"
        }

        var videoMap = "[v0]"
        if let overlayAssetURL {
            inputs.append(["-loop", "1", "-framerate", format(profile.frameRate), "-i", overlayAssetURL.path])
            let overlayIndex = inputs.count - 1
            filterComplex += "[\(overlayIndex):v]format=rgba[ov];[v0][ov]overlay=0:0:format=auto[v1]"
            videoMap = "[v1]"
        } else {
            filterComplex.removeLast()
        }

        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: segmentEncodeArguments(
                inputs: inputs,
                filterComplex: filterComplex,
                mapVideo: videoMap,
                mapAudio: "[a0]",
                outputURL: outputURL,
                profile: profile
            ),
            commandLogURL: commandLogURL
        )
    }

    private func renderAnswerTransitionSegment(
        boundary: BoundaryTransition,
        fromNode: RenderSequenceNode,
        toNode: RenderSequenceNode,
        fromInspection: MediaInspectionResult,
        toInspection: MediaInspectionResult,
        fromOverlayURL: URL?,
        toOverlayURL: URL?,
        profile: ExportProfile,
        binaries: FFmpegBinarySet,
        outputURL: URL,
        commandLogURL: URL
    ) throws {
        guard let fromClipRef = fromNode.clipRef,
              let toClipRef = toNode.clipRef,
              let fromTiming = fromNode.timing,
              let toTiming = toNode.timing else {
            throw RendererError.missingSequenceNode(boundary.boundaryID)
        }

        let duration = Double(boundary.requested.durationUS) / 1_000_000
        let outgoingAvailable = max(Double(boundary.availability.outgoingRealHandleAfterUS) / 1_000_000, 0)
        let incomingAvailable = max(Double(boundary.availability.incomingRealHandleBeforeUS) / 1_000_000, 0)

        let outgoingMissing = max(duration - outgoingAvailable, 0)
        let incomingMissing = max(duration - incomingAvailable, 0)
        let outgoingTrimDuration = max(min(duration, outgoingAvailable), 0.01)
        let incomingTrimDuration = max(min(duration, incomingAvailable), 0.01)
        let outgoingStart = Double(fromTiming.answerEndInOutputUS) / 1_000_000
        let incomingStart = max(Double(toTiming.answerStartInOutputUS) / 1_000_000 - incomingTrimDuration, 0)

        var inputs: [[String]] = [
            ["-i", fromClipRef.resolvedPath],
            ["-i", toClipRef.resolvedPath]
        ]

        var filterParts: [String] = []

        var fromVideo = "[0:v]trim=start=\(format(outgoingStart)):duration=\(format(outgoingTrimDuration)),setpts=PTS-STARTPTS,fps=\(format(profile.frameRate)),\(colorNormalizeFilter(for: fromInspection.colorInfo, profile: profile)),\(scalePadFilter(profile: profile)),setsar=1"
        if outgoingMissing > 0 {
            fromVideo += ",tpad=stop_mode=clone:stop_duration=\(format(outgoingMissing))"
        }
        filterParts.append("\(fromVideo)[fv0]")

        var toVideo = "[1:v]trim=start=\(format(incomingStart)):duration=\(format(incomingTrimDuration)),setpts=PTS-STARTPTS,fps=\(format(profile.frameRate)),\(colorNormalizeFilter(for: toInspection.colorInfo, profile: profile)),\(scalePadFilter(profile: profile)),setsar=1"
        if incomingMissing > 0 {
            toVideo += ",tpad=start_mode=clone:start_duration=\(format(incomingMissing))"
        }
        filterParts.append("\(toVideo)[tv0]")

        var fromVideoMap = "fv0"
        if let fromOverlayURL {
            inputs.append(["-loop", "1", "-framerate", format(profile.frameRate), "-i", fromOverlayURL.path])
            let index = inputs.count - 1
            filterParts.append("[\(index):v]format=rgba[fov]")
            filterParts.append("[fv0][fov]overlay=0:0:format=auto[fv1]")
            fromVideoMap = "fv1"
        }

        var toVideoMap = "tv0"
        if let toOverlayURL {
            inputs.append(["-loop", "1", "-framerate", format(profile.frameRate), "-i", toOverlayURL.path])
            let index = inputs.count - 1
            filterParts.append("[\(index):v]format=rgba[tov]")
            filterParts.append("[tv0][tov]overlay=0:0:format=auto[tv1]")
            toVideoMap = "tv1"
        }

        filterParts.append("[\(fromVideoMap)][\(toVideoMap)]xfade=transition=fade:duration=\(format(duration)):offset=0[vout]")

        switch boundary.audio.mode {
        case "quiet_window_bridge":
            let quietDuration = max(Double(boundary.audio.quietWindowUS ?? 0) / 1_000_000, min(duration / 2, 0.04))
            let outgoingQuietOffset = Double(boundary.audio.outgoingQuietWindowOffsetUS ?? 0) / 1_000_000
            let incomingQuietOffset = Double(boundary.audio.incomingQuietWindowOffsetUS ?? 0) / 1_000_000
            let bridgeDelay = max(duration - quietDuration, 0)

            if fromInspection.hasAudio {
                let fromAudio = "[0:a]\(baseAudioFilter(start: outgoingStart + outgoingQuietOffset, duration: quietDuration, loudnessMatch: fromNode.audio?.loudnessMatch ?? true, targetLUFS: fromNode.audio?.targetLUFS ?? -16, truePeak: fromNode.audio?.truePeakCeilingDBTP ?? -1)),afade=t=out:st=0:d=\(format(quietDuration)),apad=whole_dur=\(format(duration)),atrim=duration=\(format(duration))"
                filterParts.append("\(fromAudio)[fa0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[fa0]")
            }

            if toInspection.hasAudio {
                let toAudio = "[1:a]\(baseAudioFilter(start: incomingStart + incomingQuietOffset, duration: quietDuration, loudnessMatch: toNode.audio?.loudnessMatch ?? true, targetLUFS: toNode.audio?.targetLUFS ?? -16, truePeak: toNode.audio?.truePeakCeilingDBTP ?? -1)),afade=t=in:st=0:d=\(format(quietDuration)),adelay=\(Int((bridgeDelay * 1000).rounded()))|\(Int((bridgeDelay * 1000).rounded())),apad=whole_dur=\(format(duration)),atrim=duration=\(format(duration))"
                filterParts.append("\(toAudio)[ta0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[ta0]")
            }

            filterParts.append("[fa0][ta0]amix=inputs=2:normalize=0:duration=longest[aout]")
        case "silence_gap":
            inputs.append(["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"])
            let silenceIndex = inputs.count - 1
            filterParts.append("[\(silenceIndex):a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[aout]")
        default:
            if fromInspection.hasAudio {
                var fromAudio = "[0:a]\(baseAudioFilter(start: outgoingStart, duration: outgoingTrimDuration, loudnessMatch: fromNode.audio?.loudnessMatch ?? true, targetLUFS: fromNode.audio?.targetLUFS ?? -16, truePeak: fromNode.audio?.truePeakCeilingDBTP ?? -1))"
                if outgoingMissing > 0 {
                    fromAudio += ",apad=whole_dur=\(format(duration)),atrim=duration=\(format(duration))"
                }
                filterParts.append("\(fromAudio)[fa0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[fa0]")
            }

            if toInspection.hasAudio {
                var toAudio = "[1:a]\(baseAudioFilter(start: incomingStart, duration: incomingTrimDuration, loudnessMatch: toNode.audio?.loudnessMatch ?? true, targetLUFS: toNode.audio?.targetLUFS ?? -16, truePeak: toNode.audio?.truePeakCeilingDBTP ?? -1))"
                if incomingMissing > 0 {
                    let delayMS = Int((incomingMissing * 1000).rounded())
                    toAudio += ",adelay=\(delayMS)|\(delayMS)"
                }
                toAudio += ",apad=whole_dur=\(format(duration)),atrim=duration=\(format(duration))"
                filterParts.append("\(toAudio)[ta0]")
            } else {
                inputs.append(["-f", "lavfi", "-t", format(duration), "-i", "anullsrc=r=48000:cl=stereo"])
                let index = inputs.count - 1
                filterParts.append("[\(index):a]atrim=duration=\(format(duration)),asetpts=PTS-STARTPTS[ta0]")
            }

            filterParts.append("[fa0][ta0]acrossfade=d=\(format(duration)):c1=tri:c2=tri[aout]")
        }

        try runner.run(
            executableURL: binaries.ffmpegURL,
            arguments: segmentEncodeArguments(
                inputs: inputs,
                filterComplex: filterParts.joined(separator: ";"),
                mapVideo: "[vout]",
                mapAudio: "[aout]",
                outputURL: outputURL,
                profile: profile
            ),
            commandLogURL: commandLogURL
        )
    }

    private func segmentEncodeArguments(
        inputs: [[String]],
        filterComplex: String,
        mapVideo: String,
        mapAudio: String,
        outputURL: URL,
        profile: ExportProfile
    ) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        for input in inputs {
            args.append(contentsOf: input)
        }
        args.append(contentsOf: [
            "-filter_complex", filterComplex,
            "-map", mapVideo,
            "-map", mapAudio,
            "-c:v", "prores_ks",
            "-profile:v", "3",
            "-pix_fmt", "yuv422p10le",
            "-vendor", "apl0",
            "-c:a", "pcm_s16le",
            "-ar", "48000",
            "-ac", "2",
            "-shortest",
            "-colorspace", profile.colorMatrix,
            "-color_primaries", profile.colorPrimaries,
            "-color_trc", profile.colorTransfer,
            outputURL.path
        ])
        return args
    }

    private func finalAssemblyArguments(
        concatFileURL: URL,
        outputURL: URL,
        profile: ExportProfile
    ) -> [String] {
        [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", concatFileURL.path,
            "-c:v", "libx265",
            "-preset", "faster",
            "-crf", "18",
            "-pix_fmt", "yuv420p10le",
            "-tag:v", "hvc1",
            "-x265-params", "repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", "2",
            "-movflags", "+faststart",
            "-colorspace", profile.colorMatrix,
            "-color_primaries", profile.colorPrimaries,
            "-color_trc", profile.colorTransfer,
            outputURL.path
        ]
    }

    private func baseAudioFilter(start: Double, duration: Double, loudnessMatch: Bool, targetLUFS: Double, truePeak: Double) -> String {
        var parts = [
            "atrim=start=\(format(start)):duration=\(format(duration))",
            "asetpts=PTS-STARTPTS",
            "aresample=48000",
            "aformat=sample_fmts=fltp:channel_layouts=stereo"
        ]
        if loudnessMatch {
            parts.append("loudnorm=I=\(format(targetLUFS)):TP=\(format(truePeak)):LRA=11:linear=true")
        }
        return parts.joined(separator: ",")
    }

    private func colorNormalizeFilter(for colorInfo: ColorInfo, profile: ExportProfile) -> String {
        switch colorInfo.transferFlavor {
        case .hlg:
            return "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix)"
        case .pq:
            return "zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix)"
        case .sdr:
            let transferIn = (colorInfo.transferFunction ?? "").lowercased().contains("iec61966") ? "iec61966-2-1" : "bt709"
            let primariesIn = colorInfo.isDisplayP3Like ? "smpte432" : "bt709"
            return "colorspace=iall=bt709:all=bt709:fast=1,zscale=transferin=\(transferIn):primariesin=\(primariesIn):matrixin=bt709:transfer=linear,format=gbrpf32le,zscale=transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix):range=tv:npl=400,eq=contrast=1.08"
        }
    }

    private func sdrGraphicNormalizeFilter(profile: ExportProfile) -> String {
        "zscale=transferin=iec61966-2-1:primariesin=bt709:matrixin=bt709:transfer=linear,format=gbrpf32le,zscale=transfer=\(profile.colorTransfer):primaries=\(profile.colorPrimaries):matrix=\(profile.colorMatrix):range=tv:npl=400,eq=contrast=1.04"
    }

    private func scalePadFilter(profile: ExportProfile) -> String {
        "scale=w=\(profile.width):h=\(profile.height):force_original_aspect_ratio=decrease:flags=lanczos,pad=\(profile.width):\(profile.height):(ow-iw)/2:(oh-ih)/2:black"
    }

    private func makeDiagnosticsDirectory(baseURL: URL?) throws -> URL {
        let base = baseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yearly Interview Studio/Diagnostics", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = base.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func finalOutputURL(for plan: RenderPlan, outputRoot: URL?) throws -> URL {
        let root = outputRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Yearly Interview Studio/\(plan.project.projectName)", isDirectory: true)
        let sanitizedBase = sanitizeFilename(plan.project.projectName)
        let defaultURL = root.appendingPathComponent("\(sanitizedBase).\(plan.exportProfile.containerExtension)")
        if !FileManager.default.fileExists(atPath: defaultURL.path) {
            return defaultURL
        }

        let stamp = DateFormatter.outputTimestamp.string(from: Date())
        return root.appendingPathComponent("\(sanitizedBase)-\(stamp).\(plan.exportProfile.containerExtension)")
    }

    private func sanitizeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension DateFormatter {
    static let outputTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private func format(_ value: Double) -> String {
    String(format: "%.6f", value)
}
