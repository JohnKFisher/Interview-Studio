@testable import Core
import XCTest

private final class HeartbeatRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    func record(_ value: TimeInterval) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

final class RendererTests: XCTestCase {
    func testProcessRunnerEmitsHeartbeatsForLongRunningCommands() throws {
        let recorder = HeartbeatRecorder()

        _ = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.2"],
            heartbeatInterval: 0.05,
            heartbeat: { recorder.record($0) }
        )

        XCTAssertGreaterThanOrEqual(recorder.count, 2)
    }

    func testProcessRunnerStopsTimedOutCommands() throws {
        XCTAssertThrowsError(
            try ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 5"],
                timeout: 0.15
            )
        ) { error in
            guard case let ProcessRunnerError.timedOut(command, timeout, _) = error else {
                return XCTFail("Expected a bounded timeout, got \(error)")
            }
            XCTAssertTrue(command.contains("arguments redacted"))
            XCTAssertEqual(timeout, 0.15, accuracy: 0.001)
        }
    }

    func testRenderOutputValidatorRejectsWrongCodecAndAcceptsProtectedProfile() throws {
        let base = MediaInspectionResult(
            url: URL(fileURLWithPath: "/tmp/output.mov"),
            durationSeconds: 10,
            width: 640,
            height: 360,
            frameRate: 30,
            pixFmt: "yuv420p10le",
            colorSpace: "bt2020nc",
            colorTransfer: "arib-std-b67",
            colorPrimaries: "bt2020",
            hasAudio: true,
            audioChannels: 2,
            colorInfo: ColorInfo(isHDR: true, colorPrimaries: "bt2020", transferFunction: "arib-std-b67", transferFlavor: .hlg, isDisplayP3Like: false),
            codecName: "hevc",
            formatName: "mov",
            videoProfile: "Main 10",
            videoLevel: 153,
            videoCodecTag: "hvc1",
            videoTimeBase: "1/30",
            sampleAspectRatio: "1:1",
            audioCodecName: "aac",
            audioSampleRate: 48_000,
            audioSampleFormat: "fltp",
            audioChannelLayout: "stereo",
            audioTimeBase: "1/48000",
            streamCount: 2
        )
        XCTAssertNoThrow(try RenderOutputValidator().validate(base, against: .rendererTest, expectedDurationSeconds: 10))

        var shortened = base
        shortened.durationSeconds = 9.5
        XCTAssertThrowsError(
            try RenderOutputValidator().validate(shortened, against: .rendererTest, expectedDurationSeconds: 10)
        ) { error in
            guard case let RenderOutputValidationError.mismatch(field, _, _) = error else {
                return XCTFail("Expected a duration validation failure, got \(error)")
            }
            XCTAssertEqual(field, "duration")
        }

        var wrongCodec = base
        wrongCodec.codecName = "h264"
        XCTAssertThrowsError(try RenderOutputValidator().validate(wrongCodec, against: .rendererTest))
    }

    func testChunkingPolicyFlushesBeforeProjectedOverflow() {
        let policy = RenderChunkingPolicy(targetDurationSeconds: 60)

        XCTAssertFalse(policy.shouldStartNewChunk(currentDuration: 50, nextGroupDuration: 10))
        XCTAssertTrue(policy.shouldStartNewChunk(currentDuration: 50, nextGroupDuration: 11))
        XCTAssertFalse(policy.shouldStartNewChunk(currentDuration: 0, nextGroupDuration: 120))
    }

    func testChunkStreamSignatureRejectsFixedStreamParameterDrift() {
        let base = MediaInspectionResult(
            url: URL(fileURLWithPath: "/tmp/chunk.mov"),
            durationSeconds: 10,
            width: 640,
            height: 360,
            frameRate: 30,
            pixFmt: "yuv420p10le",
            colorSpace: "bt2020nc",
            colorTransfer: "arib-std-b67",
            colorPrimaries: "bt2020",
            hasAudio: true,
            audioChannels: 2,
            colorInfo: ColorInfo(isHDR: true, colorPrimaries: "bt2020", transferFunction: "arib-std-b67", transferFlavor: .hlg, isDisplayP3Like: false),
            codecName: "hevc",
            formatName: "mov",
            videoProfile: "Main 10",
            videoLevel: 153,
            videoCodecTag: "hvc1",
            videoTimeBase: "1/30",
            sampleAspectRatio: "1:1",
            audioCodecName: "pcm_s16le",
            audioSampleRate: 48_000,
            audioSampleFormat: "s16",
            audioChannelLayout: "stereo",
            audioTimeBase: "1/48000",
            streamCount: 2
        )
        var drifted = base
        drifted.audioSampleRate = 44_100

        XCTAssertEqual(ChunkStreamSignature(inspection: base), ChunkStreamSignature(inspection: base))
        XCTAssertNotEqual(ChunkStreamSignature(inspection: base), ChunkStreamSignature(inspection: drifted))
    }

    func testRenderTimelineUsesOneAudioSampleClockForEveryVideoFrame() {
        let timeline = RenderTimeline(frameRate: 30)
        let duration = timeline.duration(for: 1_750_000)

        XCTAssertEqual(duration.frameCount, 53)
        XCTAssertEqual(duration.audioSampleCount, 84_800)
        XCTAssertEqual(duration.seconds, 53.0 / 30.0, accuracy: 0.0000001)

        var total = RenderBlockDuration(frameCount: 0, audioSampleCount: 0, frameRate: 30)
        for _ in 0 ..< 136 {
            total += timeline.duration(for: 1_013_000)
        }
        XCTAssertEqual(Double(total.frameCount) / 30.0, Double(total.audioSampleCount) / 48_000.0, accuracy: 0.0000001)
    }

    func testRenderTimelineUsesCumulativeFrameRoundingAcrossManyBlocks() {
        let nodes = (0 ..< 136).map { index in
            RenderSequenceNode(
                nodeID: "node-\(index)",
                type: .questionCard,
                text: nil,
                template: .init(templateID: "test", durationSeconds: 1.013, durationSource: "test"),
                questionKey: nil,
                questionText: nil,
                clipRef: nil,
                identity: nil,
                timing: nil,
                handles: nil,
                video: nil,
                overlays: [],
                audio: nil,
                confidence: nil,
                issues: []
            )
        }

        let schedule = RenderTimeline(frameRate: 30).schedule(sequence: nodes, boundaries: [])
        XCTAssertEqual(schedule.total.seconds, 136 * 1.013, accuracy: 1.0 / 30.0)
        XCTAssertEqual(schedule.total.frameCount, nodes.reduce(0) { $0 + schedule.duration(for: $1).frameCount })
        XCTAssertEqual(schedule.total.audioSampleCount, nodes.reduce(0) { $0 + schedule.duration(for: $1).audioSampleCount })
    }

    func testRenderTimelinePreservesResolvedTransitionFrameCounts() throws {
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        let plan = RenderPlanBuilder().build(project: loaded, document: ProjectDocument.makeDefault(for: loaded), exportProfile: .rendererTest)
        let boundary = try XCTUnwrap(plan.boundaries.first(where: { $0.boundaryType == "answer_to_answer" }))
        let schedule = RenderTimeline(frameRate: plan.exportProfile.frameRate).schedule(sequence: plan.sequence, boundaries: plan.boundaries)
        let duration = schedule.duration(for: boundary)

        XCTAssertEqual(duration.frameCount, boundary.resolved.durationFrames)
        XCTAssertEqual(duration.audioSampleCount, Int((Double(duration.frameCount) * 48_000 / plan.exportProfile.frameRate).rounded()))
    }

    func testRenderOutputValidatorRejectsStreamDurationDrift() throws {
        let base = MediaInspectionResult(
            url: URL(fileURLWithPath: "/tmp/output.mov"),
            durationSeconds: 10,
            videoDurationSeconds: 10,
            audioDurationSeconds: 9.5,
            width: 640,
            height: 360,
            frameRate: 30,
            pixFmt: "yuv420p10le",
            colorSpace: "bt2020nc",
            colorTransfer: "arib-std-b67",
            colorPrimaries: "bt2020",
            hasAudio: true,
            audioChannels: 2,
            colorInfo: ColorInfo(isHDR: true, colorPrimaries: "bt2020", transferFunction: "arib-std-b67", transferFlavor: .hlg, isDisplayP3Like: false),
            codecName: "hevc",
            formatName: "mov",
            videoProfile: "Main 10",
            videoLevel: 153,
            videoCodecTag: "hvc1",
            videoTimeBase: "1/30",
            sampleAspectRatio: "1:1",
            audioCodecName: "aac",
            audioSampleRate: 48_000,
            audioSampleFormat: "fltp",
            audioChannelLayout: "stereo",
            audioTimeBase: "1/48000",
            streamCount: 2
        )

        XCTAssertThrowsError(try RenderOutputValidator().validate(base, against: .rendererTest)) { error in
            guard case let RenderOutputValidationError.mismatch(field, _, _) = error else {
                return XCTFail("Expected a stream sync validation failure, got \(error)")
            }
            XCTAssertEqual(field, "audio/video sync")
        }
    }

    func testRendererProducesPlayableMovie() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RENDERER_SMOKE_TESTS"] == "1" else {
            throw XCTSkip("Renderer smoke test is opt-in because it depends on the local ffmpeg toolchain and GUI template rendering support.")
        }
        let workspace = try TestWorkspace.make()
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        var document = ProjectDocument.makeDefault(for: loaded)
        document.plexMetadata.show = "Family Interviews"
        document.plexMetadata.season = "2026"
        document.plexMetadata.episode = "3"
        document.plexMetadata.episodeTitle = document.openingTitle
        document.plexMetadata.summary = "Renderer smoke"
        let plan = RenderPlanBuilder().build(project: loaded, document: document, exportProfile: .rendererTest)

        let renderer = Renderer(chunkDurationLimitSeconds: 1)
        let outputRoot = workspace.rootURL.appendingPathComponent("Output", isDirectory: true)
        let diagnosticsRoot = workspace.rootURL.appendingPathComponent("Diagnostics", isDirectory: true)
        let result = try await renderer.render(plan: plan, diagnosticsRoot: diagnosticsRoot, outputRoot: outputRoot, keepSuccessfulDiagnostics: true) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int64 ?? 0, 0)
        let plexOutputURL = try XCTUnwrap(result.plexOutputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plexOutputURL.path))
        XCTAssertNotNil(result.diagnosticsURL)

        let ffprobePath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFPROBE"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe"
        let ffprobeOutput = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_chapters",
                plexOutputURL.path
            ]
        )

        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ffprobeOutput.stdout.utf8)) as? [String: Any])
        let format = try XCTUnwrap(metadata["format"] as? [String: Any])
        let tags = try XCTUnwrap(format["tags"] as? [String: Any])
        XCTAssertEqual(tags["title"] as? String, document.plexMetadata.episodeTitle)
        XCTAssertEqual(tags["show"] as? String, document.plexMetadata.show)
        XCTAssertEqual(tags["date"] as? String, document.plexMetadata.season)
        XCTAssertFalse((tags["creation_time"] as? String ?? "").isEmpty)

        let chapters = metadata["chapters"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(chapters.count, 2)

        let outputMetadata = try ffprobeObject(arguments: ["-show_streams"], url: result.outputURL)
        let outputStreams = try XCTUnwrap(outputMetadata["streams"] as? [[String: Any]])
        let videoStream = try XCTUnwrap(outputStreams.first(where: { $0["codec_type"] as? String == "video" }))
        let audioStream = try XCTUnwrap(outputStreams.first(where: { $0["codec_type"] as? String == "audio" }))
        let videoFrames = try XCTUnwrap(Int(try XCTUnwrap(videoStream["nb_frames"] as? String)))
        let videoDuration = try XCTUnwrap(Double(try XCTUnwrap(videoStream["duration"] as? String)))
        let audioDuration = try XCTUnwrap(Double(try XCTUnwrap(audioStream["duration"] as? String)))
        XCTAssertEqual(videoDuration, Double(videoFrames) / 30.0, accuracy: 0.0001)
        XCTAssertEqual(videoDuration, audioDuration, accuracy: 0.0001)

        let audioFrames = try ffprobeFrames(
            streamSpecifier: "a:0",
            entries: "frame=best_effort_timestamp_time,nb_samples",
            url: result.outputURL
        )
        XCTAssertGreaterThan(audioFrames.count, 2)
        for index in 1..<audioFrames.count {
            let previous = try XCTUnwrap(audioFrames[index - 1])
            let current = try XCTUnwrap(audioFrames[index])
            let previousPTSString = try XCTUnwrap(previous["best_effort_timestamp_time"] as? String)
            let currentPTSString = try XCTUnwrap(current["best_effort_timestamp_time"] as? String)
            let previousPTS = try XCTUnwrap(Double(previousPTSString))
            let currentPTS = try XCTUnwrap(Double(currentPTSString))
            let previousSamples = try XCTUnwrap(previous["nb_samples"] as? Int)
            let expectedPTS = previousPTS + Double(previousSamples) / 48_000
            XCTAssertLessThan(abs(currentPTS - expectedPTS), 0.0001, "Audio timestamp gap or overlap at frame \(index).")
        }
    }

    private func ffprobeFrames(streamSpecifier: String, entries: String, url: URL) throws -> [[String: Any]] {
        let ffprobePath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFPROBE"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe"
        let output = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: [
                "-v", "error",
                "-select_streams", streamSpecifier,
                "-show_frames",
                "-show_entries", entries,
                "-of", "json",
                url.path
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        return object["frames"] as? [[String: Any]] ?? []
    }

    private func ffprobeObject(arguments: [String], url: URL) throws -> [String: Any] {
        let ffprobePath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFPROBE"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe"
        let output = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: ffprobePath),
            arguments: ["-v", "error"] + arguments + ["-of", "json", url.path]
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    }

    func testFailedRenderDiagnosticsExcludeGeneratedMedia() async throws {
        let workspace = try TestWorkspace.make()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let loaded = try QuestionGroupBuilder().loadProject(manifestURL: workspace.manifestURL, projectFolder: workspace.rootURL)
        var document = ProjectDocument.makeDefault(for: loaded)
        document.plexMetadata.show = "Family Interviews"
        document.plexMetadata.season = "2026"
        document.plexMetadata.episode = "3"
        document.plexMetadata.episodeTitle = document.openingTitle
        document.plexMetadata.summary = "Renderer failure diagnostics"
        var plan = RenderPlanBuilder().build(project: loaded, document: document, exportProfile: .rendererTest)
        let answerIndex = try XCTUnwrap(plan.sequence.firstIndex(where: { $0.type == .answerClip }))
        plan.sequence[answerIndex].clipRef?.resolvedPath = workspace.rootURL.appendingPathComponent("missing-source.mov").path

        let diagnosticsRoot = workspace.rootURL.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            _ = try await Renderer().render(plan: plan, diagnosticsRoot: diagnosticsRoot, outputRoot: workspace.rootURL.appendingPathComponent("Output", isDirectory: true)) { _ in }
            XCTFail("The render should fail for a missing source recording.")
        } catch {
            // The failure is expected; the assertions below inspect its small
            // persisted diagnostic bundle.
        }

        let diagnosticRun = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: diagnosticsRoot, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticRun.appendingPathComponent("render_plan.json").path))
        let failureURL = diagnosticRun.appendingPathComponent("render_failure.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureURL.path))
        let failureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: failureURL)) as? [String: Any]
        )
        XCTAssertEqual(failureObject["error_category"] as? String, "ffmpeg_process_failure")
        XCTAssertFalse((failureObject["next_action"] as? String ?? "").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticRun.appendingPathComponent("work").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticRun.appendingPathComponent("segments").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticRun.appendingPathComponent("assets").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnosticRun.appendingPathComponent("concat.txt").path))
        let diagnosticSize = FileManager.default.enumerator(at: diagnosticRun, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { item -> Int64? in
            guard let url = item as? URL else { return nil }
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }.reduce(0, +) ?? 0
        XCTAssertLessThan(diagnosticSize, 1_000_000)
    }
}
