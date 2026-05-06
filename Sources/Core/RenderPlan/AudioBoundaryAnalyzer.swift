import AVFoundation
import Foundation

public struct AudioBoundaryAnalyzer {
    private let fullCrossfadeThresholdDBFS = -30.0
    private let quietWindowThresholdDBFS = -36.0
    private let quietWindowUS: Int64 = 80_000
    private let silenceGapUS: Int64 = 80_000

    public init() {}

    public func analyze(
        from fromClip: ResolvedManifestClip,
        to toClip: ResolvedManifestClip,
        requestedDurationUS: Int64
    ) -> BoundaryTransition.AudioPlan {
        guard requestedDurationUS > 0 else {
            return .notApplicable
        }

        var reasons: [String] = []
        let handleRisk = hasHandleRisk(from: fromClip.row) || hasHandleRisk(from: toClip.row)
        if handleRisk {
            reasons.append("Handle coverage is partial or synthetic.")
        }

        do {
            let outgoingDuration = minDuration(requestedDurationUS, availableUS: fromClip.row.actualHandleAfterUS + fromClip.row.syntheticHandleAfterUS)
            let incomingDuration = minDuration(requestedDurationUS, availableUS: toClip.row.actualHandleBeforeUS + toClip.row.syntheticHandleBeforeUS)

            let outgoingMetrics = try regionMetrics(
                url: fromClip.resolvedURL,
                startSeconds: seconds(fromClip.row.answerEndInOutputUS),
                durationSeconds: seconds(outgoingDuration),
                requestedQuietWindowSeconds: seconds(min(quietWindowUS, requestedDurationUS))
            )
            let incomingMetrics = try regionMetrics(
                url: toClip.resolvedURL,
                startSeconds: max(seconds(toClip.row.answerStartInOutputUS - incomingDuration), 0),
                durationSeconds: seconds(incomingDuration),
                requestedQuietWindowSeconds: seconds(min(quietWindowUS, requestedDurationUS))
            )

            if !outgoingMetrics.hasAudio || !incomingMetrics.hasAudio {
                reasons.append("One or both clips do not provide readable audio near the transition seam.")
                return .init(
                    riskLevel: "risky",
                    mode: "silence_gap",
                    quietWindowUS: nil,
                    outgoingQuietWindowOffsetUS: nil,
                    incomingQuietWindowOffsetUS: nil,
                    silenceGapUS: min(silenceGapUS, requestedDurationUS),
                    reasons: reasons
                )
            }

            if !handleRisk,
               outgoingMetrics.averageDBFS <= fullCrossfadeThresholdDBFS,
               incomingMetrics.averageDBFS <= fullCrossfadeThresholdDBFS {
                return .init(
                    riskLevel: "safe",
                    mode: "full_crossfade",
                    quietWindowUS: nil,
                    outgoingQuietWindowOffsetUS: nil,
                    incomingQuietWindowOffsetUS: nil,
                    silenceGapUS: nil,
                    reasons: ["Nearby audio looks quiet enough for a normal crossfade."]
                )
            }

            reasons.append("Nearby audio is not quiet enough for a full handle crossfade.")

            if let outgoingWindow = outgoingMetrics.quietestWindowDBFS,
               let incomingWindow = incomingMetrics.quietestWindowDBFS,
               outgoingWindow <= quietWindowThresholdDBFS,
               incomingWindow <= quietWindowThresholdDBFS,
               let outgoingOffset = outgoingMetrics.quietestWindowOffsetUS,
               let incomingOffset = incomingMetrics.quietestWindowOffsetUS {
                return .init(
                    riskLevel: "risky",
                    mode: "quiet_window_bridge",
                    quietWindowUS: min(quietWindowUS, requestedDurationUS),
                    outgoingQuietWindowOffsetUS: outgoingOffset,
                    incomingQuietWindowOffsetUS: incomingOffset,
                    silenceGapUS: nil,
                    reasons: reasons + ["Using quieter windowed audio slices instead of the full handle audio."]
                )
            }

            return .init(
                riskLevel: "risky",
                mode: "silence_gap",
                quietWindowUS: nil,
                outgoingQuietWindowOffsetUS: nil,
                incomingQuietWindowOffsetUS: nil,
                silenceGapUS: min(silenceGapUS, requestedDurationUS),
                reasons: reasons + ["No trustworthy quiet window was found on both sides of the seam."]
            )
        } catch {
            return .init(
                riskLevel: "risky",
                mode: "silence_gap",
                quietWindowUS: nil,
                outgoingQuietWindowOffsetUS: nil,
                incomingQuietWindowOffsetUS: nil,
                silenceGapUS: min(silenceGapUS, requestedDurationUS),
                reasons: reasons + ["Audio analysis failed, so transition audio will stay conservative."]
            )
        }
    }

