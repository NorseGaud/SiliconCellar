import Foundation

public protocol FileSystem {
    func fileExists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func read(_ url: URL) throws -> Data
    func removeItem(_ url: URL) throws
    func moveItem(from: URL, to: URL) throws
    func contentsOfDirectory(_ url: URL) throws -> [URL]
    func isSymbolicLink(_ url: URL) -> Bool
}

public struct FoundationFileSystem: FileSystem {
    private let manager: FileManager
    public init(manager: FileManager = .default) { self.manager = manager }

    public func fileExists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }

    public func createDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    public func removeItem(_ url: URL) throws { try manager.removeItem(at: url) }

    public func moveItem(from: URL, to: URL) throws { try manager.moveItem(at: from, to: to) }

    public func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])
    }

    public func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
