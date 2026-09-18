import Foundation

public enum TransferFlavor: String, Codable, Hashable, Sendable {
    case sdr
    case hlg
    case pq
}

public struct ColorInfo: Codable, Hashable, Sendable {
    public var isHDR: Bool
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var transferFlavor: TransferFlavor
    public var isDisplayP3Like: Bool

    public init(
        isHDR: Bool,
        colorPrimaries: String?,
        transferFunction: String?,
        transferFlavor: TransferFlavor,
        isDisplayP3Like: Bool
    ) {
        self.isHDR = isHDR
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.transferFlavor = transferFlavor
        self.isDisplayP3Like = isDisplayP3Like
    }
}

public struct FFmpegBinarySet: Sendable {
    public var ffmpegURL: URL
    public var ffprobeURL: URL
    public var sourceDescription: String
}

public enum PhaseOneVideoEncoder: String, Sendable {
    case hevcVideoToolbox = "hevc_videotoolbox"
    case libx265
}

public struct FFmpegCapabilities: Sendable {
    public var hasZscale: Bool
    public var hasXfade: Bool
    public var hasAcrossfade: Bool
    public var hasOverlay: Bool
    public var hasLibx265: Bool
    public var hasHevcVideoToolbox: Bool

    public init(
        hasZscale: Bool,
        hasXfade: Bool,
        hasAcrossfade: Bool,
        hasOverlay: Bool,
        hasLibx265: Bool,
        hasHevcVideoToolbox: Bool = false
    ) {
        self.hasZscale = hasZscale
        self.hasXfade = hasXfade
        self.hasAcrossfade = hasAcrossfade
        self.hasOverlay = hasOverlay
        self.hasLibx265 = hasLibx265
        self.hasHevcVideoToolbox = hasHevcVideoToolbox
    }

    public var preferredPhaseOneVideoEncoder: PhaseOneVideoEncoder? {
        if hasHevcVideoToolbox { return .hevcVideoToolbox }
        if hasLibx265 { return .libx265 }
        return nil
    }

    public var missingPhaseOneCapabilities: [String] {
        var missing: [String] = []
        if !hasZscale { missing.append("zscale") }
        if !hasXfade { missing.append("xfade") }
        if !hasAcrossfade { missing.append("acrossfade") }
        if !hasOverlay { missing.append("overlay") }
        if preferredPhaseOneVideoEncoder == nil { missing.append("libx265 or hevc_videotoolbox") }
        return missing
    }

    public var isSufficientForPhaseOne: Bool {
        missingPhaseOneCapabilities.isEmpty
    }
}

public struct FFmpegPreflightResult: Sendable {
    public var binaries: FFmpegBinarySet
    public var capabilities: FFmpegCapabilities
}

public struct MediaInspectionResult: Sendable, Hashable {
    public var url: URL
    public var durationSeconds: Double
    public var videoDurationSeconds: Double?
    public var audioDurationSeconds: Double?
    public var videoFrameCount: Int?
    public var audioDurationTicks: Int64?
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var pixFmt: String?
    public var colorSpace: String?
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var hasAudio: Bool
    public var audioChannels: Int
    public var colorInfo: ColorInfo
    public var codecName: String?
    public var formatName: String?
    public var videoProfile: String?
    public var videoLevel: Int?
    public var videoCodecTag: String?
    public var videoTimeBase: String?
    public var sampleAspectRatio: String?
    public var audioCodecName: String?
    public var audioSampleRate: Int?
    public var audioSampleFormat: String?
    public var audioChannelLayout: String?
    public var audioTimeBase: String?
    public var streamCount: Int

