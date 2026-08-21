import AVFoundation
import Core
import Foundation
import Speech
import SwiftUI

struct WaveformData: Sendable, Hashable {
    let peaks: [Float]
    let durationUS: Int64
}

struct SelectedTimelineRange: Sendable, Hashable {
    let durationUS: Int64
    let visibleStartUS: Int64
    let visibleEndUS: Int64
    let safeLeadingStartUS: Int64?
    let safeTrailingEndUS: Int64?

    var hasPreciseBuffers: Bool { safeLeadingStartUS != nil && safeTrailingEndUS != nil }
}

enum MediaAnalysisError: LocalizedError, Sendable {
    case unreadableAudio(URL)
    case emptyAudio(URL)
    case missingAudio(URL)
    case conversionFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let url):
            return "The audio track could not be analyzed: \(url.lastPathComponent)."
        case .emptyAudio(let url):
            return "The audio track contains no readable samples: \(url.lastPathComponent)."
        case .missingAudio(let url):
            return "The recording has no audio track: \(url.lastPathComponent)."
        case .conversionFailed(let url, let message):
            return "The recording's audio could not be prepared: \(url.lastPathComponent) (\(message))"
        }
    }
}

struct MediaAudioExtractor: Sendable {
    func extract(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard asset.tracks(withMediaType: .audio).first != nil else {
            throw MediaAnalysisError.missingAudio(url)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewStudio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaAnalysisError.conversionFailed(url, "No compatible audio export is available")
        }
        exporter.shouldOptimizeForNetworkUse = false

        do {
            try await exporter.export(to: outputURL, as: .m4a)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaAnalysisError.conversionFailed(url, error.localizedDescription)
        }
    }
}

struct AudioWaveformAnalyzer: Sendable {
    func analyze(url: URL, bucketCount: Int = 240) async throws -> WaveformData {
        let audioURL = try await MediaAudioExtractor().extract(from: url)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            let sampleRate = file.processingFormat.sampleRate
            let totalFrames = Int(file.length)
            let channelCount = Int(file.processingFormat.channelCount)
            guard totalFrames > 0, sampleRate > 0, channelCount > 0 else {
                throw MediaAnalysisError.emptyAudio(url)
            }

            let bucketCount = max(bucketCount, 1)
            let frameCapacity: AVAudioFrameCount = 4_096
            var peaks = Array(repeating: Float.zero, count: bucketCount)
            var frameOffset = 0

            while frameOffset < totalFrames {
                let framesToRead = min(Int(frameCapacity), totalFrames - frameOffset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(framesToRead)) else {
                    throw MediaAnalysisError.unreadableAudio(url)
                }
                try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
                guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
                    frameOffset += framesToRead
                    continue
                }

                for frameIndex in 0 ..< Int(buffer.frameLength) {
                    var sum: Float = 0
                    for channelIndex in 0 ..< channelCount {
                        sum += channels[channelIndex][frameIndex]
                    }
                    let amplitude = abs(sum / Float(channelCount))
                    let absoluteFrame = frameOffset + frameIndex
                    let bucket = min(Int(Double(absoluteFrame) / Double(totalFrames) * Double(bucketCount)), bucketCount - 1)
                    peaks[bucket] = max(peaks[bucket], amplitude)
                }
                frameOffset += Int(buffer.frameLength)
            }

            let maximum = max(peaks.max() ?? 0, 0.0001)
            return WaveformData(
                peaks: peaks.map { min($0 / maximum, 1) },
                durationUS: Int64((Double(totalFrames) / sampleRate * 1_000_000).rounded())
            )
        } catch let error as MediaAnalysisError {
            throw error
        } catch {
            throw MediaAnalysisError.unreadableAudio(url)
        }
    }
}

enum SpeechTranscriptionError: LocalizedError, Sendable {
    case unavailable
    case permissionDenied
    case permissionRestricted
    case onDeviceUnavailable(String)
    case emptyResult
    case recognitionFailed(String)

