import Foundation

@testable import SiliconCellarCore

final class ScriptedCommands: CommandRunning, @unchecked Sendable {
    enum Outcome {
        case success(String)
        case failure(String)
    }

    var outcomes: [Outcome] = []
    var calls: [[String]] = []

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        workingDirectory: URL?
    ) throws -> String {
        calls.append(arguments)
        guard !outcomes.isEmpty else { throw PortError("no scripted command left") }
        switch outcomes.removeFirst() {
        case .success(let output): return output
        case .failure(let message): throw PortError(message)
        }
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        log: URL
    ) throws {}
}

final class MemoryFiles: FileSystem {
    var paths: Set<String> = []

    func fileExists(_ url: URL) -> Bool { paths.contains(url.path) }
    func createDirectory(_ url: URL) throws { paths.insert(url.path) }
    func write(_ data: Data, to url: URL) throws { paths.insert(url.path) }
    func read(_ url: URL) throws -> Data { Data() }
    func removeItem(_ url: URL) throws { paths.remove(url.path) }
    func moveItem(from: URL, to: URL) throws {
        paths.remove(from.path)
        paths.insert(to.path)
    }
    func contentsOfDirectory(_ url: URL) throws -> [URL] { [] }
    func isSymbolicLink(_ url: URL) -> Bool { false }
    func setExecutable(_ url: URL) throws {}
}