    public init(
        url: URL,
        durationSeconds: Double,
        videoDurationSeconds: Double? = nil,
        audioDurationSeconds: Double? = nil,
        videoFrameCount: Int? = nil,
        audioDurationTicks: Int64? = nil,
        width: Int,
        height: Int,
        frameRate: Double,
        pixFmt: String? = nil,
        colorSpace: String? = nil,
        colorTransfer: String? = nil,
        colorPrimaries: String? = nil,
        hasAudio: Bool,
        audioChannels: Int,
        colorInfo: ColorInfo,
        codecName: String? = nil,
        formatName: String? = nil,
        videoProfile: String? = nil,
        videoLevel: Int? = nil,
        videoCodecTag: String? = nil,
        videoTimeBase: String? = nil,
        sampleAspectRatio: String? = nil,
        audioCodecName: String? = nil,
        audioSampleRate: Int? = nil,
        audioSampleFormat: String? = nil,
        audioChannelLayout: String? = nil,
        audioTimeBase: String? = nil,
        streamCount: Int = 0
    ) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.videoDurationSeconds = videoDurationSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.videoFrameCount = videoFrameCount
        self.audioDurationTicks = audioDurationTicks
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixFmt = pixFmt
        self.colorSpace = colorSpace
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.hasAudio = hasAudio
        self.audioChannels = audioChannels
        self.colorInfo = colorInfo
        self.codecName = codecName
        self.formatName = formatName
        self.videoProfile = videoProfile
        self.videoLevel = videoLevel
        self.videoCodecTag = videoCodecTag
        self.videoTimeBase = videoTimeBase
        self.sampleAspectRatio = sampleAspectRatio
        self.audioCodecName = audioCodecName
        self.audioSampleRate = audioSampleRate
        self.audioSampleFormat = audioSampleFormat
        self.audioChannelLayout = audioChannelLayout
        self.audioTimeBase = audioTimeBase
        self.streamCount = streamCount
    }
}

public enum FFmpegLocatorError: LocalizedError {
    case binariesMissing

    public var errorDescription: String? {
        "ffmpeg and ffprobe are required for rendering but could not be found in the app bundle or on PATH."
    }
}

public struct FFmpegLocator {
    public init() {}

    public func candidates(bundleResourceURL: URL? = Bundle.main.resourceURL) -> [FFmpegBinarySet] {
        var results: [FFmpegBinarySet] = []
        var seenFFmpegPaths: Set<String> = []

        func appendCandidate(ffmpegPath: String, ffprobePath: String, description: String) {
            guard !ffmpegPath.isEmpty,
                  !ffprobePath.isEmpty,
                  FileManager.default.isExecutableFile(atPath: ffmpegPath),
                  FileManager.default.isExecutableFile(atPath: ffprobePath) else {
                return
            }

            let normalizedFFmpegPath = URL(fileURLWithPath: ffmpegPath).standardizedFileURL.path
            guard seenFFmpegPaths.insert(normalizedFFmpegPath).inserted else { return }
            results.append(
                FFmpegBinarySet(
                    ffmpegURL: URL(fileURLWithPath: ffmpegPath),
                    ffprobeURL: URL(fileURLWithPath: ffprobePath),
                    sourceDescription: description
                )
            )
        }

        if let bundleResourceURL {
            let bundledTools = bundleResourceURL.appendingPathComponent("BundledTools", isDirectory: true)
            appendCandidate(
                ffmpegPath: bundledTools.appendingPathComponent("ffmpeg").path,
                ffprobePath: bundledTools.appendingPathComponent("ffprobe").path,
                description: "app bundle"
            )
        }

        let fixedCandidates: [(String, String, String)] = [
            (
                ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFMPEG"] ?? "",
                ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFPROBE"] ?? "",
                "environment override"
            ),
            ("/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe", "homebrew ffmpeg-full"),
            ("/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe", "homebrew ffmpeg"),
            ("/usr/local/bin/ffmpeg", "/usr/local/bin/ffprobe", "usr-local ffmpeg"),
            ("/opt/local/bin/ffmpeg", "/opt/local/bin/ffprobe", "MacPorts ffmpeg")
        ]

        for (ffmpegPath, ffprobePath, description) in fixedCandidates {
            appendCandidate(ffmpegPath: ffmpegPath, ffprobePath: ffprobePath, description: description)
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories {
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            appendCandidate(
                ffmpegPath: directoryURL.appendingPathComponent("ffmpeg").path,
                ffprobePath: directoryURL.appendingPathComponent("ffprobe").path,
                description: "PATH \(directory)"
            )
        }

        return results
    }

    public func locate(bundleResourceURL: URL? = Bundle.main.resourceURL) throws -> FFmpegBinarySet {
        guard let candidate = candidates(bundleResourceURL: bundleResourceURL).first else {
            throw FFmpegLocatorError.binariesMissing
        }
        return candidate
    }
}

public struct FFmpegPreflight {
    private let runner = ProcessRunner()

    public init() {}

