import Foundation

public protocol CommandRunning {
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
        // Drain while the process runs. If we wait to read until exit, a full pipe
        // can block the child (for example `ps` with a long process list).
        handle.readabilityHandler = { file in
            let data = file.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            collected.append(data)
            lock.unlock()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            handle.readabilityHandler = nil
            throw TimeoutError()
        }
        handle.readabilityHandler = nil
        let tail = handle.readDataToEndOfFile()
        if !tail.isEmpty {
            lock.lock()
            collected.append(tail)
            lock.unlock()
        }
        let output = String(decoding: collected, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw PortError("\(executable.lastPathComponent) failed (\(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    public func runStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?,
        onChunk: @escaping (String) -> Void
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
            guard !data.isEmpty else { return }
            lock.lock()
            collected.append(data)
            lock.unlock()
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { onChunk(piece) }
            }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            handle.readabilityHandler = nil
            throw TimeoutError()
        }
        handle.readabilityHandler = nil
        let tail = handle.readDataToEndOfFile()
        if !tail.isEmpty {
            lock.lock()
            collected.append(tail)
            lock.unlock()
            let text = String(decoding: tail, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { onChunk(piece) }
            }
        }
        let output = String(decoding: collected, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw PortError(
                "\(executable.lastPathComponent) failed (\(process.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return output
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
