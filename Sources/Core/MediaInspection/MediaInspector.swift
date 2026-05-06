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

public struct FFmpegCapabilities: Sendable {
    public var hasZscale: Bool
    public var hasXfade: Bool
    public var hasAcrossfade: Bool
    public var hasOverlay: Bool
    public var hasLibx265: Bool

    public var isSufficientForPhaseOne: Bool {
        hasZscale && hasXfade && hasAcrossfade && hasOverlay && hasLibx265
    }
}

public struct FFmpegPreflightResult: Sendable {
    public var binaries: FFmpegBinarySet
    public var capabilities: FFmpegCapabilities
}

public struct MediaInspectionResult: Sendable, Hashable {
    public var url: URL
    public var durationSeconds: Double
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
}

public enum FFmpegLocatorError: LocalizedError {
    case binariesMissing

    public var errorDescription: String? {
        "ffmpeg and ffprobe are required for rendering but could not be found in the app bundle or on PATH."
    }
}

public struct FFmpegLocator {
    public init() {}

    public func locate(bundleResourceURL: URL? = Bundle.main.resourceURL) throws -> FFmpegBinarySet {
        if let bundleResourceURL {
            let bundledTools = bundleResourceURL.appendingPathComponent("BundledTools", isDirectory: true)
            let bundledFFmpeg = bundledTools.appendingPathComponent("ffmpeg")
            let bundledFFprobe = bundledTools.appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: bundledFFmpeg.path),
               FileManager.default.isExecutableFile(atPath: bundledFFprobe.path) {
                return FFmpegBinarySet(ffmpegURL: bundledFFmpeg, ffprobeURL: bundledFFprobe, sourceDescription: "app bundle")
            }
        }

        let candidates: [(String, String, String)] = [
            (
                ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFMPEG"] ?? "",
                ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFPROBE"] ?? "",
                "environment override"
            ),
            ("/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe", "homebrew ffmpeg-full"),
            ("/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe", "homebrew ffmpeg")
        ]

        for (ffmpegPath, ffprobePath, description) in candidates where !ffmpegPath.isEmpty && !ffprobePath.isEmpty {
            if FileManager.default.isExecutableFile(atPath: ffmpegPath),
               FileManager.default.isExecutableFile(atPath: ffprobePath) {
                return FFmpegBinarySet(
                    ffmpegURL: URL(fileURLWithPath: ffmpegPath),
                    ffprobeURL: URL(fileURLWithPath: ffprobePath),
                    sourceDescription: description
                )
            }
        }

        throw FFmpegLocatorError.binariesMissing
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
            hasLibx265: normalizedEncoders.contains("libx265")
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
            throw ManifestParserError.invalidJSON("ffprobe did not return a video stream for \(url.lastPathComponent).")
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

        return MediaInspectionResult(
            url: url,
            durationSeconds: Double(decoded.format?.duration ?? "") ?? 0,
            width: video.width ?? 0,
            height: video.height ?? 0,
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
            )
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
        var width: Int?
        var height: Int?
        var pixFmt: String?
        var colorSpace: String?
        var colorTransfer: String?
        var colorPrimaries: String?
        var rFrameRate: String?
        var channels: Int?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case width
            case height
            case pixFmt = "pix_fmt"
            case colorSpace = "color_space"
            case colorTransfer = "color_transfer"
            case colorPrimaries = "color_primaries"
            case rFrameRate = "r_frame_rate"
            case channels
        }
    }

    struct Format: Decodable {
        var duration: String?
    }

    var streams: [Stream]
    var format: Format?
}