    public func run(using binaries: FFmpegBinarySet) throws -> FFmpegPreflightResult {
        let filters = try runner.run(executableURL: binaries.ffmpegURL, arguments: ["-hide_banner", "-filters"]).stdout
        let encoders = try runner.run(executableURL: binaries.ffmpegURL, arguments: ["-hide_banner", "-encoders"]).stdout
        let normalizedFilters = filters.lowercased()
        let normalizedEncoders = encoders.lowercased()
        let capabilities = FFmpegCapabilities(
            hasZscale: normalizedFilters.contains("zscale"),
            hasXfade: normalizedFilters.contains("xfade"),
            hasAcrossfade: normalizedFilters.contains("acrossfade"),
            hasOverlay: normalizedFilters.contains("overlay"),
            hasLibx265: normalizedEncoders.contains("libx265"),
            hasHevcVideoToolbox: normalizedEncoders.contains("hevc_videotoolbox")
        )
        return FFmpegPreflightResult(binaries: binaries, capabilities: capabilities)
    }
}

public struct MediaInspector {
    private let runner = ProcessRunner()

    public init() {}

    public func inspect(url: URL, using binaries: FFmpegBinarySet) throws -> MediaInspectionResult {
        let output = try runner.run(
            executableURL: binaries.ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_streams",
                "-show_format",
                "-of", "json",
                url.path
            ]
        )

        let data = Data(output.stdout.utf8)
        let decoded = try JSONDecoder().decode(FFprobeEnvelope.self, from: data)
        guard let video = decoded.streams.first(where: { $0.codecType == "video" }) else {
            throw MediaInspectionError.missingVideo(url)
        }

        let audio = decoded.streams.first(where: { $0.codecType == "audio" })
        let frameRate = parseFrameRate(video.rFrameRate)
        let transferFlavor: TransferFlavor = {
            let transfer = (video.colorTransfer ?? "").lowercased()
            if transfer.contains("2084") || transfer.contains("pq") {
                return .pq
            }
            if transfer.contains("hlg") || transfer.contains("b67") {
                return .hlg
            }
            return .sdr
        }()

        let primaries = (video.colorPrimaries ?? "").lowercased()
        let isDisplayP3Like = primaries.contains("p3") || primaries.contains("smpte432")
        let isHDR = transferFlavor != .sdr || primaries.contains("2020") || (video.pixFmt ?? "").contains("10")

        let duration = Double(decoded.format?.duration ?? "") ?? 0
        let width = video.width ?? 0
        let height = video.height ?? 0
        guard duration.isFinite, duration > 0, width > 0, height > 0, frameRate.isFinite, frameRate > 0 else {
            throw MediaInspectionError.invalidVideoMetadata(url)
        }

        return MediaInspectionResult(
            url: url,
            durationSeconds: duration,
            videoDurationSeconds: Double(video.duration ?? ""),
            audioDurationSeconds: audio.flatMap { Double($0.duration ?? "") },
            videoFrameCount: Int(video.nbFrames ?? ""),
            audioDurationTicks: audio?.durationTS,
            width: width,
            height: height,
            frameRate: frameRate,
            pixFmt: video.pixFmt,
            colorSpace: video.colorSpace,
            colorTransfer: video.colorTransfer,
            colorPrimaries: video.colorPrimaries,
            hasAudio: audio != nil,
            audioChannels: audio?.channels ?? 0,
            colorInfo: ColorInfo(
                isHDR: isHDR,
                colorPrimaries: video.colorPrimaries,
                transferFunction: video.colorTransfer,
                transferFlavor: transferFlavor,
                isDisplayP3Like: isDisplayP3Like
            ),
            codecName: video.codecName,
            formatName: decoded.format?.formatName,
            videoProfile: video.profile,
            videoLevel: video.level,
            videoCodecTag: video.codecTagString,
            videoTimeBase: video.timeBase,
            sampleAspectRatio: video.sampleAspectRatio,
            audioCodecName: audio?.codecName,
            audioSampleRate: audio.flatMap { Int($0.sampleRate ?? "") },
            audioSampleFormat: audio?.sampleFormat,
            audioChannelLayout: audio?.channelLayout,
            audioTimeBase: audio?.timeBase,
            streamCount: decoded.streams.count
        )
    }

    private func parseFrameRate(_ value: String?) -> Double {
        guard let value, !value.isEmpty else { return 0 }
        let parts = value.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else {
            return Double(value) ?? 0
        }
        return numerator / denominator
    }
}

