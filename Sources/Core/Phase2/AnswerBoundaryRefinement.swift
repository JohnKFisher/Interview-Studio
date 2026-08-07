import Foundation

public struct AudioAnalysisBuffer: Sendable, Hashable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public struct SpeechActivityWindow: Sendable, Hashable {
    public var start: MediaTime
    public var end: MediaTime
    public var decibelsFS: Double
    public var isSpeech: Bool
}

public struct BoundaryRefinementResult: Sendable, Hashable {
    public var boundaries: RefinedBoundaries
    public var noiseFloorDBFS: Double
    public var speechThresholdDBFS: Double
    public var windows: [SpeechActivityWindow]
    public var needsReview: Bool

    public init(boundaries: RefinedBoundaries, noiseFloorDBFS: Double, speechThresholdDBFS: Double, windows: [SpeechActivityWindow], needsReview: Bool) {
        self.boundaries = boundaries
        self.noiseFloorDBFS = noiseFloorDBFS
        self.speechThresholdDBFS = speechThresholdDBFS
        self.windows = windows
        self.needsReview = needsReview
    }
}

public struct AnswerBoundaryRefiner: Sendable {
    public static let algorithmIdentifier = "local-vad-boundary-refiner"
    public static let algorithmVersion = "1.0"

    public init() {}