    private func hasHandleRisk(from row: ManifestRow) -> Bool {
        row.handleBeforeStatus != "full"
            || row.handleAfterStatus != "full"
            || row.syntheticHandleBeforeUS > 0
            || row.syntheticHandleAfterUS > 0
    }

    private func minDuration(_ requestedUS: Int64, availableUS: Int64) -> Int64 {
        max(min(requestedUS, availableUS), 0)
    }

    private func seconds(_ microseconds: Int64) -> Double {
        max(Double(microseconds) / 1_000_000, 0)
    }

    private func regionMetrics(
        url: URL,
        startSeconds: Double,
        durationSeconds: Double,
        requestedQuietWindowSeconds: Double
    ) throws -> RegionMetrics {
        guard durationSeconds > 0 else {
            return .noAudio
        }

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(startSeconds, 0) * sampleRate)
        let frameCount = AVAudioFrameCount(max(durationSeconds * sampleRate, 1))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return .noAudio
        }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)

        let availableFrames = Int(buffer.frameLength)
        guard availableFrames > 0,
              let channels = buffer.floatChannelData else {
            return .noAudio
        }

        let channelCount = Int(file.processingFormat.channelCount)
        var mono: [Float] = Array(repeating: 0, count: availableFrames)
        for frameIndex in 0 ..< availableFrames {
            var sum: Float = 0
            for channelIndex in 0 ..< channelCount {
                sum += channels[channelIndex][frameIndex]
            }
            mono[frameIndex] = sum / Float(channelCount)
        }

        let averageDBFS = dbfs(for: mono)
        let quietWindowFrames = max(Int(requestedQuietWindowSeconds * sampleRate), 1)
        guard availableFrames >= quietWindowFrames else {
            return .init(
                hasAudio: true,
                averageDBFS: averageDBFS,
                quietestWindowDBFS: averageDBFS,
                quietestWindowOffsetUS: 0
            )
        }

        let stepFrames = max(Int(0.02 * sampleRate), 1)
        var quietestDB = Double.greatestFiniteMagnitude
        var quietestOffsetUS: Int64 = 0

        var start = 0
        while start + quietWindowFrames <= availableFrames {
            let window = Array(mono[start ..< start + quietWindowFrames])
            let db = dbfs(for: window)
            if db < quietestDB {
                quietestDB = db
                quietestOffsetUS = Int64((Double(start) / sampleRate * 1_000_000).rounded())
            }
            start += stepFrames
        }

        return .init(
            hasAudio: true,
            averageDBFS: averageDBFS,
            quietestWindowDBFS: quietestDB,
            quietestWindowOffsetUS: quietestOffsetUS
        )
    }

    private func dbfs(for samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let rms = sqrt(sum / Double(samples.count))
        guard rms > 0 else { return -120 }
        return 20 * log10(rms)
    }
}

private struct RegionMetrics {
    var hasAudio: Bool
    var averageDBFS: Double
    var quietestWindowDBFS: Double?
    var quietestWindowOffsetUS: Int64?

    static let noAudio = RegionMetrics(hasAudio: false, averageDBFS: 0, quietestWindowDBFS: nil, quietestWindowOffsetUS: nil)
}
