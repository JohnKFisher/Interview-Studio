@testable import Core
import XCTest

final class FFmpegTests: XCTestCase {
    func testCapabilitiesReportMissingPhaseOneRequirements() {
        let capabilities = FFmpegCapabilities(
            hasZscale: false,
            hasXfade: true,
            hasAcrossfade: false,
            hasOverlay: true,
            hasLibx265: false
        )

        XCTAssertFalse(capabilities.isSufficientForPhaseOne)
        XCTAssertEqual(capabilities.missingPhaseOneCapabilities, ["zscale", "acrossfade", "libx265"])
    }

    func testLocatorIncludesExecutableBundledCandidate() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolsURL = rootURL.appendingPathComponent("BundledTools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let ffmpegURL = toolsURL.appendingPathComponent("ffmpeg")
        let ffprobeURL = toolsURL.appendingPathComponent("ffprobe")
        XCTAssertTrue(FileManager.default.createFile(atPath: ffmpegURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: ffprobeURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobeURL.path)

        let candidate = try XCTUnwrap(FFmpegLocator().candidates(bundleResourceURL: rootURL).first)
        XCTAssertEqual(candidate.sourceDescription, "app bundle")
        XCTAssertEqual(candidate.ffmpegURL.path, ffmpegURL.path)
        XCTAssertEqual(candidate.ffprobeURL.path, ffprobeURL.path)
    }
}
