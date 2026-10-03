import Foundation

public struct PortError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct TimeoutError: Error, Equatable, LocalizedError {
    public var command: String

    public init(command: String = "") { self.command = command }

    public var errorDescription: String? {
        command.isEmpty ? "The command timed out." : "The command timed out: \(command)."
    }
}
