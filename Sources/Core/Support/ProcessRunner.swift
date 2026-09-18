import Foundation
#if os(macOS)
import Darwin
#endif

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunnerError: LocalizedError {
    case nonZeroExit(command: String, status: Int32, stderr: String)
    case timedOut(command: String, timeout: TimeInterval, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let command, let status, let stderr):
            return "Command failed (\(status)): \(command)\n\(ProcessRunner.redactDiagnosticText(stderr))"
        case .timedOut(let command, let timeout, let stderr):
            let detail = ProcessRunner.redactDiagnosticText(stderr)
            let suffix = detail.isEmpty ? "" : "\n\(detail)"
            return "Command timed out after \(Int(timeout.rounded())) seconds: \(command). The renderer stopped it to prevent an indefinite render.\(suffix)"
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
        commandLogURL: URL? = nil,
        heartbeatInterval: TimeInterval? = nil,
        heartbeat: (@Sendable (TimeInterval) -> Void)? = nil,
        timeout: TimeInterval? = nil
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

        let heartbeatController: ProcessHeartbeatController?
        let heartbeatTimer: DispatchSourceTimer?
        if let heartbeat, let heartbeatInterval, heartbeatInterval > 0 {
            let controller = ProcessHeartbeatController(handler: heartbeat)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(
                deadline: .now() + heartbeatInterval,
                repeating: heartbeatInterval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { controller.emit() }
            timer.resume()
            heartbeatController = controller
            heartbeatTimer = timer
        } else {
            heartbeatController = nil
            heartbeatTimer = nil
        }
        defer {
            heartbeatController?.stop()
            heartbeatTimer?.cancel()
        }

        try process.run()
        let processStartedAt = Date()
        var timedOut = false
        var cancelled = false
        while process.isRunning {
            if Task.isCancelled {
                cancelled = true
                terminate(process)
                break
            }
            if let timeout, Date().timeIntervalSince(processStartedAt) >= timeout {
                timedOut = true
                terminate(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: stdoutData.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.data, encoding: .utf8) ?? ""
        if cancelled {
            throw CancellationError()
        }
        if timedOut {
            let command = "\(executableURL.lastPathComponent) (arguments redacted)"
            throw ProcessRunnerError.timedOut(command: command, timeout: timeout ?? 0, stderr: stderr)
        }
        let output = ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)

        guard output.status == 0 else {
            let command = "\(executableURL.lastPathComponent) (arguments redacted)"
            throw ProcessRunnerError.nonZeroExit(command: command, status: output.status, stderr: stderr)
        }

        return output
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #if os(macOS)
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        #endif
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

    static func redactDiagnosticText(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return value
            .replacingOccurrences(of: home, with: "<user-home>")
            .replacingOccurrences(of: "/private/tmp", with: "<temp>")
            .replacingOccurrences(of: NSTemporaryDirectory(), with: "<temp>")
    }
}

private final class ProcessHeartbeatController: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private let handler: @Sendable (TimeInterval) -> Void
    private var active = true

    init(handler: @escaping @Sendable (TimeInterval) -> Void) {
        self.handler = handler
    }

    func emit() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        lock.unlock()
        handler(elapsed)
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
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
