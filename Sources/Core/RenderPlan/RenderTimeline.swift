import Foundation

/// The single timing grid shared by the render plan and the FFmpeg stages.
///
/// Video is the presentation clock for the locked export profile. Audio is
/// then assigned the exact number of samples represented by those video
/// frames. Keeping that conversion in one place prevents fractional
/// per-segment durations from accumulating into A/V drift at concat seams.
struct RenderTimeline: Sendable {
    let frameRate: Double
    let audioSampleRate: Int

    init(frameRate: Double, audioSampleRate: Int = 48_000) {
        self.frameRate = max(frameRate, 1)
        self.audioSampleRate = max(audioSampleRate, 1)
    }

    func duration(for durationUS: Int64) -> RenderBlockDuration {
        var cursor = Cursor(frameRate: frameRate, audioSampleRate: audioSampleRate)
        return cursor.consume(durationUS: durationUS)
    }

    func schedule(
        sequence: [RenderSequenceNode],
        boundaries: [BoundaryTransition]
    ) -> RenderTimelineSchedule {
        let boundaryLookup = Dictionary(uniqueKeysWithValues: boundaries.map { ("\($0.fromNodeID)->\($0.toNodeID)", $0) })
        var cursor = Cursor(frameRate: frameRate, audioSampleRate: audioSampleRate)
        var nodeDurations: [String: RenderBlockDuration] = [:]
        var boundaryDurations: [String: RenderBlockDuration] = [:]

        for index in sequence.indices {
            let node = sequence[index]
            nodeDurations[node.nodeID] = cursor.consume(durationUS: rawDurationUS(for: node))
            guard index < sequence.count - 1,
                  let boundary = boundaryLookup["\(node.nodeID)->\(sequence[index + 1].nodeID)"],
                  boundary.boundaryType == "answer_to_answer",
                  boundary.resolved.style == "soft_crossfade" else {
                continue
            }
            boundaryDurations[boundary.boundaryID] = cursor.consume(frameCount: boundary.resolved.durationFrames)
        }

        return RenderTimelineSchedule(
            nodeDurations: nodeDurations,
            boundaryDurations: boundaryDurations,
            total: RenderBlockDuration(
                frameCount: cursor.totalFrameCount,
                audioSampleCount: cursor.totalAudioSampleCount,
                frameRate: frameRate
            )
        )
    }

    func duration(for node: RenderSequenceNode) -> RenderBlockDuration {
        duration(for: rawDurationUS(for: node))
    }

    func duration(for boundary: BoundaryTransition) -> RenderBlockDuration {
        var cursor = Cursor(frameRate: frameRate, audioSampleRate: audioSampleRate)
        return cursor.consume(frameCount: boundary.resolved.durationFrames)
    }

    func totalDuration(
        sequence: [RenderSequenceNode],
        boundaries: [BoundaryTransition]
    ) -> RenderBlockDuration {
        schedule(sequence: sequence, boundaries: boundaries).total
    }

    private func rawDurationUS(for node: RenderSequenceNode) -> Int64 {
        if let template = node.template {
            return Int64((template.durationSeconds * 1_000_000).rounded())
        }
        return node.timing?.durationUS ?? 0
    }

    private struct Cursor {
        let frameRate: Double
        let audioSampleRate: Int
        var elapsedSeconds: Double = 0
        var frameCursor = 0
        var audioSampleCursor = 0

        var totalFrameCount: Int { frameCursor }
        var totalAudioSampleCount: Int { audioSampleCursor }

        mutating func consume(durationUS: Int64) -> RenderBlockDuration {
            let normalizedDurationUS = max(durationUS, 0)
            elapsedSeconds += Double(normalizedDurationUS) / 1_000_000
            let targetFrameCursor = Int((elapsedSeconds * frameRate).rounded())
            return allocate(frameCount: normalizedDurationUS == 0 ? 0 : max(targetFrameCursor - frameCursor, 1))
        }

        mutating func consume(frameCount: Int) -> RenderBlockDuration {
            let normalizedFrameCount = max(frameCount, 0)
            elapsedSeconds += Double(normalizedFrameCount) / frameRate
            return allocate(frameCount: normalizedFrameCount)
        }

        private mutating func allocate(frameCount: Int) -> RenderBlockDuration {
            let normalizedFrameCount = max(frameCount, 0)
            let startFrame = frameCursor
            frameCursor += normalizedFrameCount

            let startAudioSample = audioSampleCursor
            audioSampleCursor = Int((Double(frameCursor) * Double(audioSampleRate) / frameRate).rounded())
            let audioSampleCount = audioSampleCursor - startAudioSample
            return RenderBlockDuration(
                frameCount: normalizedFrameCount,
                audioSampleCount: audioSampleCount,
                frameRate: frameRate
            )
        }
    }
}

struct RenderTimelineSchedule: Sendable {
    let nodeDurations: [String: RenderBlockDuration]
    let boundaryDurations: [String: RenderBlockDuration]
    let total: RenderBlockDuration

    func duration(for node: RenderSequenceNode) -> RenderBlockDuration {
        nodeDurations[node.nodeID] ?? RenderBlockDuration(frameCount: 0, audioSampleCount: 0, frameRate: total.frameRate)
    }

    func duration(for boundary: BoundaryTransition) -> RenderBlockDuration {
        boundaryDurations[boundary.boundaryID] ?? RenderBlockDuration(frameCount: 0, audioSampleCount: 0, frameRate: total.frameRate)
    }
}

struct RenderBlockDuration: Equatable, Sendable {
    let frameCount: Int
    let audioSampleCount: Int
    let frameRate: Double

    var seconds: Double {
        Double(frameCount) / frameRate
    }

    static func + (lhs: RenderBlockDuration, rhs: RenderBlockDuration) -> RenderBlockDuration {
        precondition(lhs.frameRate == rhs.frameRate)
        return RenderBlockDuration(
            frameCount: lhs.frameCount + rhs.frameCount,
            audioSampleCount: lhs.audioSampleCount + rhs.audioSampleCount,
            frameRate: lhs.frameRate
        )
    }

    static func += (lhs: inout RenderBlockDuration, rhs: RenderBlockDuration) {
        lhs = lhs + rhs
    }
}