    var stopsBatch: Bool {
        switch self {
        case .unavailable, .permissionDenied, .permissionRestricted, .onDeviceUnavailable:
            return true
        case .emptyResult, .recognitionFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech recognition is not currently available on this Mac."
        case .permissionDenied:
            return "Speech recognition permission was denied. Enable it in System Settings to transcribe recordings."
        case .permissionRestricted:
            return "Speech recognition is restricted on this Mac."
        case .onDeviceUnavailable(let localeIdentifier):
            return "On-device speech recognition is unavailable for \(localeIdentifier)."
        case .emptyResult:
            return "No speech was recognized in this recording."
        case .recognitionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

@MainActor
final class SpeechTranscriptionService {
    func transcribe(url: URL, sourceRecordingID: UUID, localeIdentifier: String) async throws -> AnswerTranscript {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw SpeechTranscriptionError.unavailable
        }
        guard recognizer.isAvailable else {
            throw SpeechTranscriptionError.unavailable
        }

        let authorization = await authorizationStatus()
        switch authorization {
        case .authorized:
            break
        case .denied:
            throw SpeechTranscriptionError.permissionDenied
        case .restricted:
            throw SpeechTranscriptionError.permissionRestricted
        case .notDetermined:
            throw SpeechTranscriptionError.permissionDenied
        @unknown default:
            throw SpeechTranscriptionError.permissionDenied
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscriptionError.onDeviceUnavailable(localeIdentifier)
        }

        let audioURL = try await MediaAudioExtractor().extract(from: url)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        recognizer.queue = .main

        return try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState()
            recognizer.recognitionTask(with: request) { result, error in
                guard !state.finished else { return }
                if let error {
                    state.finished = true
                    continuation.resume(throwing: SpeechTranscriptionError.recognitionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }

                let transcription = result.bestTranscription
                let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    state.finished = true
                    continuation.resume(throwing: SpeechTranscriptionError.emptyResult)
                    return
                }

                let segments = transcription.segments.map { segment in
                    TranscriptSegment(
                        text: segment.substring,
                        start: .microseconds(Int64((segment.timestamp * 1_000_000).rounded())),
                        end: .microseconds(Int64(((segment.timestamp + segment.duration) * 1_000_000).rounded()))
                    )
                }
                state.finished = true
                continuation.resume(returning: AnswerTranscript(
                    text: text,
                    segments: segments,
                    localeIdentifier: localeIdentifier,
                    sourceRecordingID: sourceRecordingID
                ))
            }
        }
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    continuation.resume(returning: status)
                }
            }
        }
    }
}

private final class RecognitionState: @unchecked Sendable {
    var finished = false
}

struct WaveformView: View {
    let waveform: WaveformData
    let timeline: SelectedTimelineRange?
    let currentTimeUS: Int64
    let onSeek: (Int64) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let peaks = waveform.peaks
                guard !peaks.isEmpty else { return }
                let step = size.width / CGFloat(peaks.count)
                let midpoint = size.height / 2
                let playedFraction = waveform.durationUS > 0
                    ? min(max(Double(currentTimeUS) / Double(waveform.durationUS), 0), 1)
                    : 0

