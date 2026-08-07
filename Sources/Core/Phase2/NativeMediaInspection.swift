import AVFoundation
import CoreMedia
import Foundation

public struct NativeMediaInspection: Codable, Hashable, Sendable {
    public var url: URL
    public var duration: MediaTime
    public var width: Int
    public var height: Int
    public var nominalFrameRate: Double
    public var actualFrameRate: Double?
    public var audioChannels: Int
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorMatrix: String?
    public var hdrMetadataSummary: String?

    public init(url: URL, duration: MediaTime, width: Int, height: Int, nominalFrameRate: Double, actualFrameRate: Double? = nil, audioChannels: Int, hasVideo: Bool, hasAudio: Bool, colorPrimaries: String? = nil, colorTransfer: String? = nil, colorMatrix: String? = nil, hdrMetadataSummary: String? = nil) {
        self.url = url
        self.duration = duration
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.actualFrameRate = actualFrameRate
        self.audioChannels = audioChannels
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.colorMatrix = colorMatrix
        self.hdrMetadataSummary = hdrMetadataSummary
    }
}

public enum NativeMediaInspectionError: LocalizedError, Sendable {
    case unreadable(URL)
    case missingVideo(URL)
    case missingAudio(URL)
    case invalidDuration(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "The media cannot be opened by AVFoundation: \(url.lastPathComponent)."
        case .missingVideo(let url): return "The recording has no usable video track: \(url.lastPathComponent)."
        case .missingAudio(let url): return "The recording has no usable audio track: \(url.lastPathComponent)."
        case .invalidDuration(let url): return "The recording has no numeric duration: \(url.lastPathComponent)."
        }
    }
}

public struct NativeMediaInspector: Sendable {
    public init() {}

    public func inspect(url: URL) throws -> NativeMediaInspection {
        let asset = AVURLAsset(url: url)
        guard asset.isPlayable else { throw NativeMediaInspectionError.unreadable(url) }
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { throw NativeMediaInspectionError.missingVideo(url) }
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else { throw NativeMediaInspectionError.missingAudio(url) }
        guard asset.duration.isNumeric, asset.duration.timescale > 0 else { throw NativeMediaInspectionError.invalidDuration(url) }

        let size = videoTrack.naturalSize
        let nominalFrameRate = Double(videoTrack.nominalFrameRate)
        let audioChannels = audioTrack.formatDescriptions.compactMap { description -> Int? in
            let audioDescription = description as! CMAudioFormatDescription
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription) else { return nil }
            return Int(streamDescription.pointee.mChannelsPerFrame)
        }.first ?? 0

        let color = colorProperties(from: videoTrack.formatDescriptions.first as! CMFormatDescription)
        return NativeMediaInspection(
            url: url,
            duration: MediaTime(value: asset.duration.value, timescale: asset.duration.timescale),
            width: Int(abs(size.width.rounded())),
            height: Int(abs(size.height.rounded())),
            nominalFrameRate: nominalFrameRate,
            audioChannels: audioChannels,
            hasVideo: true,
            hasAudio: true,
            colorPrimaries: color.primaries,
            colorTransfer: color.transfer,
            colorMatrix: color.matrix,
            hdrMetadataSummary: color.hdrSummary
        )
    }

    private func colorProperties(from description: CMFormatDescription?) -> (primaries: String?, transfer: String?, matrix: String?, hdrSummary: String?) {
        guard let description, let raw = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        let primaries = raw[kCMFormatDescriptionExtension_ColorPrimaries as String].map { String(describing: $0) }
        let transfer = raw[kCMFormatDescriptionExtension_TransferFunction as String].map { String(describing: $0) }
        let matrix = raw[kCMFormatDescriptionExtension_YCbCrMatrix as String].map { String(describing: $0) }
        let hdr = raw.keys.contains { $0.localizedCaseInsensitiveContains("HDR") || $0.localizedCaseInsensitiveContains("Dolby") } ? raw.keys.sorted().joined(separator: ", ") : nil
        return (primaries, transfer, matrix, hdr)
    }
}
