import Foundation

public struct PortError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct TimeoutError: Error, Equatable {
    public init() {}
}
