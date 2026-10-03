import Foundation

/// Times the user last selected a game or ran an action for it.
public struct GameInteractions: Equatable, Sendable {
    public private(set) var times: [String: Date]

    public init(times: [String: Date] = [:]) {
        self.times = times
    }

    public mutating func note(_ id: String, at date: Date) {
        times[id] = date
    }

    public static func load(url: URL, files: FileSystem = FoundationFileSystem()) -> GameInteractions {
        guard let data = try? files.read(url),
            let stored = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return GameInteractions() }
        return GameInteractions(times: stored.mapValues { Date(timeIntervalSince1970: $0) })
    }

    public func save(url: URL, files: FileSystem = FoundationFileSystem()) throws {
        let stored = times.mapValues { $0.timeIntervalSince1970 }
        let data = try JSONEncoder().encode(stored)
        try files.createDirectory(url.deletingLastPathComponent())
        try files.write(data, to: url)
    }
}

/// Installed games stay above the others. Each group uses the latest interaction first.
public enum GameListOrder {
    public static func sorted(
        _ recipes: [Recipe],
        installed: Set<String>,
        interactions: [String: Date]
    ) -> [Recipe] {
        recipes.enumerated().sorted { left, right in
            let leftInstalled = installed.contains(left.element.id)
            let rightInstalled = installed.contains(right.element.id)
            if leftInstalled != rightInstalled { return leftInstalled }
            let leftTime = interactions[left.element.id] ?? .distantPast
            let rightTime = interactions[right.element.id] ?? .distantPast
            if leftTime != rightTime { return leftTime > rightTime }
            return left.offset < right.offset
        }.map(\.element)
    }
}
