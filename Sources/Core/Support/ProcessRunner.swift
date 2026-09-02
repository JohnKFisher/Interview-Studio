import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunnerError: LocalizedError {
    case nonZeroExit(command: String, status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let command, let status, let stderr):
            return "Command failed (\(status)): \(command)\n\(ProcessRunner.redactDiagnosticText(stderr))"
        }
    }
}

public struct ProcessRunner {
    public init() {}

    @discardableResult
    public func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        commandLogURL: URL? = nil
    ) throws -> ProcessOutput {
        if let commandLogURL {
            try appendCommandLog(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment,
                destinationURL: commandLogURL
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutData = DataAccumulator()
        let stderrData = DataAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutData.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrData.append(data)
            }
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: stdoutData.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.data, encoding: .utf8) ?? ""
        let output = ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)

        guard output.status == 0 else {
            let command = "\(executableURL.lastPathComponent) (arguments redacted)"
            throw ProcessRunnerError.nonZeroExit(command: command, status: output.status, stderr: stderr)
        }

        return output
    }

    private func appendCommandLog(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String],
        destinationURL: URL
    ) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["[\(timestamp)]"]
        lines.append("tool=\(executableURL.lastPathComponent) argument_count=\(arguments.count)")
        if currentDirectoryURL != nil {
            lines.append("cwd=<redacted>")
        }
        if !environment.isEmpty {
            lines.append("environment_keys=\(environment.keys.sorted().joined(separator: ","))")
        }
        lines.append("arguments=<redacted>")
        lines.append("")

        let payload = lines.joined(separator: "\n")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data(payload.utf8))
        } else {
            try Data(payload.utf8).write(to: destinationURL, options: .atomic)
        }
    }

    fileprivate static func redactDiagnosticText(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return value
            .replacingOccurrences(of: home, with: "<user-home>")
            .replacingOccurrences(of: "/private/tmp", with: "<temp>")
            .replacingOccurrences(of: NSTemporaryDirectory(), with: "<temp>")
    }
}

private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