private struct FFprobeEnvelope: Decodable {
    struct Stream: Decodable {
        var codecType: String?
        var codecName: String?
        var width: Int?
        var height: Int?
        var pixFmt: String?
        var colorSpace: String?
        var colorTransfer: String?
        var colorPrimaries: String?
        var rFrameRate: String?
        var channels: Int?
        var profile: String?
        var level: Int?
        var codecTagString: String?
        var timeBase: String?
        var sampleAspectRatio: String?
        var sampleRate: String?
        var sampleFormat: String?
        var channelLayout: String?
        var duration: String?
        var nbFrames: String?
        var durationTS: Int64?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case width
            case height
            case pixFmt = "pix_fmt"
            case colorSpace = "color_space"
            case colorTransfer = "color_transfer"
            case colorPrimaries = "color_primaries"
            case rFrameRate = "r_frame_rate"
            case channels
            case profile
            case level
            case codecTagString = "codec_tag_string"
            case timeBase = "time_base"
            case sampleAspectRatio = "sample_aspect_ratio"
            case sampleRate = "sample_rate"
            case sampleFormat = "sample_fmt"
            case channelLayout = "channel_layout"
            case duration
            case nbFrames = "nb_frames"
            case durationTS = "duration_ts"
        }
    }

    struct Format: Decodable {
        var duration: String?
        var formatName: String?

        enum CodingKeys: String, CodingKey {
            case duration
            case formatName = "format_name"
        }
    }

    var streams: [Stream]
    var format: Format?
}


public enum MediaInspectionError: LocalizedError, Sendable {
    case missingVideo(URL)
    case invalidVideoMetadata(URL)

    public var errorDescription: String? {
        switch self {
        case .missingVideo(let url): return "ffprobe did not return a video stream for \(url.lastPathComponent)."
        case .invalidVideoMetadata(let url): return "The media has incomplete or invalid video duration, dimensions, or frame-rate metadata: \(url.lastPathComponent)."
        }
    }
}

public struct RenderOutputValidator: Sendable {
    public init() {}

