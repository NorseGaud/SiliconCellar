import Foundation

public struct EngineLocator {
    public static let missingMessage = """
        The game runtime was not found.
        Silicon Cellar needs the Wine Engine bundled at Contents/Resources/Engine/bin/wine.
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

    /// First line of `Engine/.siliconcellar-engine-version` (written by `make engine`), or "unknown".
    public static func engineID(wine: URL, files: FileSystem = FoundationFileSystem()) -> String {
        let marker = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".siliconcellar-engine-version")
        guard let data = try? files.read(marker),
            let firstLine = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first
        else { return "unknown" }
        return firstLine.trimmingCharacters(in: .whitespaces)
    }
}
