import Foundation

public protocol CommandRunning: Sendable {
    @discardableResult
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?
    ) throws -> String

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        log: URL
    ) throws

    func runStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?,
        onChunk: @escaping (String) -> Void
    ) throws -> String
}

extension CommandRunning {
    public func runStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?,
        onChunk: @escaping (String) -> Void
    ) throws -> String {
        let output = try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            workingDirectory: workingDirectory
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onChunk(trimmed) }
        return output
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?
    ) throws -> String {
        try runCollecting(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            workingDirectory: workingDirectory,
            onChunk: nil
        )
    }

    public func runStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?,
        onChunk: @escaping (String) -> Void
    ) throws -> String {
        try runCollecting(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            workingDirectory: workingDirectory,
            onChunk: onChunk
        )
    }

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        log: URL
    ) throws {
        let directory = log.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        Thread.sleep(forTimeInterval: 1.5)
        if !process.isRunning && process.terminationStatus != 0 {
            throw PortError("\(executable.lastPathComponent) exited before it could open. See \(log.path)")
        }
        try handle.close()
    }

    /// Drain via readabilityHandler only. Do not call `readDataToEndOfFile` after a handler —
    /// that combination can hang and leave PIPE fds open.
    private func runCollecting(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?,
        onChunk: ((String) -> Void)?
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        let lock = NSLock()
        var collected = Data()

        handle.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty {
                file.readabilityHandler = nil
                return
            }
            lock.lock()
            collected.append(data)
            lock.unlock()
            if let onChunk {
                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(whereSeparator: \.isNewline) {
                    let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { onChunk(piece) }
                }
            }
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        handle.readabilityHandler = nil
        process.waitUntilExit()

        // Writer is closed after waitUntilExit; availableData returns leftovers or empty.
        let leftover = handle.availableData
        if !leftover.isEmpty {
            lock.lock()
            collected.append(leftover)
            lock.unlock()
            if let onChunk {
                let text = String(decoding: leftover, as: UTF8.self)
                for line in text.split(whereSeparator: \.isNewline) {
                    let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { onChunk(piece) }
                }
            }
        }
        try? handle.close()

        if timedOut {
            throw TimeoutError()
        }

        lock.lock()
        let output = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        if process.terminationStatus != 0 {
            throw PortError(
                "\(executable.lastPathComponent) failed (\(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return output
    }
}

public protocol StatusSink {
    func say(_ message: String)
}

public struct PrintSink: StatusSink {
    public init() {}
    public func say(_ message: String) { print(message) }
}

public final class CallbackSink: StatusSink, @unchecked Sendable {
    private let handler: @Sendable (String) -> Void
    public init(_ handler: @escaping @Sendable (String) -> Void) { self.handler = handler }
    public func say(_ message: String) { handler(message) }
}

public final class CollectingSink: StatusSink, @unchecked Sendable {
    public private(set) var messages: [String] = []
    public init() {}
    public func say(_ message: String) { messages.append(message) }
}
