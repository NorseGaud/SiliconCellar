import Foundation

public struct EngineLocator {
    public static let missingMessage = """
        The game runtime was not found.
        Silicon Cellar needs Wine Staging bundled at Contents/Resources/Engine/bin/wine.
        Run make engine (or make app), or set SILICONCELLAR_WINE.
        """

    private let files: FileSystem
    private let bundleURL: URL

    public init(
        commands: CommandRunning = ProcessCommandRunner(),
        files: FileSystem = FoundationFileSystem(),
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        _ = commands
        self.files = files
        self.bundleURL = bundleURL
    }

    public func findWine() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SILICONCELLAR_WINE"] {
            let url = URL(fileURLWithPath: override)
            return files.fileExists(url) ? url : nil
        }
        let bundled = AppPaths.bundledWineBinary(bundle: bundleURL)
        if files.fileExists(bundled) { return bundled }
        let support = AppPaths.wineBinary()
        if files.fileExists(support) { return support }
        return nil
    }

    public static func wineserver(nextTo wine: URL) -> URL {
        wine.deletingLastPathComponent().appendingPathComponent("wineserver")
    }
}