                for (index, peak) in peaks.enumerated() {
                    let x = step * (CGFloat(index) + 0.5)
                    let height = max(2, CGFloat(peak) * size.height * 0.86)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: midpoint - height / 2))
                    path.addLine(to: CGPoint(x: x, y: midpoint + height / 2))
                    let fraction = Double(index) / Double(max(peaks.count - 1, 1))
                    let timeUS = Int64(Double(waveform.durationUS) * fraction)
                    let inVisible = timeline.map { timeUS >= $0.visibleStartUS && timeUS <= $0.visibleEndUS } ?? false
                    let inSafe = timeline.flatMap { range in
                        guard let start = range.safeLeadingStartUS, let end = range.safeTrailingEndUS else { return nil }
                        return timeUS >= start && timeUS <= end
                    } ?? false
                    let color: Color
                    if let timeline, timeline.hasPreciseBuffers, !inSafe {
                        color = Color.secondary.opacity(0.2)
                    } else if let timeline, timeline.hasPreciseBuffers, !inVisible {
                        color = Color.orange.opacity(0.8)
                    } else {
                        color = fraction <= playedFraction ? Color.accentColor : Color.secondary.opacity(0.55)
                    }
                    context.stroke(path, with: .color(color), lineWidth: max(1, step * 0.62))
                }

                if let timeline {
                    func drawMarker(_ timeUS: Int64, color: Color) {
                        let x = size.width * CGFloat(min(max(Double(timeUS) / Double(max(waveform.durationUS, 1)), 0), 1))
                        var marker = Path()
                        marker.move(to: CGPoint(x: x, y: 0))
                        marker.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(marker, with: .color(color), lineWidth: 2)
                    }
                    drawMarker(timeline.visibleStartUS, color: .green)
                    drawMarker(timeline.visibleEndUS, color: .green)
                    if let safeStart = timeline.safeLeadingStartUS, let safeEnd = timeline.safeTrailingEndUS {
                        drawMarker(safeStart, color: .orange)
                        drawMarker(safeEnd, color: .orange)
                    }
                }

                if waveform.durationUS > 0 {
                    let playheadX = size.width * CGFloat(playedFraction)
                    var path = Path()
                    path.move(to: CGPoint(x: playheadX, y: 0))
                    path.addLine(to: CGPoint(x: playheadX, y: size.height))
                    context.stroke(path, with: .color(Color.primary.opacity(0.8)), lineWidth: 1)
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                onSeek(Int64((Double(waveform.durationUS) * fraction).rounded()))
            })
            .accessibilityElement()
            .accessibilityLabel(timeline.map { range in
                range.hasPreciseBuffers ? "Audio waveform with answer and buffer ranges" : "Audio waveform with answer marker range"
            } ?? "Audio waveform")
            .accessibilityValue(timeline.map { range in
                let answer = AccessibilityValueFormatter.range(startUS: range.visibleStartUS, endUS: range.visibleEndUS)
                if let safeStart = range.safeLeadingStartUS, let safeEnd = range.safeTrailingEndUS {
                    return "Answer \(answer); buffer range \(AccessibilityValueFormatter.range(startUS: safeStart, endUS: safeEnd)); \(AccessibilityValueFormatter.position(currentTimeUS: currentTimeUS, durationUS: waveform.durationUS))"
                }
                return "Answer markers \(answer); buffer range unavailable; \(AccessibilityValueFormatter.position(currentTimeUS: currentTimeUS, durationUS: waveform.durationUS))"
            } ?? AccessibilityValueFormatter.position(currentTimeUS: currentTimeUS, durationUS: waveform.durationUS))
            .accessibilityHint("Click or drag to move playback position")
        }
        .frame(height: 110)
    }
}

struct TranscriptPanel: View {
    let transcript: AnswerTranscript?
    let isTranscribing: Bool
    let canTranscribe: Bool
    let message: String?
    let onTranscribe: () -> Void

    var body: some View {
        GroupBox("Transcription") {
            VStack(alignment: .leading, spacing: 8) {
                if let transcript {
                    ScrollView {
                        Text(transcript.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 70, maxHeight: 180)
                    Text("On-device transcript · \(transcript.segments.count) timed segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Transcribe Again", action: onTranscribe)
                        .disabled(isTranscribing || !canTranscribe)
                } else {
                    Text("No transcript saved for this recording.")
                        .foregroundStyle(.secondary)
                    Button("Transcribe on This Mac", action: onTranscribe)
                        .disabled(isTranscribing || !canTranscribe)
                }
                if isTranscribing {
                    ProgressView("Transcribing…")
                        .controlSize(.small)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private enum AccessibilityValueFormatter {
    static func range(startUS: Int64, endUS: Int64) -> String {
        String(format: "%.2f to %.2f seconds", Double(startUS) / 1_000_000, Double(endUS) / 1_000_000)
    }

    static func position(currentTimeUS: Int64, durationUS: Int64) -> String {
        guard durationUS > 0 else { return "Position unavailable" }
        let current = Double(max(currentTimeUS, 0)) / 1_000_000
        let duration = Double(durationUS) / 1_000_000
        return String(format: "%.1f seconds of %.1f", current, duration)
    }
}
