import Core
import Foundation
import XCTest

struct TestWorkspace {
    enum AudioProfile {
        case quietHandles
        case speechyHandles
    }

    let rootURL: URL
    let manifestURL: URL

    static func make(audioProfile: AudioProfile = .quietHandles) throws -> TestWorkspace {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "fixture_manifest", withExtension: "json"))
        let manifestURL = rootURL.appendingPathComponent("final_manifest.json")
        try FileManager.default.copyItem(at: fixtureURL, to: manifestURL)

        let ffmpegPath = ProcessInfo.processInfo.environment["YEARLY_INTERVIEW_STUDIO_FFMPEG"] ?? "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
        let clipDir = rootURL.appendingPathComponent("Ellie - What is Your Name", isDirectory: true)
        try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)

        try generateClip(
            ffmpegPath: ffmpegPath,
            color: "red",
            frequency: "440",
            outputURL: clipDir.appendingPathComponent("Ellie-What-is-Your-Name-5-Years-Old.mov"),
            audioProfile: audioProfile
        )
        try generateClip(
            ffmpegPath: ffmpegPath,
            color: "blue",
            frequency: "660",
            outputURL: clipDir.appendingPathComponent("Ellie-What-is-Your-Name-6-Years-Old.mov"),
            audioProfile: audioProfile
        )

        return TestWorkspace(rootURL: rootURL, manifestURL: manifestURL)
    }

    private static func generateClip(ffmpegPath: String, color: String, frequency: String, outputURL: URL, audioProfile: AudioProfile) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        var arguments = [
            "-y",
            "-f", "lavfi",
            "-i", "color=c=\(color):s=640x360:d=2:r=30"
        ]

        switch audioProfile {
        case .quietHandles:
            arguments.append(contentsOf: [
                "-f", "lavfi",
                "-i", "anullsrc=r=48000:cl=stereo:d=0.5",
                "-f", "lavfi",
                "-i", "sine=frequency=\(frequency):duration=1",
                "-f", "lavfi",
                "-i", "anullsrc=r=48000:cl=stereo:d=0.5",
                "-filter_complex", "[1:a][2:a][3:a]concat=n=3:v=0:a=1[aout]",
                "-map", "0:v",
                "-map", "[aout]"
            ])
        case .speechyHandles:
            arguments.append(contentsOf: [
                "-f", "lavfi",
                "-i", "sine=frequency=\(frequency):duration=2",
                "-map", "0:v",
                "-map", "1:a"
            ])
        }

        arguments.append(contentsOf: [
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-shortest",
            outputURL.path
        ])
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