    public func validate(
        _ inspection: MediaInspectionResult,
        against profile: ExportProfile,
        expectedDurationSeconds: Double? = nil,
        expectedVideoFrameCount: Int? = nil,
        expectedAudioSampleCount: Int? = nil,
        requireFinalOutputContract: Bool = false
    ) throws {
        let codec = inspection.codecName?.lowercased() ?? ""
        guard codec.contains("hevc") || codec.contains("h265") else {
            throw RenderOutputValidationError.mismatch(field: "codec", expected: "HEVC", observed: inspection.codecName ?? "missing")
        }
        guard inspection.width == profile.width, inspection.height == profile.height else {
            throw RenderOutputValidationError.mismatch(field: "dimensions", expected: "\(profile.width)x\(profile.height)", observed: "\(inspection.width)x\(inspection.height)")
        }
        let frameTolerance = max(0.5, profile.frameRate * 0.01)
        guard abs(inspection.frameRate - profile.frameRate) <= frameTolerance else {
            throw RenderOutputValidationError.mismatch(field: "frame rate", expected: "\(profile.frameRate) fps", observed: "\(inspection.frameRate) fps")
        }
        guard inspection.pixFmt?.lowercased().contains("10") == true else {
            throw RenderOutputValidationError.mismatch(field: "pixel format", expected: "10-bit", observed: inspection.pixFmt ?? "missing")
        }
        guard inspection.colorPrimaries?.lowercased().contains("2020") == true else {
            throw RenderOutputValidationError.mismatch(field: "color primaries", expected: profile.colorPrimaries, observed: inspection.colorPrimaries ?? "missing")
        }
        guard inspection.colorTransfer?.lowercased().contains("b67") == true || inspection.colorTransfer?.lowercased().contains("hlg") == true else {
            throw RenderOutputValidationError.mismatch(field: "transfer", expected: profile.colorTransfer, observed: inspection.colorTransfer ?? "missing")
        }
        guard inspection.colorSpace?.lowercased().contains("2020") == true else {
            throw RenderOutputValidationError.mismatch(field: "matrix/colorspace", expected: profile.colorMatrix, observed: inspection.colorSpace ?? "missing")
        }
        guard inspection.hasAudio, inspection.audioChannels > 0 else {
            throw RenderOutputValidationError.mismatch(field: "audio", expected: "an audio stream", observed: "missing or empty")
        }
        if let videoDuration = inspection.videoDurationSeconds,
           let audioDuration = inspection.audioDurationSeconds {
            let syncTolerance = max(1.0 / profile.frameRate, 2.0 / 48_000.0)
            guard abs(videoDuration - audioDuration) <= syncTolerance else {
                throw RenderOutputValidationError.mismatch(
                    field: "audio/video sync",
                    expected: "stream durations within \(syncTolerance) s",
                    observed: "video \(videoDuration) s, audio \(audioDuration) s"
                )
            }
        } else if requireFinalOutputContract {
            throw RenderOutputValidationError.mismatch(
                field: "audio/video sync",
                expected: "both video and audio stream durations",
                observed: "missing stream duration metadata"
            )
        }
        if let expectedVideoFrameCount {
            guard let videoFrameCount = inspection.videoFrameCount else {
                throw RenderOutputValidationError.mismatch(
                    field: "video frame count",
                    expected: String(expectedVideoFrameCount),
                    observed: "missing metadata"
                )
            }
            guard videoFrameCount == expectedVideoFrameCount else {
                throw RenderOutputValidationError.mismatch(
                    field: "video frame count",
                    expected: String(expectedVideoFrameCount),
                    observed: String(videoFrameCount)
                )
            }
        }
        if let expectedAudioSampleCount {
            guard let audioDurationTicks = inspection.audioDurationTicks,
                  inspection.audioSampleRate == 48_000 else {
                throw RenderOutputValidationError.mismatch(
                    field: "audio sample count",
                    expected: String(expectedAudioSampleCount),
                    observed: "missing 48 kHz duration ticks"
                )
            }
            guard audioDurationTicks == Int64(expectedAudioSampleCount) else {
                throw RenderOutputValidationError.mismatch(
                    field: "audio sample count",
                    expected: String(expectedAudioSampleCount),
                    observed: String(audioDurationTicks)
                )
            }
        }
        if requireFinalOutputContract {
            guard inspection.formatName?.lowercased().contains("mov") == true else {
                throw RenderOutputValidationError.mismatch(field: "container", expected: "MOV", observed: inspection.formatName ?? "missing")
            }
            guard inspection.videoCodecTag?.lowercased() == "hvc1" else {
                throw RenderOutputValidationError.mismatch(field: "video tag", expected: "hvc1", observed: inspection.videoCodecTag ?? "missing")
            }
            guard inspection.videoProfile?.lowercased().contains("main 10") == true || inspection.videoProfile?.lowercased().contains("main10") == true else {
                throw RenderOutputValidationError.mismatch(field: "video profile", expected: "HEVC Main 10", observed: inspection.videoProfile ?? "missing")
            }
            guard inspection.audioCodecName?.lowercased() == "aac" else {
                throw RenderOutputValidationError.mismatch(field: "audio codec", expected: "AAC", observed: inspection.audioCodecName ?? "missing")
            }
            guard inspection.audioSampleRate == 48_000 else {
                throw RenderOutputValidationError.mismatch(field: "audio sample rate", expected: "48000 Hz", observed: inspection.audioSampleRate.map(String.init) ?? "missing")
            }
            guard inspection.audioChannels == 2, inspection.streamCount == 2 else {
                throw RenderOutputValidationError.mismatch(field: "stream layout", expected: "one video stream and one stereo audio stream", observed: "\(inspection.streamCount) streams, \(inspection.audioChannels) audio channels")
            }
        }
        if let expectedDurationSeconds {
            let tolerance = max(0.25, 4.0 / profile.frameRate)
            guard abs(inspection.durationSeconds - expectedDurationSeconds) <= tolerance else {
                throw RenderOutputValidationError.mismatch(field: "duration", expected: "within \(tolerance) s of \(expectedDurationSeconds)", observed: "\(inspection.durationSeconds) s")
            }
        }
    }
}

public enum RenderOutputValidationError: LocalizedError, Sendable {
    case mismatch(field: String, expected: String, observed: String)

    public var errorDescription: String? {
        switch self {
        case .mismatch(let field, let expected, let observed):
            return "Rendered output validation failed for \(field): expected \(expected), observed \(observed)."
        }
    }
}