    public func refine(markers: RawAnswerMarkers, audio: AudioAnalysisBuffer, duration: MediaTime? = nil) -> BoundaryRefinementResult {
        let sampleRate = max(audio.sampleRate, 1)
        let samplesPerWindow = max(Int((sampleRate * 0.01).rounded()), 1)
        let durationUS = duration?.microseconds ?? Int64((Double(audio.samples.count) / sampleRate * 1_000_000).rounded())
        let answerStartUS = markers.answerStart?.microseconds ?? 0
        let answerEndUS = markers.answerEnd?.microseconds ?? durationUS
        let searchStartUS = max(0, answerStartUS - 2_500_000)
        let searchEndUS = min(durationUS, answerEndUS + 250_000)
        let allDecibels = stride(from: 0, to: audio.samples.count, by: samplesPerWindow).map { start -> Double in
            let end = min(start + samplesPerWindow, audio.samples.count)
            guard end > start else { return -60 }
            let rms = sqrt(audio.samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(end - start))
            return max(-120, 20 * log10(max(rms, 0.0000001)))
        }
        let localValues = allDecibels.enumerated().compactMap { index, value -> Double? in
            let startUS = Int64((Double(index * samplesPerWindow) / sampleRate * 1_000_000).rounded())
            return startUS >= searchStartUS && startUS <= searchEndUS ? value : nil
        }.sorted()
        let percentileIndex = min(max(Int(Double(max(localValues.count - 1, 0)) * 0.20), 0), max(localValues.count - 1, 0))
        let estimatedNoise = localValues.isEmpty ? -60 : localValues[percentileIndex]
        let noiseFloor = min(max(estimatedNoise, -60), -30)
        let threshold = max(noiseFloor + 12, -36)

        var candidate = allDecibels.map { $0 >= threshold }
        let sustainedWindowCount = 8
        var sustained = Array(repeating: false, count: candidate.count)
        var start = 0
        while start < candidate.count {
            guard candidate[start] else { start += 1; continue }
            var end = start
            while end < candidate.count && candidate[end] { end += 1 }
            if end - start >= sustainedWindowCount {
                for index in start..<end { sustained[index] = true }
            }
            start = end
        }
        candidate = sustained
        var index = 0
        while index < candidate.count {
            guard !candidate[index] else { index += 1; continue }
            let gapStart = index
            while index < candidate.count && !candidate[index] { index += 1 }
            let gapEnd = index
            let gapDuration = Double(gapEnd - gapStart) * 0.01
            if gapStart > 0 && gapEnd < candidate.count && gapDuration <= 0.12 {
                for gapIndex in gapStart..<gapEnd { candidate[gapIndex] = true }
            }
        }

        let bursts = makeBursts(candidate: candidate, sampleCount: samplesPerWindow, sampleRate: sampleRate, searchStartUS: searchStartUS, searchEndUS: searchEndUS)
        let answerStartBurst = bursts.first { $0.endUS >= answerStartUS && $0.startUS <= answerStartUS } ?? bursts.last { $0.startUS <= answerStartUS }
        let answerEndBurst = bursts.first { $0.startUS <= answerEndUS && $0.endUS >= answerEndUS } ?? bursts.last { $0.startUS <= answerEndUS }
        let visibleStartUS = max(0, (answerStartBurst?.startUS ?? answerStartUS) - 100_000)
        let visibleEndBase = answerEndBurst?.endUS ?? answerEndUS
        let visibleEndUS = min(durationUS, visibleEndBase + 150_000)
        let precedingBurst = bursts.last { $0.endUS <= visibleStartUS }
        let followingBurst = bursts.first { $0.startUS >= max(answerEndUS, visibleStartUS) }
        let safeLeadingStartUS = min(visibleStartUS, min(durationUS, (precedingBurst?.endUS ?? max(0, visibleStartUS - 2_000_000)) + 150_000))
        let safeTrailingEndUS: Int64
        if markers.noFollowingInterviewerSpeech {
            safeTrailingEndUS = durationUS
        } else if let interviewerResumes = markers.interviewerResumes {
            safeTrailingEndUS = max(visibleEndUS, interviewerResumes.microseconds - 150_000)
        } else if let followingBurst {
            safeTrailingEndUS = max(visibleEndUS, followingBurst.startUS - 150_000)
        } else {
            safeTrailingEndUS = durationUS
        }

        var reasons: [String] = []
        var needsReview = false
        if bursts.isEmpty {
            reasons.append("No sustained speech burst was detected.")
            needsReview = true
        }
        if answerStartBurst == nil || answerEndBurst == nil {
            reasons.append("One or more answer markers could not be matched to speech activity.")
            needsReview = true
        }
        if let interviewerResumes = markers.interviewerResumes, interviewerResumes.microseconds < visibleEndUS {
            reasons.append("The interviewer-resume marker overlaps the visible answer.")
            needsReview = true
        }
        if localValues.count < 3 {
            reasons.append("The local noise model has too little evidence.")
            needsReview = true
        }

        let confidence = needsReview ? 0.45 : 0.92
        let boundaries = RefinedBoundaries(
            visibleStart: .microseconds(visibleStartUS),
            visibleEnd: .microseconds(max(visibleStartUS, visibleEndUS)),
            safeLeadingStart: .microseconds(max(0, visibleStartUS - min(2_000_000, visibleStartUS - safeLeadingStartUS))),
            safeTrailingEnd: .microseconds(min(durationUS, max(visibleEndUS, safeTrailingEndUS))),
            confidence: confidence,
            reasons: reasons,
            algorithmIdentifier: Self.algorithmIdentifier,
            algorithmVersion: Self.algorithmVersion,
            manualOverride: false
        )
        let windows = allDecibels.enumerated().map { index, db in
            let startUS = Int64((Double(index * samplesPerWindow) / sampleRate * 1_000_000).rounded())
            return SpeechActivityWindow(start: .microseconds(startUS), end: .microseconds(min(durationUS, startUS + 10_000)), decibelsFS: db, isSpeech: candidate[index])
        }
        return BoundaryRefinementResult(boundaries: boundaries, noiseFloorDBFS: noiseFloor, speechThresholdDBFS: threshold, windows: windows, needsReview: needsReview)
    }

    private func makeBursts(candidate: [Bool], sampleCount: Int, sampleRate: Double, searchStartUS: Int64, searchEndUS: Int64) -> [(startUS: Int64, endUS: Int64)] {
        var bursts: [(Int64, Int64)] = []
        var index = 0
        while index < candidate.count {
            guard candidate[index] else { index += 1; continue }
            let start = index
            while index < candidate.count && candidate[index] { index += 1 }
            let startUS = Int64((Double(start * sampleCount) / sampleRate * 1_000_000).rounded())
            let endUS = Int64((Double(index * sampleCount) / sampleRate * 1_000_000).rounded())
            guard endUS >= searchStartUS && startUS <= searchEndUS else { continue }
            bursts.append((max(startUS, searchStartUS), min(endUS, searchEndUS)))
        }
        return bursts
    }
}
